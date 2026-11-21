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

/// How much of a sync has downloaded, for the sign-in progress row. Counts lines received, so
/// it runs ahead of what is stored and includes assets that turn out to be hidden or archived.
struct SyncProgress: Sendable, Equatable {
    var assets = 0
    var partnerAssets = 0

    mutating func count(_ lineType: String) {
        switch lineType {
        case "AssetV2": assets += 1
        case "PartnerAssetV2", "PartnerAssetBackfillV2": partnerAssets += 1
        default: break
        }
    }
}

/// The replacement is stored on the server but the old asset has not been retired. A retry
/// must finish this replacement, not upload another.
struct ReplacementIncomplete: Error {
    let newID: String
    let newChecksumHex: String
    let underlying: Error
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
    let changesContinuation: AsyncStream<RemoteChange>.Continuation

    let database: AppDatabase
    let session: ImmichAuthSession
    private let clientFactory: @Sendable (URL) -> ImmichClient
    /// Only needed for D22's pending-edit reconciliation: resolving a local facet's current
    /// state, exporting it, and picking a rotator for a remote-only retry.
    let resolver: PHAssetResolver
    let exporter: LocalAssetExporter
    let registry: RotatorRegistry

    private let clientProvider: (@Sendable () throws -> ImmichClient)?

    private var activeSyncTask: Task<Void, Error>?
    /// Incremented on every cache wipe or account switch so an in-flight sync from a previous
    /// session can never commit into or mark `last_synced_at` for a newer session.
    private var sessionGeneration: UInt64 = 0
    /// The actor is re-entrant across `await`, and launch, foreground and the background task
    /// each start a drain.
    var isRetryingEdits = false

    private enum Cursor {
        /// Wall-clock time of the last successful sync, for display only (§13.4) — the sync
        /// cursor itself lives server-side, keyed to the access token.
        static let lastSyncedAt = "last_synced_at"
        /// Base URL and account whose server data the cache holds.
        static let cacheOwner = "cache_owner"
        /// Present while a full replay has committed some chunks but not its final sweep.
        static let unfinishedReplay = "unfinished_replay"
    }

    init(database: AppDatabase,
         session: ImmichAuthSession,
         resolver: PHAssetResolver,
         exporter: LocalAssetExporter,
         registry: RotatorRegistry = .v1,
         maxLinesPerCommit: Int = 20_000,
         clientFactory: (@Sendable (URL) -> ImmichClient)? = nil,
         clientProvider: (@Sendable () throws -> ImmichClient)? = nil) {
        self.database = database
        self.clientProvider = clientProvider
        self.maxLinesPerCommit = maxLinesPerCommit
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

    func makeClient() throws -> ImmichClient {
        // Tests cannot produce a Keychain token.
        if let clientProvider { return try clientProvider() }
        guard let baseURL = session.baseURL, session.credential != nil else {
            throw ImmichError.notConfigured
        }
        return clientFactory(baseURL)
    }

    // MARK: - Sync

    private static let syncTypes: [Immich.SyncRequestType] = [
        .assets, .assetExifs, .authUsers, .users, .partners, .partnerAssets, .partnerAssetExifs,
    ]

    /// Lines are committed, announced and acked in chunks while the stream is still
    /// downloading, so the grid and a partner's library fill in as it goes rather than after a
    /// multi-minute transfer. Every commit costs the timeline a rebuild, so chunks are cut by
    /// time, with a line cap only to bound memory when the network outpaces the interval.
    private static let commitInterval: Duration = .seconds(2)
    private let maxLinesPerCommit: Int

    /// Streams every change since the server-tracked cursor (or the whole library, when `reset`
    /// is true) and applies it as it arrives. Replaces the old paged full/delta sync and the
    /// weekly hard-delete sweep alike (D9) — an `AssetDeleteV1` line removes its row immediately,
    /// on whichever call first reports it.
    func syncStream(reset: Bool = false, progress: (@Sendable (SyncProgress) -> Void)? = nil) async throws {
        let session = session
        try await syncStream(client: try makeClient(), reset: reset, progress: progress,
                             isSignedIn: { session.isConfigured })
    }

    /// `isSignedIn` is checked before each commit; it is a parameter only so tests can run this
    /// without a Keychain token.
    func syncStream(client: ImmichClient,
                    reset: Bool,
                    progress: (@Sendable (SyncProgress) -> Void)? = nil,
                    isSignedIn: @escaping @Sendable () -> Bool) async throws {
        guard activeSyncTask == nil else { return }
        let generation = sessionGeneration
        let credential = session.credential
        let task = Task { [self] in
            try await self.runSyncStream(client: client, reset: reset, progress: progress,
                                         isSignedIn: isSignedIn, generation: generation,
                                         credential: credential)
        }
        activeSyncTask = task
        defer {
            if sessionGeneration == generation {
                activeSyncTask = nil
            }
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func runSyncStream(client: ImmichClient,
                               reset: Bool,
                               progress: (@Sendable (SyncProgress) -> Void)?,
                               isSignedIn: @escaping @Sendable () -> Bool,
                               generation: UInt64,
                               credential: ImmichCredential?) async throws {
        // A replay cut off part-way has applied and acked some of its lines but never removed
        // the rows it did not reach, so only another full replay can finish the job.
        let resumesReplay = try getCursor(Cursor.unfinishedReplay) != nil
        var totals = try await streamBatch(client: client, reset: reset || resumesReplay,
                                           progress: progress, isSignedIn: isSignedIn,
                                           generation: generation, credential: credential)
        if totals.serverRequestedReset {
            // Sent alone, in place of any changes, when the session's checkpoint is older than the
            // server's 30-day audit retention: deletes from before then can no longer be reported,
            // so only a full replay can be trusted. A `reset: true` request clears the server-side
            // reset itself, which is why the `SyncResetV1` line is never acked — acking it would
            // also discard the checkpoints this replay is about to ack.
            Log.immich.info("Server requested a sync reset; replaying the whole library")
            totals = try await streamBatch(client: client, reset: true, progress: progress,
                                           isSignedIn: isSignedIn, generation: generation,
                                           credential: credential)
            guard !totals.serverRequestedReset else {
                throw ImmichError.decoding("Sync reset requested again by a reset sync")
            }
        }

        guard generation == sessionGeneration, isSignedIn() else { throw CancellationError() }
        try setCursor(Cursor.lastSyncedAt, to: Immich.iso8601String(from: Date()))
        Log.immich.info("Sync stream applied \(totals.upserts) upserts, \(totals.deletes) deletes\(totals.isReplay ? " (replaced cache)" : "")")
        if totals.hasPartnerData {
            Log.device("immich", "Sync stream applied partner data: \(totals.partnerAssets) assets, "
                       + "\(totals.shares) shares")
        }
    }

    private struct SyncBatch {
        var upserts: [String: Immich.SyncAssetV2] = [:]
        var exifs: [String: Immich.SyncAssetExifV1] = [:]
        var deletedIDs: Set<String> = []
        var partners = PartnerSyncBatch()
        var acks = Immich.SyncAcks()
        var lineCount = 0
        var hasCorruptHeader = false

        /// Returns `false` when a known line type failed to decode (so its checkpoint must not be acked).
        mutating func add(type: String, line: Data, decoder: JSONDecoder) -> Bool {
            lineCount += 1
            switch type {
            case "AssetV2":
                do {
                    let decoded = try decoder.decode(Immich.SyncLine<Immich.SyncAssetV2>.self, from: line)
                    upserts[decoded.data.id] = decoded.data
                    deletedIDs.remove(decoded.data.id)
                    return true
                } catch {
                    Log.immich.error("Failed to decode AssetV2 line: \(String(describing: error), privacy: .public)")
                    return false
                }
            case "AssetExifV1":
                do {
                    let decoded = try decoder.decode(Immich.SyncLine<Immich.SyncAssetExifV1>.self, from: line)
                    exifs[decoded.data.assetId] = decoded.data
                    return true
                } catch {
                    Log.immich.error("Failed to decode AssetExifV1 line: \(String(describing: error), privacy: .public)")
                    return false
                }
            case "AssetDeleteV1":
                do {
                    let decoded = try decoder.decode(Immich.SyncLine<Immich.SyncAssetDeleteV1>.self, from: line)
                    deletedIDs.insert(decoded.data.assetId)
                    upserts.removeValue(forKey: decoded.data.assetId)
                    exifs.removeValue(forKey: decoded.data.assetId)
                    return true
                } catch {
                    Log.immich.error("Failed to decode AssetDeleteV1 line: \(String(describing: error), privacy: .public)")
                    return false
                }
            default:
                // "SyncCompleteV1" (end-of-batch marker), "SyncAckV1" (end of a partner's
                // backfill) and anything not requested/handled yet — degrade gracefully rather
                // than fail the whole batch (see file header comment).
                return partners.addLine(type: type, line: line, decoder: decoder) != .failed
            }
        }
    }

    private struct SyncTotals {
        var isReplay: Bool
        var serverRequestedReset = false
        var upserts = 0
        var deletes = 0
        var partnerAssets = 0
        var shares = 0
        var hasPartnerData = false

        mutating func add(_ batch: SyncBatch) {
            upserts += batch.upserts.count
            deletes += batch.deletedIDs.count
            partnerAssets += batch.partners.assets.count
            shares += batch.partners.shares.count
            hasPartnerData = hasPartnerData || !batch.partners.isEmpty
        }
    }

    /// The server rows a full replay has mentioned so far. A replay used to clear the cache in
    /// the same transaction as its upserts; committing in chunks, that would empty the grid for
    /// the whole download, so instead whatever the replay never mentions is dropped at the end.
    /// Ids only — a few megabytes for a six-figure library.
    private struct ReplaySweep {
        enum Kind: String { case asset, partnerAsset, partner, user }

        private var ids: [Kind: Set<String>] = [:]

        mutating func record(_ batch: SyncBatch) {
            ids[.asset, default: []].formUnion(batch.upserts.keys)
            ids[.partnerAsset, default: []].formUnion(batch.partners.assets.keys)
            ids[.partner, default: []].formUnion(batch.partners.shares.values.map(\.sharedById))
            ids[.user, default: []].formUnion(batch.partners.users.keys)
        }

        /// Fills `temp.replay_seen`, which `seen(_:)` reads.
        func load(into db: Database) throws {
            try db.execute(sql: """
                CREATE TEMP TABLE IF NOT EXISTS replay_seen
                    (kind TEXT NOT NULL, id TEXT NOT NULL, PRIMARY KEY (kind, id)) WITHOUT ROWID
                """)
            try db.execute(sql: "DELETE FROM temp.replay_seen")
            let insert = try db.makeStatement(sql: "INSERT OR IGNORE INTO temp.replay_seen (kind, id) VALUES (?, ?)")
            for (kind, ids) in ids {
                for id in ids { try insert.execute(arguments: [kind.rawValue, id]) }
            }
        }

        /// A subquery listing the ids of `kind` the replay mentioned.
        static func seen(_ kind: Kind) -> String {
            "SELECT id FROM temp.replay_seen WHERE kind = '\(kind.rawValue)'"
        }
    }

    private func streamBatch(client: ImmichClient, reset: Bool,
                             progress: (@Sendable (SyncProgress) -> Void)?,
                             isSignedIn: () -> Bool,
                             generation: UInt64,
                             credential: ImmichCredential?) async throws -> SyncTotals {
        var totals = SyncTotals(isReplay: reset)
        var replay = reset ? ReplaySweep() : nil
        var chunk = SyncBatch()
        var received = SyncProgress()
        var lastCommit = ContinuousClock.now
        let decoder = JSONDecoder()

        do {
            for try await lines in try await client.syncStream(types: Self.syncTypes, reset: reset) {
                for lineData in lines {
                    try Task.checkCancellation()
                    let header: Immich.SyncLineHeader
                    do {
                        header = try decoder.decode(Immich.SyncLineHeader.self, from: lineData)
                    } catch {
                        Log.immich.error("Failed to decode sync/stream header: \(String(describing: error), privacy: .public)")
                        chunk.hasCorruptHeader = true
                        continue
                    }
                    if header.type == "SyncResetV1" {
                        // Sent alone, so nothing of this batch has been committed.
                        totals.serverRequestedReset = true
                        return totals
                    }
                    if chunk.add(type: header.type, line: lineData, decoder: decoder) {
                        chunk.acks.record(header.ack)
                    } else {
                        chunk.acks.taint(header.ack)
                    }
                    received.count(header.type)

                    if chunk.lineCount >= maxLinesPerCommit
                        || ContinuousClock.now - lastCommit >= Self.commitInterval {
                        try await commit(chunk, replay: &replay, isLast: false, client: client,
                                         isSignedIn: isSignedIn, generation: generation, totals: &totals)
                        chunk = SyncBatch()
                        lastCommit = .now
                    }
                }
                progress?(received)
            }
            try await commit(chunk, replay: &replay, isLast: true, client: client,
                             isSignedIn: isSignedIn, generation: generation, totals: &totals)
        } catch ImmichError.unauthorized {
            if generation == sessionGeneration {
                session.markExpired(ifCredentialMatches: credential)
            }
            throw ImmichError.unauthorized
        }
        return totals
    }

    /// Writes one chunk, tells the timeline and the partner screens, then acks it. Acking only
    /// after the write means an interrupted sync resumes from the last chunk that was stored.
    private func commit(_ chunk: SyncBatch, replay: inout ReplaySweep?, isLast: Bool,
                        client: ImmichClient, isSignedIn: () -> Bool, generation: UInt64,
                        totals: inout SyncTotals) async throws {
        let sweeps = isLast && replay != nil
        guard chunk.lineCount > 0 || sweeps else { return }
        replay?.record(chunk)

        // Signing out or switching accounts mid-download wipes the cache and bumps
        // `sessionGeneration`; applying this afterwards would cross-contaminate accounts.
        guard generation == sessionGeneration, isSignedIn() else { throw CancellationError() }
        var acks = chunk.acks
        let deferredPartnerShares = try apply(chunk, isReplay: replay != nil, sweeping: sweeps ? replay : nil)
        if deferredPartnerShares {
            acks.taintCheckpoint("PartnerV1")
            acks.taintCheckpoint("PartnerDeleteV1")
        }
        totals.add(chunk)

        if sweeps || !chunk.partners.isEmpty {
            postPartnersDidChange()
        }
        if sweeps {
            changesContinuation.yield(.all)
        } else {
            // Every yield costs the timeline a rebuild.
            let changedIDs = Set(chunk.upserts.keys).union(chunk.exifs.keys).union(chunk.deletedIDs)
            if !changedIDs.isEmpty {
                changesContinuation.yield(.assets(changedIDs))
            }
        }

        // One entry per checkpoint the chunk touched — a dozen or so, well under the server's
        // 1000-ack cap. Skip acking when a header could not be parsed at all.
        if !chunk.hasCorruptHeader, !acks.all.isEmpty {
            guard generation == sessionGeneration, isSignedIn() else { throw CancellationError() }
            try await client.syncAck(acks.all)
        }
    }

    // MARK: - Persistence

    /// - Parameters:
    ///   - isReplay: the chunk belongs to a full replay, which stays marked unfinished in `kv`
    ///     until its sweep commits.
    ///   - sweep: set on a replay's last chunk; everything it never mentioned is removed in the
    ///     same transaction.
    /// - Returns: `true` if partner shares were deferred because `auth_user_id` is still unknown.
    private func apply(_ batch: SyncBatch, isReplay: Bool, sweeping sweep: ReplaySweep?) throws -> Bool {
        let writer = try database.writer()
        let encoder = JSONEncoder()

        return try writer.write { db in
            if isReplay {
                try AppDatabase.setKV(Cursor.unfinishedReplay, value: "1", in: db)
            }
            let deferredPartnerShares = try PartnerStore.apply(batch.partners, in: db, encoder: encoder)
            var releasedLink = false
            for (id, asset) in batch.upserts {
                guard asset.visibility == .timeline else {
                    // Matches the old `isVisible: true` search filter (D9): archived, hidden and
                    // locked assets never appeared in the grid, so one that turns non-timeline is
                    // dropped rather than kept in a state nothing reads.
                    try db.execute(sql: "DELETE FROM remote_assets WHERE immich_id = ?", arguments: [id])
                    try db.execute(sql: "UPDATE facet_links SET immich_id = NULL WHERE immich_id = ?",
                                   arguments: [id])
                    releasedLink = true
                    continue
                }

                var record = try RemoteAssetRecord.filter(key: id).fetchOne(db)
                    ?? RemoteAssetRecord(placeholderID: id)
                record.apply(asset)
                if let exif = batch.exifs[id] { record.apply(exif, encoder: encoder) }
                try record.save(db)

                if record.isTrashed {
                    // A trashed asset still reports the checksum it was uploaded under. Letting it
                    // claim the link would take a local photo back from the asset that replaced it.
                    try db.execute(sql: "UPDATE facet_links SET immich_id = NULL WHERE immich_id = ?",
                                   arguments: [id])
                    releasedLink = true
                    continue
                }

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

            // EXIF lines for assets not touched by an upsert this chunk: merge onto whatever is
            // already cached, if anything. The server sends every asset line before any EXIF
            // line, so in a replay the asset is already stored by the time its EXIF arrives.
            for (id, exif) in batch.exifs where batch.upserts[id] == nil {
                guard var record = try RemoteAssetRecord.filter(key: id).fetchOne(db) else { continue }
                record.apply(exif, encoder: encoder)
                try record.save(db)
            }

            if !batch.deletedIDs.isEmpty {
                let ids = Array(batch.deletedIDs)
                for start in stride(from: 0, to: ids.count, by: 500) {
                    let chunk = Array(ids[start..<min(start + 500, ids.count)])
                    let placeholders = databaseQuestionMarks(count: chunk.count)
                    try db.execute(sql: "DELETE FROM remote_assets WHERE immich_id IN (\(placeholders))",
                                   arguments: StatementArguments(chunk))
                    try db.execute(sql: "UPDATE facet_links SET immich_id = NULL WHERE immich_id IN (\(placeholders))",
                                   arguments: StatementArguments(chunk))
                }
                releasedLink = true
            }

            if releasedLink {
                try db.execute(sql: "DELETE FROM facet_links WHERE local_identifier IS NULL AND immich_id IS NULL")
            }

            if let sweep {
                try Self.removeUnmentioned(by: sweep, in: db)
                try db.execute(sql: "DELETE FROM kv WHERE key = ?", arguments: [Cursor.unfinishedReplay])
            }
            return deferredPartnerShares
        }
    }

    /// The end of a full replay: drops every server row it did not mention, leaving what clearing
    /// the cache and applying the replay in one transaction used to. Backup state is deliberately
    /// not touched — on the same server, a photo uploaded and then deleted there must stay
    /// uploaded, or backup would restore it.
    private static func removeUnmentioned(by sweep: ReplaySweep, in db: Database) throws {
        try sweep.load(into: db)
        try db.execute(sql: "DELETE FROM remote_assets WHERE immich_id NOT IN (\(ReplaySweep.seen(.asset)))")
        // A link keeps its server half only where the replay stored that asset under that
        // checksum, as re-inserting the links would have. The local half always stays: a local
        // checksum is computed only while its backup_state row has none, so dropping it would
        // leave the photo unlinked from its server copy and shown twice.
        try db.execute(sql: """
            UPDATE facet_links SET immich_id = NULL
            WHERE immich_id IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM remote_assets r
                WHERE r.immich_id = facet_links.immich_id AND r.checksum_hex = facet_links.checksum_hex)
            """)
        try db.execute(sql: "DELETE FROM facet_links WHERE local_identifier IS NULL AND immich_id IS NULL")
        try PartnerStore.removeUnmentioned(assets: ReplaySweep.seen(.partnerAsset),
                                           partners: ReplaySweep.seen(.partner),
                                           users: ReplaySweep.seen(.user),
                                           in: db)
        try db.execute(sql: "DROP TABLE temp.replay_seen")
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

    // MARK: - Cache lifecycle

    /// Clears cached server data without touching the device library.
    func wipeCache() throws {
        sessionGeneration &+= 1
        activeSyncTask?.cancel()
        activeSyncTask = nil
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
            let current = try AppDatabase.getKV(Cursor.cacheOwner, in: db)
            guard current != owner else { return false }
            try Self.wipe(db)
            try AppDatabase.setKV(Cursor.cacheOwner, value: owner, in: db)
            return true
        }
        if wiped {
            sessionGeneration &+= 1
            activeSyncTask?.cancel()
            activeSyncTask = nil
            changesContinuation.yield(.all)
            postPartnersDidChange()
        }
        return wiped
    }

    private static func wipe(_ db: Database) throws {
        try clearServerAssets(db)
        try db.execute(sql: "DELETE FROM kv")
        try db.execute(sql: "DELETE FROM pending_edits")
        // Uploaded to a server this cache no longer describes. Pending re-checks each against
        // whichever server comes next, which skips the ones it already has.
        try db.execute(sql: """
            UPDATE backup_state
            SET state = ?, retry_count = 0, last_error = NULL, next_attempt_at = 0, modified_at = NULL
            WHERE state IN (?, ?, ?)
            """, arguments: [BackupStateRecord.State.pending.rawValue,
                             BackupStateRecord.State.uploaded.rawValue,
                             BackupStateRecord.State.uploading.rawValue,
                             BackupStateRecord.State.failed.rawValue])
    }

    /// Drops every cached server asset, all partner data, and the server half of every link.
    private static func clearServerAssets(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM remote_assets")
        try PartnerStore.wipe(db)
        // The local half of a link is kept: a local checksum is computed only while its
        // backup_state row has none, so dropping it would leave the photo unlinked from its
        // server copy and shown twice.
        try db.execute(sql: "DELETE FROM facet_links WHERE local_identifier IS NULL")
        try db.execute(sql: "UPDATE facet_links SET immich_id = NULL")
    }

    // MARK: - Cursors

    private func getCursor(_ key: String) throws -> String? {
        try database.writer().read { db in
            try AppDatabase.getKV(key, in: db)
        }
    }

    private func setCursor(_ key: String, to value: String) throws {
        try database.writer().write { db in
            try AppDatabase.setKV(key, value: value, in: db)
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
