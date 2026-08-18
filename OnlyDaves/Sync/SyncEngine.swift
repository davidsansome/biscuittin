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

    static let backgroundTaskIdentifier = "dev.onlydaves.sync"
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

    private var isRunning = false
    private var uploadsInFlight = 0

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
        guard isEnabled, session.isConfigured, localLibrary.hasAnyAccess else {
            await publishStatus(uploading: false)
            return
        }
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        do {
            try await enumerateLibrary()
            await publishStatus(uploading: true)

            // Checksum, dedupe and upload in rounds until the queue stops shrinking, so one
            // kick drains the backlog instead of leaving most of it for the next trigger.
            while true {
                try Task.checkCancellation()
                let before = try await outstandingCount()
                guard before > 0 else { break }

                try await computeMissingChecksums()
                try await dedupeAgainstServer()
                try await uploadPending()
                await publishStatus(uploading: true)

                let after = try await outstandingCount()
                if after >= before { break }   // no progress this round: stop rather than spin
            }
        } catch is CancellationError {
            // Leave state as-is; the next kick resumes.
        } catch {
            Log.sync.error("Sync failed: \(error.localizedDescription, privacy: .public)")
            await status.setError((error as? LocalizedError)?.errorDescription
                                  ?? error.localizedDescription)
        }
        await publishStatus(uploading: false)
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

    /// Step 2: checksum assets we have not hashed yet.
    private func computeMissingChecksums() async throws {
        let writer = try database.writer()
        let identifiers = try await writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT local_identifier FROM backup_state
                WHERE checksum_hex IS NULL AND state = ?
                LIMIT ?
                """, arguments: [BackupStateRecord.State.pending.rawValue, Self.checksumBatchSize])
        }
        guard !identifiers.isEmpty else { return }

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
            } catch {
                try await mark(identifier, state: .ineligible, error: error.localizedDescription)
            }
        }
    }

    /// Step 3: ask the server which checksums it already has. Duplicates are marked uploaded
    /// without transferring anything.
    private func dedupeAgainstServer() async throws {
        guard let baseURL = session.baseURL else { throw ImmichError.notConfigured }
        let client = ImmichClient(baseURL: baseURL, tokenProvider: { [session] in session.token })

        let writer = try database.writer()
        let candidates = try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT local_identifier, checksum_hex FROM backup_state
                WHERE state = ? AND checksum_hex IS NOT NULL
                LIMIT ?
                """, arguments: [BackupStateRecord.State.pending.rawValue, Self.checksumBatchSize])
        }
        guard !candidates.isEmpty else { return }

        let items = candidates.map {
            Immich.BulkUploadCheckItem(id: $0["local_identifier"], checksum: $0["checksum_hex"])
        }
        let response = try await client.bulkUploadCheck(items)

        for result in response.results where result.action == "reject" {
            guard result.reason == "duplicate" else { continue }
            try await mark(result.id, state: .uploaded, error: nil)
            if let assetID = result.assetId {
                try await writer.write { db in
                    try db.execute(sql: """
                        UPDATE facet_links SET immich_id = ?
                        WHERE local_identifier = ?
                        """, arguments: [assetID, result.id])
                }
            }
        }
    }

    /// Step 4: upload what is left.
    private func uploadPending() async throws {
        guard let baseURL = session.baseURL else { throw ImmichError.notConfigured }
        let client = ImmichClient(baseURL: baseURL, tokenProvider: { [session] in session.token })

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
        guard !pending.isEmpty else { return }

        let assets = resolver.resolve(pending)
        for identifier in pending {
            try Task.checkCancellation()
            guard let asset = assets[identifier] else {
                try await mark(identifier, state: .ineligible, error: "Asset no longer exists")
                continue
            }
            await upload(asset: asset, identifier: identifier, client: client)
            await publishStatus(uploading: true)
        }
    }

    private func upload(asset: PHAsset, identifier: String, client: ImmichClient) async {
        do {
            try await mark(identifier, state: .uploading, error: nil)
            let export = try await exporter.export(asset: asset)
            defer { try? FileManager.default.removeItem(at: export.fileURL) }

            let (request, bodyURL) = try await client.makeUploadRequest(
                fileURL: export.fileURL,
                deviceAssetId: identifier,
                deviceId: session.deviceID,
                fileCreatedAt: export.createdAt,
                fileModifiedAt: export.modifiedAt,
                filename: export.filename,
                checksumHex: export.sha1Hex)
            defer { try? FileManager.default.removeItem(at: bodyURL) }

            let response = try await UploadTask.perform(request: request, bodyURL: bodyURL)

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
            }
            Log.sync.info("Uploaded \(export.filename, privacy: .public) (\(export.byteCount) bytes)")
        } catch is CancellationError {
            try? await mark(identifier, state: .pending, error: nil)
        } catch {
            try? await bumpFailure(identifier, error: error.localizedDescription)
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

    /// Recomputes the badge count (requirement 14).
    func publishStatus(uploading: Bool) async {
        let enabled = isEnabled
        var remaining = 0
        if let writer = try? database.writer() {
            remaining = (try? await writer.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM backup_state WHERE state IN (?, ?, ?)
                    """, arguments: StatementArguments(BackupStateRecord.outstandingStates)) ?? 0
            }) ?? 0
        }
        await status.update(remaining: remaining, uploading: uploading, enabled: enabled)
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

        let work = Task { await kick() }
        task.expirationHandler = { work.cancel() }
        await work.value
        task.setTaskCompleted(success: true)
    }
}

/// Performs one upload. Kept separate so the transport can move to a true background
/// `URLSession` without touching the engine's state machine.
enum UploadTask {
    static func perform(request: URLRequest, bodyURL: URL) async throws -> Immich.UploadResponse? {
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: bodyURL)
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
