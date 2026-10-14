import Foundation
import Photos
import GRDB
import BackgroundTasks

/// What gets backed up (DESIGN.md D17).
enum SyncScope: Equatable {
    case all
    /// Only assets captured at or after the moment sync was switched on.
    case newOnly(anchor: Date)

    var isNewOnly: Bool {
        if case .newOnly = self { return true }
        return false
    }

    var anchor: Date? {
        if case let .newOnly(anchor) = self { return anchor }
        return nil
    }
}

/// Uploads device photos and videos to Immich (requirement 14, DESIGN.md §12).
///
/// The pipeline is: enumerate → checksum → dedupe against the server → upload. The dedupe step
/// is what makes first run against an already-populated server cheap — most assets come back as
/// duplicates and are marked backed up without transferring a byte.
///
/// Uploads run on a background `URLSession` so they survive app suspension (D12).
actor SyncEngine {

    static let backgroundTaskIdentifier = "dev.biscuittin.sync"
    private static let maxRetries = 5
    private static let checksumBatchSize = 200
    private static let uploadConcurrency = 2

    private let database: AppDatabase
    private let session: ImmichAuthSession
    private let localLibrary: LocalLibraryService
    private let resolver: PHAssetResolver
    private let exporter: LocalAssetExporter
    private let remoteLibrary: RemoteLibraryService
    private let settings: AppSettings
    private let status: BackupStatusStore
    private let network = NetworkMonitor()

    private var isRunning = false
    private var uploadsInFlight = 0
    /// Set when an upload landed bytes older than the asset it came from; see `upload`.
    private var queuedEditDuringUpload = false

    init(database: AppDatabase,
         session: ImmichAuthSession,
         localLibrary: LocalLibraryService,
         resolver: PHAssetResolver,
         exporter: LocalAssetExporter,
         remoteLibrary: RemoteLibraryService,
         settings: AppSettings,
         status: BackupStatusStore) {
        self.database = database
        self.session = session
        self.localLibrary = localLibrary
        self.resolver = resolver
        self.exporter = exporter
        self.remoteLibrary = remoteLibrary
        self.settings = settings
        self.status = status
    }

    // MARK: - Configuration

    nonisolated var isEnabled: Bool { settings.syncEnabled }
    nonisolated var scope: SyncScope { settings.syncScope }
    nonisolated var allowsCellular: Bool { settings.syncAllowsCellular }

    /// Resumes the queue when connectivity returns or Wi-Fi appears, since nothing else would
    /// until the next foreground or background task.
    nonisolated func startMonitoringNetwork() {
        network.start { [weak self] in
            Task { await self?.kick() }
        }
    }

    func setAllowsCellular(_ allowed: Bool) async {
        settings.syncAllowsCellular = allowed
        await kick()
    }

    /// Why uploads cannot use the network right now, or nil when they can.
    private var networkWait: BackupStatusStore.Phase? {
        if !network.isSatisfied { return .waitingForNetwork }
        if network.isExpensive && !allowsCellular { return .waitingForWiFi }
        return nil
    }

    /// Turning sync on requires a scope choice; the settings screen asks for one (D17).
    func setEnabled(_ enabled: Bool, scope newScope: SyncScope?) async {
        settings.syncEnabled = enabled
        if let newScope { settings.syncScope = newScope }

        if enabled {
            await kick()
        } else {
            await publishStatus(uploading: false)
        }
    }

    /// One-way upgrade from "new items only" to "all" (D17). Everything previously excluded
    /// becomes pending; there is no downgrade, which keeps the state model trivial.
    func upgradeScopeToAll() async {
        guard scope.isNewOnly else { return }
        settings.syncScope = .all

        if let writer = try? database.writer() {
            try? await writer.write { db in
                try db.execute(sql: """
                    UPDATE backup_state SET state = ?, updated_at = ?
                    WHERE state = ?
                    """,
                    arguments: [BackupStateRecord.State.pending.rawValue,
                                Date().timeIntervalSince1970,
                                BackupStateRecord.State.outOfScope.rawValue])
            }
        }
        await kick()
    }

    /// Number of assets that would be added by upgrading, for the confirmation copy.
    func outOfScopeCount() async -> Int {
        guard let writer = try? database.writer() else { return 0 }
        return (try? await writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM backup_state WHERE state = ?",
                             arguments: [BackupStateRecord.State.outOfScope.rawValue]) ?? 0
        }) ?? 0
    }

    // MARK: - Pipeline

    /// Evaluates the queue and makes as much progress as it can. Safe to call often.
    func kick() async {
        guard isEnabled, session.isConfigured else {
            await status.setPhase(.idle)
            await publishStatus(uploading: false)
            return
        }
        guard localLibrary.hasAnyAccess else {
            await status.setPhase(.noPhotoAccess)
            await publishStatus(uploading: false)
            return
        }
        guard !isRunning else { return }
        isRunning = true
        await status.setError(nil)
        await releaseOrphanedUploads()

        do {
            await status.setPhase(.scanning)
            try await enumerateLibrary()
            await publishStatus(uploading: true)

            // Checksum, dedupe and upload in rounds until the queue stops shrinking, so one
            // kick drains the backlog instead of leaving most of it for the next trigger.
            // Enumeration above is local and runs regardless of the network, so a wait still
            // reports how much is owed.
            while networkWait == nil {
                try Task.checkCancellation()
                let before = try await outstandingCount()
                guard before > 0 else { break }

                await status.setPhase(.preparing)
                let checksummed = try await computeMissingChecksums()
                await status.setPhase(.checkingServer)
                let deduped = try await dedupeAgainstServer()
                await status.setPhase(.uploading)
                let uploaded = try await uploadPending()
                // All three link facets in `facet_links` directly; the timeline hears of it only here.
                if checksummed || deduped || uploaded { remoteLibrary.facetLinksDidChange() }
                await publishStatus(uploading: true)

                let after = try await outstandingCount()
                if after >= before { break }   // no progress this round: stop rather than spin
            }

            // Straight away rather than on the next foreground: the server was reachable a
            // moment ago, and until this runs it shows the photo as it was before the edit.
            if queuedEditDuringUpload {
                queuedEditDuringUpload = false
                await remoteLibrary.retryPendingEdits()
            }
        } catch is CancellationError {
            // Leave state as-is; the next kick resumes.
        } catch where networkWait != nil || NetworkMonitor.isConnectivityError(error) {
            Log.sync.info("Sync paused, network unavailable: \(error.localizedDescription, privacy: .public)")
        } catch {
            Log.sync.error("Sync failed: \(error.localizedDescription, privacy: .public)")
            await status.setError((error as? LocalizedError)?.errorDescription
                                  ?? error.localizedDescription)
        }
        isRunning = false
        await status.setPhase(networkWait ?? .idle)
        await publishStatus(uploading: false)
    }

    /// Returns rows left `uploading` by a run that never finished — the app was killed or
    /// suspended mid-transfer — to the queue. Nothing selects `uploading` rows for upload, yet
    /// they count as outstanding, so without this they would stay owed forever. Only one run
    /// is ever active (`isRunning`), so at its start no row is genuinely in flight.
    private func releaseOrphanedUploads() async {
        guard let writer = try? database.writer() else { return }
        try? await writer.write { db in
            try db.execute(sql: "UPDATE backup_state SET state = ? WHERE state = ?",
                           arguments: [BackupStateRecord.State.pending.rawValue,
                                       BackupStateRecord.State.uploading.rawValue])
        }
    }

    /// Items still owing an upload, used to detect progress between rounds.
    private func outstandingCount() async throws -> Int {
        let writer = try database.writer()
        return try await writer.read { db in
            try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM backup_state WHERE state IN (?, ?, ?) AND retry_count < ?",
                arguments: [BackupStateRecord.State.pending.rawValue,
                            BackupStateRecord.State.uploading.rawValue,
                            BackupStateRecord.State.failed.rawValue,
                            Self.maxRetries]) ?? 0
        }
    }

    /// Step 1: make sure every local asset has a backup_state row, honouring the scope.
    private func enumerateLibrary() async throws {
        let fetch = localLibrary.fetchAllAssets()
        var rows: [(String, Date)] = []
        rows.reserveCapacity(fetch.count)
        fetch.enumerateObjects { asset, _, _ in
            rows.append((asset.localIdentifier, asset.creationDate ?? .distantPast))
        }

        let anchor = scope.anchor
        let writer = try database.writer()
        try await writer.write { db in
            let known = try String.fetchSet(db, sql: "SELECT local_identifier FROM backup_state")
            for (identifier, created) in rows where !known.contains(identifier) {
                // Out of scope assets are recorded, not skipped, so upgrading later is a
                // state flip rather than a re-enumeration of the whole library.
                let state: BackupStateRecord.State =
                    (anchor.map { created < $0 } ?? false) ? .outOfScope : .pending
                try BackupStateRecord(localIdentifier: identifier, state: state).insert(db)
            }
        }
    }

    /// Step 2: checksum assets we have not hashed yet. Returns whether it linked any facets.
    private func computeMissingChecksums() async throws -> Bool {
        let writer = try database.writer()
        let identifiers = try await writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT local_identifier FROM backup_state
                WHERE checksum_hex IS NULL AND state = ?
                LIMIT ?
                """, arguments: [BackupStateRecord.State.pending.rawValue, Self.checksumBatchSize])
        }
        guard !identifiers.isEmpty else { return false }

        var linked = false
        let assets = resolver.resolve(identifiers)
        for identifier in identifiers {
            try Task.checkCancellation()
            guard let asset = assets[identifier] else {
                try await mark(identifier, state: .ineligible, error: "Asset no longer exists")
                continue
            }
            do {
                let checksum = try await exporter.checksum(asset: asset)
                try await writer.write { db in
                    try db.execute(sql: """
                        UPDATE backup_state SET checksum_hex = ?, updated_at = ?
                        WHERE local_identifier = ?
                        """, arguments: [checksum, Date().timeIntervalSince1970, identifier])
                    // Link the facets: a server asset with this checksum is the same photo (D5).
                    try db.execute(sql: """
                        INSERT INTO facet_links (checksum_hex, local_identifier, immich_id)
                        VALUES (?, ?, NULL)
                        ON CONFLICT(checksum_hex) DO UPDATE SET local_identifier = excluded.local_identifier
                        """, arguments: [checksum, identifier])
                }
                linked = true
            } catch {
                try await mark(identifier, state: .ineligible, error: error.localizedDescription)
            }
        }
        return linked
    }

    /// Step 3: ask the server which checksums it already has. Duplicates are marked uploaded
    /// without transferring anything. Returns whether it linked any facets.
    private func dedupeAgainstServer() async throws -> Bool {
        guard let baseURL = session.baseURL else { throw ImmichError.notConfigured }
        let client = ImmichClient(baseURL: baseURL, credentialProvider: { [session] in session.credential })

        let writer = try database.writer()
        let candidates = try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT local_identifier, checksum_hex FROM backup_state
                WHERE state = ? AND checksum_hex IS NOT NULL
                LIMIT ?
                """, arguments: [BackupStateRecord.State.pending.rawValue, Self.checksumBatchSize])
        }
        guard !candidates.isEmpty else { return false }

        let items = candidates.map {
            Immich.BulkUploadCheckItem(id: $0["local_identifier"], checksum: $0["checksum_hex"])
        }
        let response = try await client.bulkUploadCheck(items)
        var linked = false

        for result in response.results where result.action == "reject" {
            guard result.reason == "duplicate" else { continue }

            // Immich reports assets in its trash as duplicates too. Treating one as backed up
            // would mark the local copy safe while its only server copy waits to be purged —
            // and would then make it a candidate for Free Up Space (D18). Leave it pending so
            // it uploads again.
            if result.isTrashed == true {
                Log.sync.info("Duplicate \(result.id, privacy: .public) is trashed on the server; re-uploading")
                continue
            }

            try await mark(result.id, state: .uploaded, error: nil)
            if let assetID = result.assetId {
                try await writer.write { db in
                    try db.execute(sql: """
                        UPDATE facet_links SET immich_id = ?
                        WHERE local_identifier = ?
                        """, arguments: [assetID, result.id])
                }
                linked = true
            }
        }
        return linked
    }

    /// Step 4: upload what is left. Returns whether it linked any facets.
    private func uploadPending() async throws -> Bool {
        guard let baseURL = session.baseURL else { throw ImmichError.notConfigured }
        let client = ImmichClient(baseURL: baseURL, credentialProvider: { [session] in session.credential })

        let writer = try database.writer()
        let pending = try await writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT local_identifier FROM backup_state
                WHERE state IN (?, ?) AND retry_count < ?
                ORDER BY updated_at ASC
                LIMIT ?
                """, arguments: [BackupStateRecord.State.pending.rawValue,
                                 BackupStateRecord.State.failed.rawValue,
                                 Self.maxRetries,
                                 Self.uploadConcurrency * 4])
        }
        guard !pending.isEmpty else { return false }

        var linked = false
        let assets = resolver.resolve(pending)
        let meter = TransferRateMeter()
        let ticker = Task { [status] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                await status.setUploadRate(meter.bytesPerSecond())
            }
        }
        defer { ticker.cancel() }

        for identifier in pending {
            try Task.checkCancellation()
            // Stop the round rather than fail the rest of it one by one; `kick` reports the wait.
            guard networkWait == nil else { break }
            guard let asset = assets[identifier] else {
                try await mark(identifier, state: .ineligible, error: "Asset no longer exists")
                continue
            }
            if await upload(asset: asset, identifier: identifier, client: client, meter: meter) {
                linked = true
            }
            await publishStatus(uploading: true)
        }
        return linked
    }

    /// Returns whether it linked the uploaded asset to its server copy.
    private func upload(asset: PHAsset, identifier: String, client: ImmichClient,
                        meter: TransferRateMeter) async -> Bool {
        do {
            try await mark(identifier, state: .uploading, error: nil)
            let modifiedBeforeExport = asset.modificationDate
            let export = try await exporter.export(asset: asset)
            defer { try? FileManager.default.removeItem(at: export.fileURL) }

            let (unrestricted, bodyURL) = try await client.makeUploadRequest(
                fileURL: export.fileURL,
                deviceAssetId: identifier,
                deviceId: session.deviceID,
                fileCreatedAt: export.createdAt,
                fileModifiedAt: export.modifiedAt,
                filename: export.filename,
                checksumHex: export.sha1Hex)
            defer { try? FileManager.default.removeItem(at: bodyURL) }
            // Catches a switch from Wi-Fi to mobile data mid-transfer, which the check between
            // items cannot: URLSession fails the request rather than moving it to cellular.
            var request = unrestricted
            request.allowsExpensiveNetworkAccess = allowsCellular

            let response = try await UploadTask.perform(request: request, bodyURL: bodyURL, meter: meter)

            // "duplicate" is success too: the server already had these bytes.
            try await mark(identifier, state: .uploaded, error: nil, checksum: export.sha1Hex)
            if let remoteID = response?.id {
                let writer = try database.writer()
                try await writer.write { db in
                    try db.execute(sql: """
                        INSERT INTO facet_links (checksum_hex, local_identifier, immich_id)
                        VALUES (?, ?, ?)
                        ON CONFLICT(checksum_hex) DO UPDATE SET
                            local_identifier = excluded.local_identifier,
                            immich_id = excluded.immich_id
                        """, arguments: [export.sha1Hex, identifier, remoteID])
                }
                await queueReconcileIfEdited(identifier: identifier, immichID: remoteID,
                                             kind: AssetStub(asset).kind, since: modifiedBeforeExport)
            }
            Log.sync.info("Uploaded \(export.filename, privacy: .public) (\(export.byteCount) bytes)")
            return response?.id != nil
        } catch is CancellationError {
            try? await mark(identifier, state: .pending, error: nil)
        } catch where networkWait != nil || NetworkMonitor.isConnectivityError(error) {
            // Not this item's fault; spending a retry on it would eventually abandon it.
            try? await mark(identifier, state: .pending, error: nil)
        } catch {
            try? await bumpFailure(identifier, error: error.localizedDescription)
        }
        return false
    }

    /// Catches an edit made while the upload was in flight, such as a rotation from the viewer.
    ///
    /// The export was taken before the edit, so the server now holds the old rendition. The
    /// edit itself had no server leg to run — the asset was not linked yet — and an uploaded
    /// asset is never uploaded again, so without this the two copies would stay different for
    /// good. Checked only after the link is written: an edit from then on finds the link and
    /// updates the server itself (`PhotoActionService.rotateOne`).
    ///
    /// Never throws: the upload itself succeeded, and failing it here would send it round again.
    private func queueReconcileIfEdited(identifier: String, immichID: String,
                                        kind: MediaKind, since baseline: Date?) async {
        // Fetched afresh: the resolver's cached `PHAsset` is a snapshot from before the edit.
        guard let current = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
                .firstObject?.modificationDate,
              baseline.map({ current > $0 }) ?? true else { return }

        Log.sync.info("\(identifier, privacy: .public) changed during its upload; queueing a server update")
        do {
            try await remoteLibrary.enqueueLocalReconcile(localIdentifier: identifier, immichID: immichID,
                                                          mediaKind: kind)
            queuedEditDuringUpload = true
        } catch {
            Log.sync.error("Couldn't queue a server update: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - State helpers

    private func mark(_ identifier: String,
                      state: BackupStateRecord.State,
                      error: String?,
                      checksum: String? = nil) async throws {
        let writer = try database.writer()
        try await writer.write { db in
            if let checksum {
                try db.execute(sql: """
                    UPDATE backup_state SET state = ?, last_error = ?, checksum_hex = ?, updated_at = ?
                    WHERE local_identifier = ?
                    """, arguments: [state.rawValue, error, checksum,
                                     Date().timeIntervalSince1970, identifier])
            } else {
                try db.execute(sql: """
                    UPDATE backup_state SET state = ?, last_error = ?, updated_at = ?
                    WHERE local_identifier = ?
                    """, arguments: [state.rawValue, error,
                                     Date().timeIntervalSince1970, identifier])
            }
        }
    }

    private func bumpFailure(_ identifier: String, error: String) async throws {
        let writer = try database.writer()
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE backup_state
                SET state = ?, last_error = ?, retry_count = retry_count + 1, updated_at = ?
                WHERE local_identifier = ?
                """, arguments: [BackupStateRecord.State.failed.rawValue, error,
                                 Date().timeIntervalSince1970, identifier])
        }
    }

    /// Recomputes the badge count (requirement 14). Callers outside a run, such as Settings
    /// refreshing its counts, cannot end one: `uploading` holds while a run is active.
    func publishStatus(uploading: Bool) async {
        let uploading = uploading || isRunning
        let enabled = isEnabled
        var remaining = 0
        var failed = 0
        var retrying = 0
        if let writer = try? database.writer() {
            (remaining, failed, retrying) = (try? await writer.read { db in
                let remaining = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM backup_state WHERE state IN (?, ?, ?)
                    """, arguments: StatementArguments(BackupStateRecord.outstandingStates)) ?? 0
                let failedTotal = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM backup_state WHERE state = ?
                    """, arguments: [BackupStateRecord.State.failed.rawValue]) ?? 0
                let failed = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM backup_state WHERE state = ? AND retry_count >= ?
                    """, arguments: [BackupStateRecord.State.failed.rawValue, Self.maxRetries]) ?? 0
                return (remaining, failed, failedTotal - failed)
            }) ?? (0, 0, 0)
        }
        await status.update(remaining: remaining, uploading: uploading, enabled: enabled,
                            failed: failed, retrying: retrying)
    }

    // MARK: - Background scheduling (D12)

    /// Connects this engine to the identifier the app delegate registered at launch.
    nonisolated func connectBackgroundHandler() {
        BackgroundTaskRegistrar.setHandler { task in
            Task { await self.handleBackgroundTask(task) }
        }
    }

    nonisolated func scheduleBackgroundTask() {
        guard isEnabled else { return }
        // Submitting an unregistered identifier raises an Objective-C exception that Swift
        // cannot catch, which aborts the process. Never submit unless registration succeeded.
        guard BackgroundTaskRegistrar.canSubmit else { return }

        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Log.sync.debug("Background task not scheduled: \(error.localizedDescription, privacy: .public)")
        }
    }

    func handleBackgroundTask(_ task: BGProcessingTask) async {
        scheduleBackgroundTask()   // always leave a successor queued

        // Reuses this same background window for D22's pending-edit retries rather than
        // registering a second BGTaskScheduler identifier for what is, in practice, a much
        // smaller and rarer queue than the upload backlog this task already exists for.
        let work = Task {
            await kick()
            await remoteLibrary.retryPendingEdits()
        }
        task.expirationHandler = { work.cancel() }
        await work.value
        task.setTaskCompleted(success: true)
    }
}

/// Performs one upload. Kept separate so the transport can move to a true background
/// `URLSession` without touching the engine's state machine.
enum UploadTask {
    static func perform(request: URLRequest, bodyURL: URL,
                        meter: TransferRateMeter? = nil) async throws -> Immich.UploadResponse? {
        let delegate = meter.map(ProgressDelegate.init)
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: bodyURL,
                                                                  delegate: delegate)
        guard let http = response as? HTTPURLResponse else { return nil }
        switch http.statusCode {
        case 200..<300:
            return try? JSONDecoder().decode(Immich.UploadResponse.self, from: data)
        case 401, 403:
            throw ImmichError.unauthorized
        default:
            throw ImmichError.http(status: http.statusCode)
        }
    }
}


/// Feeds bytes sent to a `TransferRateMeter`, for the grid's info bar.
private final class ProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let meter: TransferRateMeter

    init(meter: TransferRateMeter) {
        self.meter = meter
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        meter.record(bytes: bytesSent)
    }
}
