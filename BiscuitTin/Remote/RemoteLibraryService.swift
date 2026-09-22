import Foundation
import GRDB

/// Everything `TimelineStore` needs to fold remote assets into the merged index.
///
/// Deliberately does *not* pre-filter the linked assets out. Whether a server copy should be
/// hidden behind a local one depends on the local asset still existing, which only the timeline
/// knows — a link row outlives the local file it names. Filtering here made every photo vanish
/// from the grid after Free Up Space removed its local copy (D18).
struct RemoteMergeData {
    /// Every non-trashed remote asset, newest first.
    var stubs: [AssetStub] = []
    /// immich id → the local identifier it is linked to, where one is known (D5).
    var localIdentifierByImmichID: [String: String] = [:]
    /// Local identifiers known to have a server copy.
    var linkedLocalIdentifiers: Set<String> = []

    var isEmpty: Bool { stubs.isEmpty && linkedLocalIdentifiers.isEmpty }

    /// The server copies that must be shown in their own right, given which local assets still
    /// exist. A link row alone is not enough to hide one: the local file it names may be gone.
    func remoteOnlyStubs(presentLocalIdentifiers: Set<String>) -> [AssetStub] {
        stubs.filter { stub in
            guard let immichID = stub.id.immichID,
                  let localIdentifier = localIdentifierByImmichID[immichID] else { return true }
            return !presentLocalIdentifiers.contains(localIdentifier)
        }
    }
}

/// Syncs Immich *metadata* into SQLite and serves it to the timeline (DESIGN.md §7.2, D9).
///
/// Files are never synced here — only the rows that let the grid show remote assets offline.
/// Both full and incremental sync go through `POST /sync/stream`, whose cursor Immich tracks
/// server-side per access token: `reset: true` replays the whole library, `reset: false` replays
/// only what changed since the last acknowledged position. Hard deletes arrive as explicit
/// `AssetDeleteV1` lines in that same stream, so there is no separate reconciliation sweep.
actor RemoteLibraryService {

    /// Emitted after each committed batch so the timeline can re-merge.
    nonisolated let changes: AsyncStream<Void>
    private let changesContinuation: AsyncStream<Void>.Continuation

    private let database: AppDatabase
    private let session: ImmichAuthSession
    private let clientFactory: @Sendable (URL) -> ImmichClient

    private var isSyncing = false

    private enum Cursor {
        /// Wall-clock time of the last successful sync, for display only (§13.4) — the sync
        /// cursor itself lives server-side, keyed to the access token.
        static let lastSyncedAt = "last_synced_at"
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

    /// Streams every change since the server-tracked cursor (or the whole library, when `reset`
    /// is true) and applies it in one pass. Replaces the old paged full/delta sync and the
    /// weekly hard-delete sweep alike (D9) — an `AssetDeleteV1` line removes its row immediately,
    /// on whichever call first reports it.
    func syncStream(reset: Bool = false, progress: (@Sendable (Int) -> Void)? = nil) async throws {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let client = try makeClient()
        let body: Data
        do {
            body = try await client.syncStream(types: [.assets, .assetExifs], reset: reset)
        } catch ImmichError.unauthorized {
            session.markExpired()
            throw ImmichError.unauthorized
        }

        var upserts: [String: Immich.SyncAssetV2] = [:]
        var exifs: [String: Immich.SyncAssetExifV1] = [:]
        var deletedIDs: [String] = []
        // A per-type watermark, not a per-line receipt — acking the last id of a type
        // acknowledges every line of that type before it too (verified against a live server).
        var lastAckByType: [String: String] = [:]

        for lineData in body.split(separator: UInt8(ascii: "\n")) where !lineData.isEmpty {
            try Task.checkCancellation()
            guard let header = try? JSONDecoder().decode(Immich.SyncLineHeader.self, from: lineData) else {
                continue
            }
            lastAckByType[header.type] = header.ack

            switch header.type {
            case "AssetV2":
                guard let line = try? JSONDecoder()
                    .decode(Immich.SyncLine<Immich.SyncAssetV2>.self, from: lineData) else { continue }
                upserts[line.data.id] = line.data
            case "AssetExifV1":
                guard let line = try? JSONDecoder()
                    .decode(Immich.SyncLine<Immich.SyncAssetExifV1>.self, from: lineData) else { continue }
                exifs[line.data.assetId] = line.data
            case "AssetDeleteV1":
                guard let line = try? JSONDecoder()
                    .decode(Immich.SyncLine<Immich.SyncAssetDeleteV1>.self, from: lineData) else { continue }
                deletedIDs.append(line.data.assetId)
            default:
                // "SyncCompleteV1" (end-of-batch marker) and anything not requested/handled yet —
                // degrade gracefully rather than fail the whole batch (see file header comment).
                continue
            }
            progress?(upserts.count)
        }

        try apply(upserts: upserts, exifs: exifs, deletedIDs: deletedIDs)

        // At most 3 entries (one per requested type), always well under the server's 1000-ack cap.
        if !lastAckByType.isEmpty {
            try await client.syncAck(Array(lastAckByType.values))
        }
        try setCursor(Cursor.lastSyncedAt, to: Immich.iso8601String(from: Date()))
        Log.immich.info("Sync stream applied \(upserts.count) upserts, \(deletedIDs.count) deletes")
        changesContinuation.yield()
    }

    // MARK: - Persistence

    private func apply(upserts: [String: Immich.SyncAssetV2],
                       exifs: [String: Immich.SyncAssetExifV1],
                       deletedIDs: [String]) throws {
        guard !upserts.isEmpty || !exifs.isEmpty || !deletedIDs.isEmpty else { return }
        let writer = try database.writer()

        try writer.write { db in
            for (id, asset) in upserts {
                guard asset.visibility == .timeline else {
                    // Matches the old `isVisible: true` search filter (D9): archived, hidden and
                    // locked assets never appeared in the grid, so one that turns non-timeline is
                    // dropped rather than kept in a state nothing reads.
                    try db.execute(sql: "DELETE FROM remote_assets WHERE immich_id = ?", arguments: [id])
                    continue
                }

                var record = try RemoteAssetRecord.filter(key: id).fetchOne(db)
                    ?? RemoteAssetRecord(placeholderID: id)
                record.apply(asset)
                if let exif = exifs[id] { record.apply(exif) }
                try record.save(db)

                guard !record.checksumHex.isEmpty else { continue }
                // Checksum-only link; M6 fills in the local identifier once computed. (v3.1.0
                // never reports `deviceAssetId`/`deviceId` on this DTO, so the immediate-link
                // fast path from the old `search/metadata` client cannot apply here either — it
                // was already dead on this server version; see `Immich.Asset`'s own comment.)
                try db.execute(sql: """
                    INSERT INTO facet_links (checksum_hex, local_identifier, immich_id)
                    VALUES (?, NULL, ?)
                    ON CONFLICT(checksum_hex) DO UPDATE SET immich_id = excluded.immich_id
                    """, arguments: [record.checksumHex, id])
            }

            // EXIF lines for assets not touched by an upsert this batch: merge onto whatever is
            // already cached, if anything. An asset this device has never synced has nowhere to
            // attach the EXIF yet — it arrives paired with its asset on a future `reset` sync.
            for (id, exif) in exifs where upserts[id] == nil {
                guard var record = try RemoteAssetRecord.filter(key: id).fetchOne(db) else { continue }
                record.apply(exif)
                try record.save(db)
            }

            guard !deletedIDs.isEmpty else { return }
            let placeholders = databaseQuestionMarks(count: deletedIDs.count)
            try db.execute(sql: "DELETE FROM remote_assets WHERE immich_id IN (\(placeholders))",
                           arguments: StatementArguments(deletedIDs))
            try db.execute(sql: "UPDATE facet_links SET immich_id = NULL WHERE immich_id IN (\(placeholders))",
                           arguments: StatementArguments(deletedIDs))
        }
    }

    /// Reads what the timeline needs for its merge. Runs off the main thread by construction.
    func mergeData() throws -> RemoteMergeData {
        guard database.isOpen || session.isConfigured else { return RemoteMergeData() }
        let writer = try database.writer()

        return try writer.read { db in
            var data = RemoteMergeData()

            for link in try FacetLinkRecord.fetchAll(db) {
                guard let localIdentifier = link.localIdentifier, let immichID = link.immichID else {
                    continue
                }
                data.localIdentifierByImmichID[immichID] = localIdentifier
                data.linkedLocalIdentifiers.insert(localIdentifier)
            }

            data.stubs = try RemoteAssetRecord
                .filter(sql: "is_trashed = 0")
                .order(sql: "capture_at DESC")
                .fetchAll(db)
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
        guard let cursor = try? getCursor(Cursor.lastSyncedAt) else { return nil }
        return Immich.parseDate(cursor)
    }
}

/// `?,?,?` for an IN clause of the given size.
func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ",")
}
