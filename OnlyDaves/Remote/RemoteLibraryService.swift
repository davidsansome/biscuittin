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
