import Foundation
import GRDB
import Photos

/// Everything `TimelineStore` needs to fold remote assets into the merged index.
///
/// Deliberately does *not* pre-filter the linked assets out. Whether a server copy should be
/// hidden behind a local one depends on the local asset still existing, which only the timeline
/// knows — a link row outlives the local file it names. Filtering here made every photo vanish
/// from the grid after Free Up Space removed its local copy (D18).
/// What a committed change to the metadata cache touched, so the timeline can re-read only that.
enum RemoteChange: Sendable, Equatable {
    /// Rows for these server assets may have been added, changed, trashed or removed.
    case assets(Set<String>)
    /// Only `facet_links` changed. The timeline re-reads links on every rebuild anyway.
    case links
    /// Anything may have changed.
    case all
}

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
    nonisolated let changes: AsyncStream<RemoteChange>

    /// Posted when partner sharing data (§22) may have changed: who shares with the user, or
    /// what is in their libraries. Kept off `changes`, which drives the timeline — a partner's
    /// photos are not part of it and must not cost it a rebuild.
    static let partnersDidChangeNotification = Notification.Name("RemoteLibraryService.partnersDidChange")
    private let changesContinuation: AsyncStream<RemoteChange>.Continuation

    private let database: AppDatabase
    private let session: ImmichAuthSession
    private let clientFactory: @Sendable (URL) -> ImmichClient
    /// Only needed for D22's pending-edit reconciliation: resolving a local facet's current
    /// state, exporting it, and picking a rotator for a remote-only retry.
    private let resolver: PHAssetResolver
    private let exporter: LocalAssetExporter
    private let registry: RotatorRegistry

    private var isSyncing = false

    private static let maxEditRetries = 5

    private enum Cursor {
        /// Wall-clock time of the last successful sync, for display only (§13.4) — the sync
        /// cursor itself lives server-side, keyed to the access token.
        static let lastSyncedAt = "last_synced_at"
        /// Base URL and account whose server data the cache holds.
        static let cacheOwner = "cache_owner"
    }

    init(database: AppDatabase,
         session: ImmichAuthSession,
         resolver: PHAssetResolver,
         exporter: LocalAssetExporter,
         registry: RotatorRegistry = .v1,
         clientFactory: (@Sendable (URL) -> ImmichClient)? = nil) {
        self.database = database
        self.session = session
        self.resolver = resolver
        self.exporter = exporter
        self.registry = registry
        self.clientFactory = clientFactory ?? { url in
            ImmichClient(baseURL: url, credentialProvider: { session.credential })
        }
        // Unbounded: each event names what changed, and the timeline caches rows between them,
        // so a dropped event would leave it showing stale rows until relaunch.
        let (stream, continuation) = AsyncStream<RemoteChange>.makeStream()
        changes = stream
        changesContinuation = continuation
    }

    deinit { changesContinuation.finish() }

    nonisolated var isConfigured: Bool { session.isConfigured }

    private func makeClient() throws -> ImmichClient {
        guard let baseURL = session.baseURL, session.credential != nil else {
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
            body = try await client.syncStream(types: [.assets, .assetExifs, .authUsers, .users, .partners,
                                                       .partnerAssets, .partnerAssetExifs],
                                               reset: reset)
        } catch ImmichError.unauthorized {
            session.markExpired()
            throw ImmichError.unauthorized
        }

        var upserts: [String: Immich.SyncAssetV2] = [:]
        var exifs: [String: Immich.SyncAssetExifV1] = [:]
        var deletedIDs: [String] = []
        var partnerBatch = PartnerSyncBatch()
        var acks = Immich.SyncAcks()

        for lineData in body.split(separator: UInt8(ascii: "\n")) where !lineData.isEmpty {
            try Task.checkCancellation()
            guard let header = try? JSONDecoder().decode(Immich.SyncLineHeader.self, from: lineData) else {
                continue
            }
            acks.record(header.ack)

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
                if partnerBatch.add(type: header.type, line: Data(lineData)) { continue }
                // "SyncCompleteV1" (end-of-batch marker), "SyncAckV1" (end of a partner's
                // backfill) and anything not requested/handled yet — degrade gracefully rather
                // than fail the whole batch (see file header comment).
                continue
            }
            progress?(upserts.count)
        }

        // Signing out mid-download wipes the cache; applying this afterwards would put the
        // signed-out server's assets back.
        guard session.isConfigured else { throw CancellationError() }
        try apply(upserts: upserts, exifs: exifs, deletedIDs: deletedIDs, partners: partnerBatch)

        // One entry per checkpoint the stream touched — a dozen or so, well under the server's
        // 1000-ack cap.
        if !acks.all.isEmpty {
            try await client.syncAck(acks.all)
        }
        try setCursor(Cursor.lastSyncedAt, to: Immich.iso8601String(from: Date()))
        Log.immich.info("Sync stream applied \(upserts.count) upserts, \(deletedIDs.count) deletes")
        if !partnerBatch.isEmpty {
            Log.device("immich", "Sync stream applied partner data: \(partnerBatch.assets.count) assets, "
                       + "\(partnerBatch.shares.count) shares")
            postPartnersDidChange()
        }
        // Every yield costs the timeline a rebuild.
        let changedIDs = Set(upserts.keys).union(exifs.keys).union(deletedIDs)
        if !changedIDs.isEmpty {
            changesContinuation.yield(.assets(changedIDs))
        }
    }

    // MARK: - Persistence

    private func apply(upserts: [String: Immich.SyncAssetV2],
                       exifs: [String: Immich.SyncAssetExifV1],
                       deletedIDs: [String],
                       partners: PartnerSyncBatch) throws {
        guard !upserts.isEmpty || !exifs.isEmpty || !deletedIDs.isEmpty || !partners.isEmpty else { return }
        let writer = try database.writer()

        try writer.write { db in
            try PartnerStore.apply(partners, in: db)
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

    /// True when there cannot be anything cached, so reads can skip opening the database.
    private var hasNoCache: Bool { !database.isOpen && !session.isConfigured }

    /// Every complete local↔server link, immich id → local identifier. Runs off the main thread
    /// by construction.
    func links() throws -> [String: String] {
        guard !hasNoCache else { return [:] }
        return try database.writer().read { db in
            try Self.links(in: db, sql: """
                SELECT immich_id, local_identifier FROM facet_links
                WHERE immich_id IS NOT NULL AND local_identifier IS NOT NULL
                """)
        }
    }

    /// The complete links among `immichIDs`. An id missing from the result has none.
    func links(immichIDs: Set<String>) throws -> [String: String] {
        guard !hasNoCache, !immichIDs.isEmpty else { return [:] }
        let all = Array(immichIDs)
        return try database.writer().read { db in
            var links = [String: String]()
            // Stays well under SQLite's bound-parameter limit.
            for start in stride(from: 0, to: all.count, by: 500) {
                let chunk = Array(all[start..<min(start + 500, all.count)])
                links.merge(try Self.links(in: db, sql: """
                    SELECT immich_id, local_identifier FROM facet_links
                    WHERE local_identifier IS NOT NULL
                      AND immich_id IN (\(databaseQuestionMarks(count: chunk.count)))
                    """, arguments: StatementArguments(chunk))) { $1 }
            }
            return links
        }
    }

    private static func links(in db: Database, sql: String,
                              arguments: StatementArguments = StatementArguments()) throws -> [String: String] {
        var links = [String: String]()
        for row in try Row.fetchAll(db, sql: sql, arguments: arguments) {
            links[row[0] as String] = row[1] as String
        }
        return links
    }

    /// Every non-trashed server asset, newest first.
    func remoteStubs() throws -> [AssetStub] {
        guard !hasNoCache else { return [] }
        return try database.writer().read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(RemoteAssetRecord.stubColumns) FROM remote_assets
                WHERE is_trashed = 0 ORDER BY capture_at DESC
                """).map(RemoteAssetRecord.stub(row:))
        }
    }

    /// The non-trashed stubs among `ids`. An id missing from the result has no visible row.
    func remoteStubs(ids: Set<String>) throws -> [AssetStub] {
        guard !hasNoCache, !ids.isEmpty else { return [] }
        let all = Array(ids)
        return try database.writer().read { db in
            var stubs = [AssetStub]()
            // Stays well under SQLite's bound-parameter limit.
            for start in stride(from: 0, to: all.count, by: 500) {
                let chunk = Array(all[start..<min(start + 500, all.count)])
                stubs += try Row.fetchAll(db, sql: """
                    SELECT \(RemoteAssetRecord.stubColumns) FROM remote_assets
                    WHERE is_trashed = 0 AND immich_id IN (\(databaseQuestionMarks(count: chunk.count)))
                    """, arguments: StatementArguments(chunk)).map(RemoteAssetRecord.stub(row:))
            }
            return stubs
        }
    }

    // MARK: - Partner sharing (§22)

    /// Everyone sharing their library with the signed-in user, by name.
    func partners() throws -> [Partner] {
        guard !hasNoCache else { return [] }
        return try database.writer().read { db in try PartnerStore.partners(in: db) }
    }

    /// One partner's visible assets, newest first.
    func partnerStubs(ownerID: String) throws -> [AssetStub] {
        guard !hasNoCache else { return [] }
        return try database.writer().read { db in try PartnerStore.stubs(ownerID: ownerID, in: db) }
    }

    private nonisolated func postPartnersDidChange() {
        NotificationCenter.default.post(name: Self.partnersDidChangeNotification, object: self)
    }

    /// For writers outside this actor — `SyncEngine` links facets as it checksums and uploads.
    nonisolated func facetLinksDidChange() {
        changesContinuation.yield(.links)
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
        let record = try await remoteRecord(for: immichID, client: client)
        let filename = record.fileName ?? "\(immichID).jpg"

        let data = try await client.originalData(id: immichID)
        let downloaded = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-rotate-\(UUID().uuidString)-\(filename)")
        try data.write(to: downloaded, options: .atomic)
        defer { try? FileManager.default.removeItem(at: downloaded) }

        let rotated = try await rotator.rotateRemoteOriginal(fileURL: downloaded, clockwise: clockwise)
        defer { try? FileManager.default.removeItem(at: rotated) }

        try await replaceRemoteFile(oldID: immichID, fileURL: rotated, filename: filename, record: record)
    }

    /// The cached row for `immichID`, or the server's own description of the asset when there
    /// is none yet.
    ///
    /// A photo this device has just uploaded is linked in `facet_links` straight away, so the
    /// timeline shows it as on the server, but its `remote_assets` row only arrives with the
    /// next sync stream — which runs on launch, foreground and pull-to-refresh, not after an
    /// upload. Requiring the cached row made every rotation in that window fail its server leg.
    func remoteRecord(for immichID: String, client: ImmichClient) async throws -> RemoteAssetRecord {
        if let cached = try record(for: immichID) { return cached }
        return RemoteAssetRecord(try await client.assetInfo(id: immichID))
    }

    /// Uploads `fileURL` as `oldID`'s replacement, retires the original, and repoints local
    /// state to the new id. Shared by `rotateRemote` (rotate the remote's own download) and
    /// `reconcileFromLocalFacet` (push a local edit's current rendition) — both end the same
    /// way: a new asset id replacing an old one, verified safe to retire only once the
    /// replacement is stored.
    private func replaceRemoteFile(oldID: String, fileURL: URL, filename: String,
                                   record: RemoteAssetRecord,
                                   width: Int? = nil, height: Int? = nil,
                                   checksumHex: String? = nil) async throws {
        let client = try makeClient()
        let captured = Date(timeIntervalSince1970: record.captureAt)
        let newID = try await client.uploadReplacement(fileURL: fileURL,
                                                       filename: filename,
                                                       deviceID: session.deviceID,
                                                       fileCreatedAt: captured,
                                                       fileModifiedAt: captured)

        // The multipart timestamps only stick when the file carries no date of its own, which
        // is true of a rotated JPEG but not a remuxed video. Set it explicitly so a rotated
        // video keeps its place in the timeline instead of resurfacing as if shot just now.
        try await client.updateCaptureDate(id: newID, to: captured)

        // Only trash the original once the replacement is safely stored.
        try await client.deleteAssets(ids: [oldID])

        try await repointAfterRotation(oldID: oldID, newID: newID, record: record,
                                       width: width, height: height, checksumHex: checksumHex)
    }

    /// Swaps the rotated asset in for the old one locally, so the grid updates without waiting
    /// for the next metadata sync.
    ///
    /// `width`/`height` let a caller supply the *authoritative* new dimensions — needed by D22's
    /// state-based reconciliation, where the local rendition may reflect any number of composed
    /// edits, not necessarily one quarter turn. Omitting them keeps `rotateRemote`'s existing
    /// swap-on-a-quarter-turn behaviour, which is exactly right for that single-turn call site.
    private func repointAfterRotation(oldID: String,
                                      newID: String,
                                      record: RemoteAssetRecord,
                                      width: Int? = nil,
                                      height: Int? = nil,
                                      checksumHex: String? = nil) async throws {
        let writer = try database.writer()
        try await writer.write { db in
            var rotated = record
            rotated.immichID = newID
            // Known when the uploaded bytes were hashed here, and lets a repeated reconcile of
            // the same rendition see that there is nothing left to push.
            if let checksumHex { rotated.checksumHex = checksumHex }
            // The checksum changed and the next sync will replace this row with the server's
            // authoritative copy anyway — this is an optimistic bridge until then.
            rotated.width = width ?? record.height
            rotated.height = height ?? record.width
            rotated.updatedAt = Date().timeIntervalSince1970
            try rotated.save(db)

            try db.execute(sql: "DELETE FROM remote_assets WHERE immich_id = ?", arguments: [oldID])
            try db.execute(sql: "UPDATE facet_links SET immich_id = ? WHERE immich_id = ?",
                           arguments: [newID, oldID])
        }
        // Every rotation and pending-edit retry ends here.
        changesContinuation.yield(.assets([oldID, newID]))
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
        changesContinuation.yield(.assets(Set(ids)))
    }

    /// Clears cached server data without touching the device library.
    func wipeCache() throws {
        try database.writer().write { db in try Self.wipe(db) }
        changesContinuation.yield(.all)
        postPartnersDidChange()
    }

    /// Wipes the cache unless it was filled by `owner`, then records `owner` as filling it.
    /// Returns whether it wiped.
    ///
    /// Sign Out keeps the cache so it stays browsable offline (§13), so without this a sign-in
    /// to another server or account kept the old one's assets in the grid, where their images
    /// could no longer be fetched. A cache from before owners were recorded is treated as
    /// someone else's; sign-in replays the whole library regardless, so that costs no downloads.
    @discardableResult
    func claimCache(for owner: String) throws -> Bool {
        let wiped = try database.writer().write { db -> Bool in
            let current = try String.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?",
                                              arguments: [Cursor.cacheOwner])
            guard current != owner else { return false }
            try Self.wipe(db)
            try db.execute(sql: "INSERT INTO kv (key, value) VALUES (?, ?)",
                           arguments: [Cursor.cacheOwner, owner])
            return true
        }
        if wiped {
            changesContinuation.yield(.all)
            postPartnersDidChange()
        }
        return wiped
    }

    private static func wipe(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM remote_assets")
        try PartnerStore.wipe(db)
        try db.execute(sql: "DELETE FROM kv")
        try db.execute(sql: "DELETE FROM pending_edits")
        // The local half of a link is kept: a local checksum is computed only while its
        // backup_state row has none, so dropping it would leave the photo unlinked from its
        // server copy on the next server and shown twice.
        try db.execute(sql: "DELETE FROM facet_links WHERE local_identifier IS NULL")
        try db.execute(sql: "UPDATE facet_links SET immich_id = NULL")
        // Uploaded to a server this cache no longer describes. Pending re-checks each against
        // whichever server comes next, which skips the ones it already has.
        try db.execute(sql: """
            UPDATE backup_state SET state = ?, retry_count = 0, last_error = NULL
            WHERE state IN (?, ?, ?)
            """, arguments: [BackupStateRecord.State.pending.rawValue,
                             BackupStateRecord.State.uploaded.rawValue,
                             BackupStateRecord.State.uploading.rawValue,
                             BackupStateRecord.State.failed.rawValue])
    }

    // MARK: - Pending edits (D22)
    //
    // Catches up a local edit whose remote leg failed once the server is reachable again — see
    // `PendingEditRecord`'s doc comment for the two reconciliation shapes. Driven from
    // `StartupSequencer` (launch/foreground) and `SyncEngine`'s background task; both already
    // hold a reference here, so nothing new needed registering with the OS to get a retry
    // window (BGTaskScheduler identifiers are a scarce, crash-prone resource — see AGENTS.md).

    /// Queues a rotation to retry, called after `rotateRemote` fails regardless of whether the
    /// local facet's own rotation succeeded. Re-enqueuing an asset that already has a pending
    /// edit just resets its retry clock — the partial unique indexes on `pending_edits` make
    /// that an update, not a duplicate row.
    func enqueuePendingRotation(localIdentifier: String?,
                                immichID: String,
                                mediaKind: MediaKind,
                                clockwise: Bool) async throws {
        // Only a remote-only edit needs to remember the operation — a local-backed one is
        // state-based and re-reads PhotoKit fresh at retry time (see PendingEditRecord).
        let payload = localIdentifier == nil ? RotationPayload(clockwise: clockwise).jsonString : nil
        try await upsertPendingEdit(localIdentifier: localIdentifier, immichID: immichID,
                                    editType: .rotation, mediaKind: mediaKind, payload: payload)
    }

    /// Queues a push of the local rendition for an asset whose upload finished after it was
    /// edited — the server holds the pre-edit bytes, and nothing else would ever correct them.
    func enqueueLocalReconcile(localIdentifier: String, immichID: String, mediaKind: MediaKind) async throws {
        try await upsertPendingEdit(localIdentifier: localIdentifier, immichID: immichID,
                                    editType: .rotation, mediaKind: mediaKind, payload: nil)
    }

    private func upsertPendingEdit(localIdentifier: String?,
                                   immichID: String,
                                   editType: PendingEditRecord.EditType,
                                   mediaKind: MediaKind,
                                   payload: String?) async throws {
        let writer = try database.writer()
        let now = Date().timeIntervalSince1970
        try await writer.write { db in
            let existing: PendingEditRecord?
            if let localIdentifier {
                existing = try PendingEditRecord
                    .filter(sql: "local_identifier = ?", arguments: [localIdentifier])
                    .fetchOne(db)
            } else {
                existing = try PendingEditRecord
                    .filter(sql: "immich_id = ? AND local_identifier IS NULL", arguments: [immichID])
                    .fetchOne(db)
            }

            if var row = existing {
                row.immichID = immichID
                row.mediaKindRaw = Int(mediaKind.rawValue)
                row.payload = payload
                row.retryCount = 0
                row.lastError = nil
                row.updatedAt = now
                try row.update(db)
            } else {
                try PendingEditRecord(localIdentifier: localIdentifier, immichID: immichID,
                                      editType: editType, mediaKind: mediaKind, payload: payload,
                                      updatedAt: now).insert(db)
            }
        }
    }

    /// Drains the queue, one edit at a time. Safe to call often — each edit either reconciles
    /// and clears, or fails and is left for the next call; there is no partial state to corrupt
    /// (D22, matching `SyncEngine`'s bounded-retry pattern for uploads).
    func retryPendingEdits() async {
        guard let writer = try? database.writer() else { return }
        let edits = (try? await writer.read { db in
            try PendingEditRecord
                .filter(sql: "retry_count < ?", arguments: [Self.maxEditRetries])
                .fetchAll(db)
        }) ?? []
        guard !edits.isEmpty else { return }

        for edit in edits {
            do {
                try Task.checkCancellation()
                try await reconcile(edit)
                try await clearPendingEdit(id: edit.id)
            } catch is CancellationError {
                return
            } catch {
                Log.immich.error("Pending edit retry failed: \(error.localizedDescription, privacy: .public)")
                try? await bumpPendingEditFailure(id: edit.id, error: error.localizedDescription)
            }
        }
    }

    private func reconcile(_ edit: PendingEditRecord) async throws {
        switch edit.editType {
        case .rotation:
            try await reconcileRotation(edit)
        }
    }

    private func reconcileRotation(_ edit: PendingEditRecord) async throws {
        if let localIdentifier = edit.localIdentifier {
            try await reconcileFromLocalFacet(localIdentifier: localIdentifier)
        } else {
            guard let payloadString = edit.payload, let payload = RotationPayload(jsonString: payloadString) else {
                throw RotationError.assetUnavailable
            }
            guard let rotator = registry.rotator(for: edit.mediaKind) else {
                throw RotationError.unsupportedMediaKind(edit.mediaKind)
            }
            try await rotateRemote(immichID: edit.immichID, clockwise: payload.clockwise, rotator: rotator)
        }
    }

    /// State-based reconciliation: pushes whatever PhotoKit currently has, rather than replaying
    /// whichever rotation(s) were attempted while offline. However many edits landed locally,
    /// in whatever order, the current rendition already *is* the answer — there is no baseline
    /// to drift from, because nothing is remembered; it is re-read fresh every time this runs.
    ///
    /// This always overwrites a concurrent remote-side change — a deliberate, last-writer-wins
    /// choice, not an attempt at conflict resolution. It matches D10's existing posture: an
    /// online rotation already produces a new asset id and drops server-side album membership
    /// in favour of staying simple.
    private func reconcileFromLocalFacet(localIdentifier: String) async throws {
        guard let phAsset = resolver.resolve(localIdentifier) else {
            return   // Local asset is gone; nothing left to push. Not an error — just moot.
        }
        guard let immichID = try immichID(forLocalIdentifier: localIdentifier) else {
            return   // No remote facet either (any more); same as above.
        }
        let record = try await remoteRecord(for: immichID, client: try makeClient())

        let export = try await exporter.export(asset: phAsset)
        defer { try? FileManager.default.removeItem(at: export.fileURL) }

        // Already in step. An edit queued by `SyncEngine` after an upload is a guess from a
        // moved modification date, which PhotoKit also moves for changes that leave the bytes
        // alone; replacing anyway would cost a new asset id for nothing.
        guard export.sha1Hex != record.checksumHex else { return }

        try await replaceRemoteFile(oldID: immichID, fileURL: export.fileURL, filename: export.filename,
                                    record: record, width: phAsset.pixelWidth, height: phAsset.pixelHeight,
                                    checksumHex: export.sha1Hex)
    }

    private func clearPendingEdit(id: Int64?) async throws {
        guard let id else { return }
        let writer = try database.writer()
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM pending_edits WHERE id = ?", arguments: [id])
        }
    }

    private func bumpPendingEditFailure(id: Int64?, error: String) async throws {
        guard let id else { return }
        let writer = try database.writer()
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE pending_edits SET retry_count = retry_count + 1, last_error = ?, updated_at = ?
                WHERE id = ?
                """, arguments: [error, Date().timeIntervalSince1970, id])
        }
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
