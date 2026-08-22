import Foundation
import GRDB

/// Everything `TimelineStore` needs to fold remote assets into the merged index.
struct RemoteMergeData {
    /// Remote-only candidates, newest first.
    var stubs: [AssetStub] = []
    /// Local identifiers already known to have a server copy (D5).
    var linkedLocalIdentifiers: Set<String> = []
    /// Immich ids reachable through a linked local asset, so they are not added twice.
    var linkedImmichIDs: Set<String> = []

    var isEmpty: Bool { stubs.isEmpty && linkedLocalIdentifiers.isEmpty }
}

/// Syncs Immich *metadata* into SQLite and serves it to the timeline (DESIGN.md §7.2, D9).
///
/// Files are never synced here — only the rows that let the grid show remote assets offline.
/// Full sync pages `search/metadata`; delta sync replays the same endpoint with an
/// `updatedAfter` cursor.
actor RemoteLibraryService {

    /// Emitted after each committed batch so the timeline can re-merge.
    nonisolated let changes: AsyncStream<Void>
    private let changesContinuation: AsyncStream<Void>.Continuation

    private let database: AppDatabase
    private let session: ImmichAuthSession
    private let clientFactory: @Sendable (URL) -> ImmichClient

    private var isSyncing = false

    private enum Cursor {
        static let lastSync = "last_sync_cursor"
        static let lastFullSweep = "last_full_sweep"
    }

    init(database: AppDatabase,
         session: ImmichAuthSession,
         clientFactory: (@Sendable (URL) -> ImmichClient)? = nil) {
        self.database = database
        self.session = session
        self.clientFactory = clientFactory ?? { url in
            ImmichClient(baseURL: url, tokenProvider: { session.token })
        }
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        changes = stream
        changesContinuation = continuation
    }

    deinit { changesContinuation.finish() }

    nonisolated var isConfigured: Bool { session.isConfigured }

    private func makeClient() throws -> ImmichClient {
        guard let baseURL = session.baseURL, session.token != nil else {
            throw ImmichError.notConfigured
        }
        return clientFactory(baseURL)
    }

    // MARK: - Sync

    /// First run against a server: pages the entire library into SQLite.
    func fullSync(progress: (@Sendable (Int) -> Void)? = nil) async throws {
        try await sync(updatedAfter: nil, progress: progress)
        try setCursor(Cursor.lastFullSweep, to: Immich.iso8601String(from: Date()))
    }

    /// Incremental catch-up using the stored cursor.
    func deltaSync() async throws {
        let cursor = try getCursor(Cursor.lastSync)
        try await sync(updatedAfter: cursor, progress: nil)
    }

    private func sync(updatedAfter: String?, progress: (@Sendable (Int) -> Void)?) async throws {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let client = try makeClient()
        // Recorded before the first request so assets changed mid-sync are picked up next time
        // rather than being skipped.
        let startedAt = Date()

        var page = 1
        var imported = 0

        while true {
            try Task.checkCancellation()
            var request = Immich.MetadataSearchRequest()
            request.page = page
            request.updatedAfter = updatedAfter

            let result: Immich.SearchPage
            do {
                result = try await client.searchAssets(request)
            } catch ImmichError.unauthorized {
                session.markExpired()
                throw ImmichError.unauthorized
            }

            let assets = result.assets.items
            if result.assets.skippedCount > 0 {
                Log.immich.error("Sync skipped \(result.assets.skippedCount) undecodable assets")
            }
            guard !assets.isEmpty else { break }

            try store(assets)
            imported += assets.count
            progress?(imported)
            changesContinuation.yield()

            guard let next = result.assets.nextPage, let nextPage = Int(next) else { break }
            page = nextPage
        }

        try setCursor(Cursor.lastSync, to: Immich.iso8601String(from: startedAt))
        Log.immich.info("Metadata sync imported \(imported) assets")
        changesContinuation.yield()
    }

    /// Immich reports trashing through `isTrashed`, but a hard delete simply stops appearing.
    /// A periodic sweep re-pages everything and drops rows the server no longer lists (D9).
    func reconcileDeletions() async throws {
        let client = try makeClient()
        var seen = Set<String>()
        var page = 1

        while true {
            try Task.checkCancellation()
            var request = Immich.MetadataSearchRequest()
            request.page = page
            let result = try await client.searchAssets(request)
            let assets = result.assets.items
            guard !assets.isEmpty else { break }
            seen.formUnion(assets.map(\.id))
            try store(assets)
            guard let next = result.assets.nextPage, let nextPage = Int(next) else { break }
            page = nextPage
        }

        let writer = try database.writer()
        let removed = try await writer.write { db -> Int in
            let all = try String.fetchAll(db, sql: "SELECT immich_id FROM remote_assets")
            let stale = all.filter { !seen.contains($0) }
            guard !stale.isEmpty else { return 0 }
            let placeholders = databaseQuestionMarks(count: stale.count)
            try db.execute(sql: "DELETE FROM remote_assets WHERE immich_id IN (\(placeholders))",
                           arguments: StatementArguments(stale))
            try db.execute(sql: "UPDATE facet_links SET immich_id = NULL WHERE immich_id IN (\(placeholders))",
                           arguments: StatementArguments(stale))
            return stale.count
        }
        if removed > 0 { Log.immich.info("Reconcile removed \(removed) stale remote rows") }
        try setCursor(Cursor.lastFullSweep, to: Immich.iso8601String(from: Date()))
        changesContinuation.yield()
    }

    // MARK: - Persistence

    private func store(_ assets: [Immich.Asset]) throws {
        let writer = try database.writer()
        let ourDeviceID = session.deviceID

        try writer.write { db in
            for asset in assets {
                let record = RemoteAssetRecord(asset)
                try record.save(db)

                // Our own uploads carry the PhotoKit identifier, so they link immediately
                // without waiting for a checksum pass (D5).
                if let deviceAssetID = asset.deviceAssetId,
                   asset.deviceId == ourDeviceID,
                   !record.checksumHex.isEmpty {
                    try FacetLinkRecord(checksumHex: record.checksumHex,
                                        localIdentifier: deviceAssetID,
                                        immichID: asset.id).save(db)
                } else if !record.checksumHex.isEmpty {
                    // Checksum-only row; M6 fills in the local identifier once computed.
                    try db.execute(sql: """
                        INSERT INTO facet_links (checksum_hex, local_identifier, immich_id)
                        VALUES (?, NULL, ?)
                        ON CONFLICT(checksum_hex) DO UPDATE SET immich_id = excluded.immich_id
                        """, arguments: [record.checksumHex, asset.id])
                }
            }
        }
    }

    /// Reads what the timeline needs for its merge. Runs off the main thread by construction.
    func mergeData() throws -> RemoteMergeData {
        guard database.isOpen || session.isConfigured else { return RemoteMergeData() }
        let writer = try database.writer()

        return try writer.read { db in
            var data = RemoteMergeData()

            let links = try FacetLinkRecord.fetchAll(db)
            var immichToLocal = [String: String]()
            for link in links {
                guard let localIdentifier = link.localIdentifier, let immichID = link.immichID else {
                    continue
                }
                immichToLocal[immichID] = localIdentifier
                data.linkedLocalIdentifiers.insert(localIdentifier)
                data.linkedImmichIDs.insert(immichID)
            }

            let records = try RemoteAssetRecord
                .filter(sql: "is_trashed = 0")
                .order(sql: "capture_at DESC")
                .fetchAll(db)

            data.stubs = records
                .filter { immichToLocal[$0.immichID] == nil }
                .map(\.stub)
            return data
        }
    }

    func record(for immichID: String) throws -> RemoteAssetRecord? {
        try database.writer().read { db in
            try RemoteAssetRecord.filter(key: immichID).fetchOne(db)
        }
    }

    /// Local identifiers whose server copy is verified present (D18).
    ///
    /// Requires all three: a checksum link carrying both sides, a `backup_state` of `uploaded`,
    /// and a matching remote row that is not trashed. Anything less and the local copy might be
    /// the only one.
    func locallyDeletableIdentifiers() throws -> [String] {
        try database.writer().read { db in
            try String.fetchAll(db, sql: """
                SELECT l.local_identifier
                FROM facet_links l
                JOIN backup_state b ON b.local_identifier = l.local_identifier
                JOIN remote_assets r ON r.immich_id = l.immich_id
                WHERE l.local_identifier IS NOT NULL
                  AND l.immich_id IS NOT NULL
                  AND b.state = 'uploaded'
                  AND r.is_trashed = 0
                """)
        }
    }

    /// True when the periodic hard-delete sweep is due (D9).
    func needsDeletionSweep(interval: TimeInterval = 7 * 24 * 3600) -> Bool {
        guard let raw = try? getCursor(Cursor.lastFullSweep),
              let last = Immich.parseDate(raw) else { return true }
        return Date().timeIntervalSince(last) > interval
    }

    /// The Immich id paired with a local asset, when one is known.
    func immichID(forLocalIdentifier localIdentifier: String) throws -> String? {
        try database.writer().read { db in
            try String.fetchOne(db, sql: """
                SELECT immich_id FROM facet_links
                WHERE local_identifier = ? AND immich_id IS NOT NULL
                """, arguments: [localIdentifier])
        }
    }

    // MARK: - Remote mutations

    /// Rotates the server's copy (M7, D10).
    ///
    /// Immich v3.1.0 has **no endpoint that replaces an existing asset's file** — verified
    /// against a real server: `PUT/POST /api/assets/{id}/original`, `/file` and `/replace` all
    /// return the route-missing response, and there is no server-side edit or rotate route
    /// either. So "rotate the server copy" has to be expressed as upload-the-rotated-file then
    /// trash the old asset.
    ///
    /// The replacement is uploaded with the original's `fileCreatedAt`/`fileModifiedAt`, which
    /// v3.1.0 honours (it echoes them back, including in `localDateTime`). Without that the new
    /// asset would take "now" as its capture date and jump to the top of the timeline.
    ///
    /// Caveat worth knowing: the rotated copy is a *new* asset id, so server-side album
    /// membership, favourites and ratings for that photo do not carry over.
    func rotateRemote(immichID: String, clockwise: Bool, rotator: any AssetRotator) async throws {
        let client = try makeClient()
        guard let record = try record(for: immichID) else { throw ImmichError.notConfigured }
        let filename = record.fileName ?? "\(immichID).jpg"

        let data = try await client.originalData(id: immichID)
        let downloaded = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-rotate-\(UUID().uuidString)-\(filename)")
        try data.write(to: downloaded, options: .atomic)
        defer { try? FileManager.default.removeItem(at: downloaded) }

        let rotated = try await rotator.rotateRemoteOriginal(fileURL: downloaded, clockwise: clockwise)
        defer { try? FileManager.default.removeItem(at: rotated) }

        let captured = Date(timeIntervalSince1970: record.captureAt)
        let newID = try await client.uploadReplacement(fileURL: rotated,
                                                       filename: filename,
                                                       deviceID: session.deviceID,
                                                       fileCreatedAt: captured,
                                                       fileModifiedAt: captured)

        // The multipart timestamps only stick when the file carries no date of its own, which
        // is true of a rotated JPEG but not a remuxed video. Set it explicitly so a rotated
        // video keeps its place in the timeline instead of resurfacing as if shot just now.
        try await client.updateCaptureDate(id: newID, to: captured)

        // Only trash the original once the replacement is safely stored.
        try await client.deleteAssets(ids: [immichID])

        try await repointAfterRotation(oldID: immichID, newID: newID, record: record)
        changesContinuation.yield()
    }

    /// Swaps the rotated asset in for the old one locally, so the grid updates without waiting
    /// for the next metadata sync.
    private func repointAfterRotation(oldID: String,
                                      newID: String,
                                      record: RemoteAssetRecord) async throws {
        let writer = try database.writer()
        try await writer.write { db in
            var rotated = record
            rotated.immichID = newID
            // Dimensions swap on a quarter turn; the checksum changed, and the next sync will
            // replace this row with the server's authoritative copy anyway.
            rotated.width = record.height
            rotated.height = record.width
            rotated.updatedAt = Date().timeIntervalSince1970
            try rotated.save(db)

            try db.execute(sql: "DELETE FROM remote_assets WHERE immich_id = ?", arguments: [oldID])
            try db.execute(sql: "UPDATE facet_links SET immich_id = ? WHERE immich_id = ?",
                           arguments: [newID, oldID])
        }
    }

    private func writeSwappedDimensions(immichID: String) async throws {
        let writer = try database.writer()
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE remote_assets SET width = height, height = width, updated_at = ?
                WHERE immich_id = ?
                """, arguments: [Date().timeIntervalSince1970, immichID])
        }
    }

    func deleteRemote(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let client = try makeClient()
        try await client.deleteAssets(ids: ids)

        let writer = try database.writer()
        try await writer.write { db in
            let placeholders = databaseQuestionMarks(count: ids.count)
            try db.execute(sql: "UPDATE remote_assets SET is_trashed = 1 WHERE immich_id IN (\(placeholders))",
                           arguments: StatementArguments(ids))
        }
        changesContinuation.yield()
    }

    /// Clears cached server data without touching the device library.
    func wipeCache() throws {
        let writer = try database.writer()
        try writer.write { db in
            try db.execute(sql: "DELETE FROM remote_assets")
            try db.execute(sql: "DELETE FROM facet_links")
            try db.execute(sql: "DELETE FROM kv")
        }
        changesContinuation.yield()
    }

    // MARK: - Cursors

    private func getCursor(_ key: String) throws -> String? {
        try database.writer().read { db in
            try String.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: [key])
        }
    }

    private func setCursor(_ key: String, to value: String) throws {
        try database.writer().write { db in
            try db.execute(sql: "INSERT INTO kv (key, value) VALUES (?, ?) "
                           + "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [key, value])
        }
    }

    func lastSyncDate() -> Date? {
        guard let cursor = try? getCursor(Cursor.lastSync) else { return nil }
        return Immich.parseDate(cursor)
    }
}

/// `?,?,?` for an IN clause of the given size.
func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ",")
}
