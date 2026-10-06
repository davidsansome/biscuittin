import Foundation
import GRDB

/// Someone sharing their Immich library with the signed-in user (§22).
struct Partner: Hashable, Sendable, Identifiable {
    /// The partner's Immich user id, which is also the `owner_id` of their assets.
    let id: String
    let name: String
}

/// The partner-sharing lines of one `sync/stream` batch, collected before anything is written so
/// the whole batch lands in one transaction alongside the user's own assets.
struct PartnerSyncBatch {
    var authUserID: String?
    var users: [String: Immich.SyncUserV1] = [:]
    var deletedUserIDs: Set<String> = []
    var shares: [Immich.SyncPartnerV1] = []
    var removedShares: [Immich.SyncPartnerDeleteV1] = []
    var assets: [String: Immich.SyncAssetV2] = [:]
    var exifs: [String: Immich.SyncAssetExifV1] = [:]
    var deletedAssetIDs: Set<String> = []

    var isEmpty: Bool {
        authUserID == nil && users.isEmpty && deletedUserIDs.isEmpty && shares.isEmpty
            && removedShares.isEmpty && assets.isEmpty && exifs.isEmpty && deletedAssetIDs.isEmpty
    }

    /// Takes one line if it belongs to partner sharing. Returns false for any other type.
    ///
    /// Backfill lines carry the same payload as live ones; they exist only so the server can
    /// replay a newly added partner's history, and are stored the same way.
    mutating func add(type: String, line: Data) -> Bool {
        let decoder = JSONDecoder()
        func decode<T: Decodable>(_: T.Type) -> T? {
            try? decoder.decode(Immich.SyncLine<T>.self, from: line).data
        }

        switch type {
        case "AuthUserV1":
            guard let user = decode(Immich.SyncUserV1.self) else { return true }
            authUserID = user.id
            users[user.id] = user
        case "UserV1":
            guard let user = decode(Immich.SyncUserV1.self) else { return true }
            users[user.id] = user
            deletedUserIDs.remove(user.id)
        case "UserDeleteV1":
            guard let delete = decode(Immich.SyncUserDeleteV1.self) else { return true }
            deletedUserIDs.insert(delete.userId)
            users[delete.userId] = nil
        case "PartnerV1":
            guard let share = decode(Immich.SyncPartnerV1.self) else { return true }
            shares.append(share)
        case "PartnerDeleteV1":
            guard let removed = decode(Immich.SyncPartnerDeleteV1.self) else { return true }
            removedShares.append(removed)
        case "PartnerAssetV2", "PartnerAssetBackfillV2":
            guard let asset = decode(Immich.SyncAssetV2.self) else { return true }
            assets[asset.id] = asset
            deletedAssetIDs.remove(asset.id)
        case "PartnerAssetDeleteV1":
            guard let delete = decode(Immich.SyncAssetDeleteV1.self) else { return true }
            deletedAssetIDs.insert(delete.assetId)
            assets[delete.assetId] = nil
        case "PartnerAssetExifV1", "PartnerAssetExifBackfillV1":
            guard let exif = decode(Immich.SyncAssetExifV1.self) else { return true }
            exifs[exif.assetId] = exif
        default:
            return false
        }
        return true
    }
}

/// Reads and writes the partner tables (§22). Plain functions over a `Database`, so they run
/// inside whichever transaction `RemoteLibraryService` is already in.
enum PartnerStore {
    /// `kv` key holding the signed-in user's Immich id, learned from an `AuthUserV1` line. That
    /// line is acknowledged like any other and not sent again, so it has to be remembered.
    static let authUserIDKey = "auth_user_id"

    static func apply(_ batch: PartnerSyncBatch, in db: Database) throws {
        guard !batch.isEmpty else { return }

        if let authUserID = batch.authUserID {
            try db.execute(sql: """
                INSERT INTO kv (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, arguments: [authUserIDKey, authUserID])
        }
        let me = try String.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?",
                                     arguments: [authUserIDKey])

        for user in batch.users.values {
            try db.execute(sql: """
                INSERT INTO immich_users (id, name, email) VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, email = excluded.email
                """, arguments: [user.id, user.name, user.email])
        }
        for id in batch.deletedUserIDs {
            try db.execute(sql: "DELETE FROM immich_users WHERE id = ?", arguments: [id])
        }

        // Removals first: the server reports a share's deletes before its upserts, so a share
        // removed and re-added within one batch ends up present.
        for removed in batch.removedShares where removed.sharedWithId == me {
            try db.execute(sql: "DELETE FROM partners WHERE shared_by_id = ?",
                           arguments: [removed.sharedById])
            // The server sends no per-asset deletes when a share ends; the library just stops
            // being visible. Re-sharing later backfills it again.
            try db.execute(sql: "DELETE FROM partner_assets WHERE owner_id = ?",
                           arguments: [removed.sharedById])
        }
        if me == nil, !batch.shares.isEmpty {
            Log.device("immich", "Partner shares arrived before the signed-in user's id; ignored")
        }
        for share in batch.shares where share.sharedWithId == me {
            try db.execute(sql: """
                INSERT INTO partners (shared_by_id, in_timeline) VALUES (?, ?)
                ON CONFLICT(shared_by_id) DO UPDATE SET in_timeline = excluded.in_timeline
                """, arguments: [share.sharedById, share.inTimeline ?? false])
        }

        for (id, asset) in batch.assets {
            // As for the user's own library: archived, hidden and locked assets never show.
            guard asset.visibility == .timeline, let owner = asset.ownerId else {
                try db.execute(sql: "DELETE FROM partner_assets WHERE immich_id = ?", arguments: [id])
                continue
            }
            var record = try record(id: id, in: db) ?? RemoteAssetRecord(placeholderID: id)
            record.apply(asset)
            if let exif = batch.exifs[id] { record.apply(exif) }
            try save(record, owner: owner, in: db)
        }
        // EXIF for an asset not in this batch merges onto the cached row. The server sends a
        // partner's assets before their EXIF, so one with no row yet has no asset to attach to.
        for (id, exif) in batch.exifs where batch.assets[id] == nil {
            guard var record = try record(id: id, in: db),
                  let owner = try String.fetchOne(db, sql: "SELECT owner_id FROM partner_assets WHERE immich_id = ?",
                                                  arguments: [id]) else { continue }
            record.apply(exif)
            try save(record, owner: owner, in: db)
        }

        if !batch.deletedAssetIDs.isEmpty {
            let ids = Array(batch.deletedAssetIDs)
            try db.execute(sql: "DELETE FROM partner_assets WHERE immich_id IN (\(databaseQuestionMarks(count: ids.count)))",
                           arguments: StatementArguments(ids))
        }
    }

    /// Everyone sharing with the signed-in user, by name. A partner whose user line has not
    /// arrived yet is still listed, under their email or a placeholder, rather than hidden.
    static func partners(in db: Database) throws -> [Partner] {
        try Row.fetchAll(db, sql: """
            SELECT p.shared_by_id, u.name, u.email FROM partners p
            LEFT JOIN immich_users u ON u.id = p.shared_by_id
            """).map { row in
                let name: String? = row[1]
                let email: String? = row[2]
                return Partner(id: row[0], name: name.flatMap { $0.isEmpty ? nil : $0 } ?? email ?? "Partner")
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A partner's visible assets, newest first.
    static func stubs(ownerID: String, in db: Database) throws -> [AssetStub] {
        try Row.fetchAll(db, sql: """
            SELECT \(RemoteAssetRecord.stubColumns) FROM partner_assets
            WHERE owner_id = ? AND is_trashed = 0 ORDER BY capture_at DESC
            """, arguments: [ownerID]).map(RemoteAssetRecord.stub(row:))
    }

    /// The end of a full replay: drops every partner row it did not mention. Each argument is a
    /// subquery listing the ids it did. A share that ended long ago is reported by no line at
    /// all, so this is the only way its library leaves the cache.
    static func removeUnmentioned(assets: String, partners: String, users: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM partner_assets WHERE immich_id NOT IN (\(assets))")
        try db.execute(sql: "DELETE FROM partners WHERE shared_by_id NOT IN (\(partners))")
        try db.execute(sql: "DELETE FROM immich_users WHERE id NOT IN (\(users))")
    }

    static func wipe(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM partner_assets")
        try db.execute(sql: "DELETE FROM partners")
        try db.execute(sql: "DELETE FROM immich_users")
    }

    // `partner_assets` has `remote_assets`' columns plus `owner_id`, so the same record type
    // serves both; only the table name differs.

    private static func record(id: String, in db: Database) throws -> RemoteAssetRecord? {
        try RemoteAssetRecord.fetchOne(db, sql: "SELECT * FROM partner_assets WHERE immich_id = ?",
                                       arguments: [id])
    }

    private static func save(_ record: RemoteAssetRecord, owner: String, in db: Database) throws {
        var columns = try record.databaseDictionary
        columns["owner_id"] = owner.databaseValue
        let names = Array(columns.keys)
        try db.execute(sql: """
            INSERT OR REPLACE INTO partner_assets (\(names.joined(separator: ", ")))
            VALUES (\(databaseQuestionMarks(count: names.count)))
            """, arguments: StatementArguments(names.map { columns[$0]! }))
    }
}
