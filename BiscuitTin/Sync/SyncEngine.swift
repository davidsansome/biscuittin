import Foundation
import Photos
import GRDB
import BackgroundTasks
import UIKit

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
    static let refreshTaskIdentifier = "dev.biscuittin.refresh"
    /// Continued-processing identifiers must start with the bundle id.
    static let backUpNowTaskIdentifier = "com.davidsansome.biscuittin.backup-now"
    /// Everything the app delegate registers at launch.
    static let backgroundTaskIdentifiers = [backgroundTaskIdentifier, refreshTaskIdentifier,
                                            backUpNowTaskIdentifier]
    private static let maxRetries = 5
    private static let checksumBatchSize = 200
    /// Bounds on what is handed to the upload daemon at once. Queueing several at a time
    /// matters in the background: iOS waits longer before each relaunch it makes to report a
    /// completion, so one at a time slows to a crawl. The byte bound caps disk use, since every
    /// queued body is a full copy of its original; one upload is always allowed, however large.
    private static let maxQueuedUploads = 8
    private static let maxQueuedBytes: Int64 = 1 << 30

    private let database: AppDatabase
    private let session: ImmichAuthSession
    private let localLibrary: LocalLibraryService
    private let resolver: PHAssetResolver
    private let exporter: LocalAssetExporter
    private let remoteLibrary: RemoteLibraryService
    private let settings: AppSettings
    private let status: BackupStatusStore
    private let network = NetworkMonitor()
    private let uploader: BackgroundUploader

    private var isRunning = false
    /// The run in progress. Only one runs at a time.
    private var currentRun: Task<Void, Never>?
    /// A kick arrived during a run, which goes round again rather than dropping it.
    private var rerunRequested = false
    /// A refill waiting to start; see `scheduleRefill`.
    private var pendingRefill: Task<Void, Never>?
    /// Set by kicks from outside, which may follow a library change. An upload finishing
    /// leaves it alone: enumerating the whole library for that would be wasted work.
    private var needsEnumeration = true
    /// Uploads the daemon holds, as of the last count.
    private var uploadsInFlight = 0
    private var rateTicker: Task<Void, Never>?
    private var linksNotice: Task<Void, Never>?
    /// Set when an upload landed bytes older than the asset it came from; see `upload`.
    private var queuedEditDuringUpload = false

    init(database: AppDatabase,
         session: ImmichAuthSession,
         localLibrary: LocalLibraryService,
         resolver: PHAssetResolver,
         exporter: LocalAssetExporter,
         remoteLibrary: RemoteLibraryService,
         settings: AppSettings,
         status: BackupStatusStore,
         uploader: BackgroundUploader = .shared) {
        self.uploader = uploader
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
        // Queued transfers keep the permission they were queued with; requeue them without it.
        if !allowed { await uploader.cancelAll() }
        await kick()
    }

    /// Stops the transfers the daemon holds. They return to the queue for the next run.
    func cancelUploads() async {
        await uploader.cancelAll()
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
            await uploader.cancelAll()
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

    /// Evaluates the queue and makes as much progress as it can. Safe to call often: a kick
    /// during a run makes that run go round again instead of starting a second one.
    func kick() async {
        needsEnumeration = true
        await requestRun()
    }

    private func requestRun() async {
        if currentRun != nil {
            rerunRequested = true
            return
        }
        let run = Task {
            repeat {
                rerunRequested = false
                await runOnce()
            } while rerunRequested && !Task.isCancelled
        }
        currentRun = run
        await withTaskCancellationHandler {
            await run.value
        } onCancel: {
            run.cancel()
        }
        currentRun = nil
        // Requested between the loop's last check and here.
        if rerunRequested && !Task.isCancelled { await requestRun() }
    }

    /// Waits for the run in progress, and for a refill about to start one, if there are
    /// any. Cancelling the caller cancels both.
    func waitForCurrentRun() async {
        let refill = pendingRefill
        let run = currentRun
        guard refill != nil || run != nil else { return }
        await withTaskCancellationHandler {
            await refill?.value
            await run?.value
        } onCancel: {
            refill?.cancel()
            run?.cancel()
        }
    }

    private func runOnce() async {
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
        isRunning = true
        await status.setError(nil)
        await releaseOrphanedUploads()

        do {
            if needsEnumeration {
                needsEnumeration = false
                await setWorkingPhase(.scanning)
                try await enumerateLibrary()
            }
            await publishStatus(uploading: true)

            // Checksum, dedupe and upload in rounds until the queue stops shrinking, so one
            // kick drains the backlog instead of leaving most of it for the next trigger.
            // Enumeration above is local and runs regardless of the network, so a wait still
            // reports how much is owed.
            while networkWait == nil {
                try Task.checkCancellation()
                let before = try await outstandingCount()
                guard before > 0 else { break }

                await setWorkingPhase(.preparing)
                let checksummed = try await computeMissingChecksums()
                let deduped = try await dedupeAgainstServer()
                await status.setPhase(.uploading)
                let queued = try await uploadPending()
                // Both link facets in `facet_links` directly; the timeline hears of it only here.
                // Uploads link theirs as they finish (`record`).
                if checksummed || deduped { remoteLibrary.facetLinksDidChange() }
                await publishStatus(uploading: true)

                // Uploads finish later, so queueing more counts as progress. Once the queue is
                // full, uploads finishing start the next run.
                let after = try await outstandingCount()
                if after >= before && queued == 0 { break }   // stop rather than spin
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
        await status.setPhase(networkWait ?? (uploadsInFlight > 0 ? .uploading : .idle))
        await publishStatus(uploading: false)
    }

    /// Returns rows left `uploading` with no transfer behind them to the queue: the process
    /// was killed between marking a row and handing its body to the daemon, or a transfer's
    /// outcome was never recorded. Nothing selects `uploading` rows for upload, yet they count
    /// as outstanding, so without this they would stay owed forever. Rows whose transfer the
    /// daemon still holds are left alone.
    private func releaseOrphanedUploads() async {
        let inFlight = await uploader.inFlightTickets()
        uploadsInFlight = inFlight.count
        updateRateTicker()
        let live = Set(inFlight.map(\.localIdentifier))

        if let writer = try? database.writer() {
            try? await writer.write { db in
                let uploading = try String.fetchAll(db, sql: "SELECT local_identifier FROM backup_state WHERE state = ?",
                                                    arguments: [BackupStateRecord.State.uploading.rawValue])
                for identifier in uploading where !live.contains(identifier) {
                    try db.execute(sql: "UPDATE backup_state SET state = ? WHERE local_identifier = ?",
                                   arguments: [BackupStateRecord.State.pending.rawValue, identifier])
                }
            }
        }
        await uploader.removeOrphanedBodies()
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

    /// Step 4: hand what is left to the upload daemon, within the queue's bounds. Returns how
    /// many it queued.
    private func uploadPending() async throws -> Int {
        guard let baseURL = session.baseURL else { throw ImmichError.notConfigured }
        let client = ImmichClient(baseURL: baseURL, credentialProvider: { [session] in session.credential })

        let inFlight = await uploader.inFlightTickets()
        uploadsInFlight = inFlight.count
        let room = Self.maxQueuedUploads - inFlight.count
        guard room > 0 else { return 0 }
        var queuedBytes = inFlight.reduce(Int64(0)) { $0 + $1.byteCount }
        let live = Set(inFlight.map(\.localIdentifier))

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
                                 room])
        }
        guard !pending.isEmpty else { return 0 }

        var queued = 0
        let assets = resolver.resolve(pending)
        for identifier in pending where !live.contains(identifier) {
            try Task.checkCancellation()
            // Stop the round rather than fail the rest of it one by one; `kick` reports the wait.
            guard networkWait == nil else { break }
            guard queuedBytes < Self.maxQueuedBytes || (queued == 0 && inFlight.isEmpty) else { break }
            guard let asset = assets[identifier] else {
                try await mark(identifier, state: .ineligible, error: "Asset no longer exists")
                continue
            }
            if let bytes = await enqueueUpload(asset: asset, identifier: identifier, client: client) {
                queued += 1
                queuedBytes += bytes
            }
            await publishStatus(uploading: true)
        }
        return queued
    }

    /// Exports the original, writes its multipart body and queues it. Returns the original's
    /// size once queued; the outcome arrives later, in `record`.
    private func enqueueUpload(asset: PHAsset, identifier: String,
                               client: ImmichClient) async -> Int64? {
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
                checksumHex: export.sha1Hex,
                bodyDirectory: BackgroundUploader.bodyDirectory)
            // Per request as well as checked between items: a switch from Wi-Fi to mobile data
            // can happen while the transfer waits in the daemon.
            var request = unrestricted
            request.allowsExpensiveNetworkAccess = allowsCellular

            let ticket = BackgroundUploader.Ticket(localIdentifier: identifier,
                                                   checksumHex: export.sha1Hex,
                                                   filename: export.filename,
                                                   byteCount: export.byteCount,
                                                   bodyFilename: bodyURL.lastPathComponent,
                                                   modifiedBeforeExport: modifiedBeforeExport)
            do {
                try uploader.enqueue(request, bodyURL: bodyURL, ticket: ticket)
            } catch {
                try? FileManager.default.removeItem(at: bodyURL)
                throw error
            }
            uploadsInFlight += 1
            updateRateTicker()
            return export.byteCount
        } catch is CancellationError {
            try? await mark(identifier, state: .pending, error: nil)
        } catch where networkWait != nil || NetworkMonitor.isConnectivityError(error) {
            // Not this item's fault; spending a retry on it would eventually abandon it.
            try? await mark(identifier, state: .pending, error: nil)
        } catch {
            try? await bumpFailure(identifier, error: error.localizedDescription)
        }
        return nil
    }

    /// Records how one upload ended. Runs in whichever process hears of it, which may be one
    /// iOS launched in the background for the purpose, long after the upload was queued.
    func record(_ outcome: BackgroundUploader.Outcome) async {
        let ticket = outcome.ticket
        let identifier = ticket.localIdentifier

        var spentRetry = false
        switch outcome.result {
        case let .success(response):
            do {
                // "duplicate" is success too: the server already had these bytes.
                try await mark(identifier, state: .uploaded, error: nil, checksum: ticket.checksumHex)
                if let remoteID = response?.id {
                    let writer = try database.writer()
                    try await writer.write { db in
                        try db.execute(sql: """
                            INSERT INTO facet_links (checksum_hex, local_identifier, immich_id)
                            VALUES (?, ?, ?)
                            ON CONFLICT(checksum_hex) DO UPDATE SET
                                local_identifier = excluded.local_identifier,
                                immich_id = excluded.immich_id
                            """, arguments: [ticket.checksumHex, identifier, remoteID])
                    }
                    noteLinksChanged()
                    await queueReconcileIfEdited(identifier: identifier, immichID: remoteID,
                                                 since: ticket.modifiedBeforeExport)
                }
                Log.sync.info("Uploaded \(ticket.filename, privacy: .public) (\(ticket.byteCount) bytes)")
            } catch {
                // Left `uploading`; the next run returns it to the queue and the server's
                // duplicate check settles it without a second transfer.
                Log.sync.error("Couldn't record upload of \(ticket.filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        case let .failure(error):
            if (error as? URLError)?.code == .cancelled
                || networkWait != nil || NetworkMonitor.isConnectivityError(error) {
                // Not this item's fault; spending a retry on it would eventually abandon it.
                try? await mark(identifier, state: .pending, error: nil)
            } else {
                try? await bumpFailure(identifier, error: error.localizedDescription)
                spentRetry = true
            }
        }

        uploadsInFlight = max(0, uploadsInFlight - 1)
        updateRateTicker()
        // Refill the queue, without waiting: on a background relaunch the uploader holds the
        // system's completion handler until this returns, and a run can take minutes. Not
        // after a failure, which would send a server that is refusing uploads straight
        // through every item's retries; the next completion or kick retries it.
        if !spentRetry { scheduleRefill() }
        if uploadsInFlight == 0 && !isRunning && pendingRefill == nil {
            await status.setPhase(networkWait ?? .idle)
        }
        await publishStatus(uploading: false)
    }

    private static let refillDelay = Duration.seconds(1)

    /// Starts a run to top the queue up after an upload finishes. In the foreground it waits a
    /// moment first, so that uploads finishing close together share one run, and one dedupe
    /// request to the server, rather than each starting its own. In the background it starts
    /// at once: iOS may suspend the app as soon as the outcomes it woke it for are recorded.
    private func scheduleRefill() {
        guard pendingRefill == nil else { return }
        pendingRefill = Task {
            let active = await MainActor.run { UIApplication.shared.applicationState == .active }
            if active { try? await Task.sleep(for: Self.refillDelay) }
            pendingRefill = nil
            guard !Task.isCancelled else { return }
            await requestRun()
        }
    }

    /// While the daemon holds uploads, that is what the status reports. Each refill run
    /// passes through these steps briefly, and showing them would flash them between every
    /// upload finishing and the next.
    private func setWorkingPhase(_ phase: BackupStatusStore.Phase) async {
        await status.setPhase(uploadsInFlight > 0 ? .uploading : phase)
    }

    /// Uploads finish one at a time, and each `facetLinksDidChange` makes the timeline merge
    /// the links again, so a burst of completions is reported once.
    private func noteLinksChanged() {
        guard linksNotice == nil else { return }
        linksNotice = Task {
            try? await Task.sleep(for: .seconds(2))
            remoteLibrary.facetLinksDidChange()
            linksNotice = nil
        }
    }

    /// Feeds the info bar's rate while the daemon holds uploads and the app is running to see.
    private func updateRateTicker() {
        if uploadsInFlight > 0 {
            guard rateTicker == nil else { return }
            rateTicker = Task { [status, meter = uploader.meter] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    await status.setUploadRate(meter.bytesPerSecond())
                }
            }
        } else {
            rateTicker?.cancel()
            rateTicker = nil
        }
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
                                        since baseline: Date?) async {
        // Fetched afresh: the resolver's cached `PHAsset` is a snapshot from before the edit.
        guard let current = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
                .firstObject,
              let modified = current.modificationDate,
              baseline.map({ modified > $0 }) ?? true else { return }

        Log.sync.info("\(identifier, privacy: .public) changed during its upload; queueing a server update")
        do {
            try await remoteLibrary.enqueueLocalReconcile(localIdentifier: identifier, immichID: immichID,
                                                          mediaKind: AssetStub(current).kind)
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
    /// refreshing its counts, cannot end one: `uploading` holds while a run is active, the
    /// daemon holds uploads, or a refill is about to start.
    func publishStatus(uploading: Bool) async {
        let uploading = uploading || isRunning || uploadsInFlight > 0 || pendingRefill != nil
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

    /// Connects this engine to the identifiers the app delegate registered at launch, and to
    /// the uploader's outcomes.
    nonisolated func connectBackgroundHandler() {
        uploader.setHandler { outcome in await self.record(outcome) }
        BackgroundTaskRegistrar.setHandler(for: Self.backgroundTaskIdentifier) { task in
            guard let task = task as? BGProcessingTask else { return task.setTaskCompleted(success: false) }
            Task { await self.handleBackgroundTask(task) }
        }
        BackgroundTaskRegistrar.setHandler(for: Self.refreshTaskIdentifier) { task in
            guard let task = task as? BGAppRefreshTask else { return task.setTaskCompleted(success: false) }
            Task { await self.handleRefreshTask(task) }
        }
        BackgroundTaskRegistrar.setHandler(for: Self.backUpNowTaskIdentifier) { task in
            guard let task = task as? BGContinuedProcessingTask else { return task.setTaskCompleted(success: false) }
            Task { await self.handleBackUpNow(task) }
        }
    }

    /// Queues both kinds of wake-up: a processing task for the long work of draining a
    /// backlog, which iOS tends to grant overnight, and an app refresh for the short, more
    /// frequent wakes that queue photos taken since.
    nonisolated func scheduleBackgroundTask() {
        guard isEnabled else { return }

        let processing = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        submit(processing)

        let refresh = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        submit(refresh)
    }

    private nonisolated func submit(_ request: BGTaskRequest) {
        // Submitting an unregistered identifier raises an Objective-C exception that Swift
        // cannot catch, which aborts the process. Never submit unless registration succeeded.
        guard BackgroundTaskRegistrar.canSubmit(request.identifier) else { return }
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Log.sync.debug("Background task \(request.identifier, privacy: .public) not scheduled: \(error.localizedDescription, privacy: .public)")
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

    /// About 30 seconds: enough to find new photos and queue the first few, which the daemon
    /// then uploads after the app is suspended again.
    func handleRefreshTask(_ task: BGAppRefreshTask) async {
        scheduleBackgroundTask()
        let work = Task { await kick() }
        task.expirationHandler = { work.cancel() }
        await work.value
        task.setTaskCompleted(success: true)
    }

    // MARK: - Back Up Now

    /// Settings' "Back Up Now". A continued-processing task starts in the foreground and keeps
    /// going if the user leaves the app, with progress in a system Live Activity, so a first
    /// backup of a large library does not depend on the app staying on screen. Falls back to
    /// an ordinary foreground run when the system will not take the task.
    nonisolated func backUpNow(remaining: Int) {
        let identifier = Self.backUpNowTaskIdentifier
        guard BackgroundTaskRegistrar.canSubmit(identifier) else {
            Task { await kick() }
            return
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier,
                                                       title: "Backing up to Immich",
                                                       subtitle: Self.remainingText(remaining))
        // The user is waiting on this now; a queued start at some later moment would read as
        // the button doing nothing.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Log.sync.info("Back Up Now not accepted: \(error.localizedDescription, privacy: .public)")
            Task { await kick() }
        }
    }

    func handleBackUpNow(_ task: BGContinuedProcessingTask) async {
        let work = Task { await drain(reportingTo: task) }
        task.expirationHandler = { work.cancel() }
        let finished = await work.value
        task.setTaskCompleted(success: finished)
    }

    /// Runs until nothing is owed, or until nothing is moving: no run going, no uploads in the
    /// daemon, and nothing finished since the last look. Polls rather than awaiting each run,
    /// because the system's progress UI offers to cancel a task whose progress stalls, and one
    /// run can spend minutes hashing before the count moves.
    private func drain(reportingTo task: BGContinuedProcessingTask) async -> Bool {
        let total = max((try? await outstandingCount()) ?? 0, 1)
        task.progress.totalUnitCount = Int64(total)
        var lastRemaining = Int.max
        needsEnumeration = true

        while !Task.isCancelled {
            if currentRun == nil {
                Task { await requestRun() }
            }
            try? await Task.sleep(for: .seconds(2))

            let remaining = (try? await outstandingCount()) ?? 0
            task.progress.completedUnitCount = Int64(min(max(total - remaining, 0), total))
            task.updateTitle(task.title, subtitle: Self.remainingText(remaining))
            if remaining == 0 { return true }
            if currentRun == nil && uploadsInFlight == 0 && remaining >= lastRemaining { return false }
            lastRemaining = remaining
        }
        // The user cancelled from the Live Activity. Uploads already in the daemon carry on.
        currentRun?.cancel()
        return false
    }

    private nonisolated static func remainingText(_ remaining: Int) -> String {
        remaining == 0 ? "All backed up" : "\(remaining) to go"
    }
}
