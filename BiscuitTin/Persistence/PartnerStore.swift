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
    struct ShareKey: Hashable {
        let sharedById: String
        let sharedWithId: String
    }

    enum LineResult {
        case handled
        case failed
        case ignored
    }

    var authUserID: String?
    var users: [String: Immich.SyncUserV1] = [:]
    var deletedUserIDs: Set<String> = []
    var shares: [ShareKey: Immich.SyncPartnerV1] = [:]
    var removedShares: [ShareKey: Immich.SyncPartnerDeleteV1] = [:]
    var assets: [String: Immich.SyncAssetV2] = [:]
    var exifs: [String: Immich.SyncAssetExifV1] = [:]
    var deletedAssetIDs: Set<String> = []

    var isEmpty: Bool {
        authUserID == nil && users.isEmpty && deletedUserIDs.isEmpty && shares.isEmpty
            && removedShares.isEmpty && assets.isEmpty && exifs.isEmpty && deletedAssetIDs.isEmpty
    }

    /// Takes one line if it belongs to partner sharing. Returns false for any other type.
    mutating func add(type: String, line: Data, decoder: JSONDecoder = JSONDecoder()) -> Bool {
        addLine(type: type, line: line, decoder: decoder) != .ignored
    }

    /// Takes one line if it belongs to partner sharing, distinguishing decode failures from
    /// non-partner line types so callers can avoid acknowledging corrupt checkpoints.
    ///
    /// Backfill lines carry the same payload as live ones; they exist only so the server can
    /// replay a newly added partner's history, and are stored the same way.
    mutating func addLine(type: String, line: Data, decoder: JSONDecoder = JSONDecoder()) -> LineResult {
        func decode<T: Decodable>(_: T.Type) -> T? {
            do {
                return try decoder.decode(Immich.SyncLine<T>.self, from: line).data
            } catch {
                Log.immich.error("Failed to decode \(type, privacy: .public) line: \(String(describing: error), privacy: .public)")
                return nil
            }
        }

        switch type {
        case "AuthUserV1":
            guard let user = decode(Immich.SyncUserV1.self) else { return .failed }
            authUserID = user.id
            users[user.id] = user
        case "UserV1":
            guard let user = decode(Immich.SyncUserV1.self) else { return .failed }
            users[user.id] = user
            deletedUserIDs.remove(user.id)
        case "UserDeleteV1":
            guard let delete = decode(Immich.SyncUserDeleteV1.self) else { return .failed }
            deletedUserIDs.insert(delete.userId)
            users[delete.userId] = nil
        case "PartnerV1":
            guard let share = decode(Immich.SyncPartnerV1.self) else { return .failed }
            let key = ShareKey(sharedById: share.sharedById, sharedWithId: share.sharedWithId)
            shares[key] = share
            removedShares.removeValue(forKey: key)
        case "PartnerDeleteV1":
            guard let removed = decode(Immich.SyncPartnerDeleteV1.self) else { return .failed }
            let key = ShareKey(sharedById: removed.sharedById, sharedWithId: removed.sharedWithId)
            removedShares[key] = removed
            shares.removeValue(forKey: key)
        case "PartnerAssetV2", "PartnerAssetBackfillV2":
            guard let asset = decode(Immich.SyncAssetV2.self) else { return .failed }
            assets[asset.id] = asset
            deletedAssetIDs.remove(asset.id)
        case "PartnerAssetDeleteV1":
            guard let delete = decode(Immich.SyncAssetDeleteV1.self) else { return .failed }
            deletedAssetIDs.insert(delete.assetId)
            assets[delete.assetId] = nil
            exifs[delete.assetId] = nil
        case "PartnerAssetExifV1", "PartnerAssetExifBackfillV1":
            guard let exif = decode(Immich.SyncAssetExifV1.self) else { return .failed }
            exifs[exif.assetId] = exif
        default:
            return .ignored
        }
        return .handled
    }
}

/// Reads and writes the partner tables (§22). Plain functions over a `Database`, so they run
/// inside whichever transaction `RemoteLibraryService` is already in.
enum PartnerStore {
    /// `kv` key holding the signed-in user's Immich id, learned from an `AuthUserV1` line. That
    /// line is acknowledged like any other and not sent again, so it has to be remembered.
    static let authUserIDKey = "auth_user_id"

    /// Applies a partner sync batch. Returns `true` when share lines could not be processed yet
    /// because the signed-in user's id (`AuthUserV1`) is still unknown.
    @discardableResult
    static func apply(_ batch: PartnerSyncBatch,
                      in db: Database,
                      encoder: JSONEncoder = JSONEncoder()) throws -> Bool {
        guard !batch.isEmpty else { return false }

        if let authUserID = batch.authUserID {
            try AppDatabase.setKV(authUserIDKey, value: authUserID, in: db)
        }
        let me = try AppDatabase.getKV(authUserIDKey, in: db)

        for user in batch.users.values {
            try db.execute(sql: """
                INSERT INTO immich_users (id, name, email) VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, email = excluded.email
                """, arguments: [user.id, user.name, user.email])
        }
        for id in batch.deletedUserIDs {
            try db.execute(sql: "DELETE FROM immich_users WHERE id = ?", arguments: [id])
        }

        // `shares` and `removedShares` are disjoint per `(sharedById, sharedWithId)` because
        // `PartnerSyncBatch.addLine` cancels earlier opposing operations in stream order.
        let deferredShares = me == nil && (!batch.shares.isEmpty || !batch.removedShares.isEmpty)
        if deferredShares {
            Log.device("immich", "Partner shares arrived before the signed-in user's id; deferring ack")
        }
        if let me {
            for removed in batch.removedShares.values where removed.sharedWithId == me {
                try db.execute(sql: "DELETE FROM partners WHERE shared_by_id = ?",
                               arguments: [removed.sharedById])
                // The server sends no per-asset deletes when a share ends; the library just stops
                // being visible. Re-sharing later backfills it again.
                try db.execute(sql: "DELETE FROM partner_assets WHERE owner_id = ?",
                               arguments: [removed.sharedById])
            }
            for share in batch.shares.values where share.sharedWithId == me {
                try db.execute(sql: """
                    INSERT INTO partners (shared_by_id, in_timeline) VALUES (?, ?)
                    ON CONFLICT(shared_by_id) DO UPDATE SET in_timeline = excluded.in_timeline
                    """, arguments: [share.sharedById, share.inTimeline ?? false])
            }
        }

        // Batch-load all existing partner rows touched by this batch to avoid N+1 SELECTs.
        let existingIDs = Set(batch.assets.keys).union(batch.exifs.keys)
        let existingRows = try fetchRecords(ids: existingIDs, in: db)

        for (id, asset) in batch.assets {
            // As for the user's own library: archived, hidden and locked assets never show.
            guard asset.visibility == .timeline, let owner = asset.ownerId else {
                try db.execute(sql: "DELETE FROM partner_assets WHERE immich_id = ?", arguments: [id])
                continue
            }
            var record = existingRows[id]?.record ?? RemoteAssetRecord(placeholderID: id)
            record.apply(asset)
            if let exif = batch.exifs[id] { record.apply(exif, encoder: encoder) }
            try save(record, owner: owner, in: db)
        }
        // EXIF for an asset not in this batch merges onto the cached row. The server sends a
        // partner's assets before their EXIF, so one with no row yet has no asset to attach to.
        for (id, exif) in batch.exifs where batch.assets[id] == nil {
            guard var entry = existingRows[id] else { continue }
            entry.record.apply(exif, encoder: encoder)
            try save(entry.record, owner: entry.owner, in: db)
        }

        if !batch.deletedAssetIDs.isEmpty {
            let ids = Array(batch.deletedAssetIDs)
            for start in stride(from: 0, to: ids.count, by: 500) {
                let chunk = Array(ids[start..<min(start + 500, ids.count)])
                try db.execute(sql: "DELETE FROM partner_assets WHERE immich_id IN (\(databaseQuestionMarks(count: chunk.count)))",
                               arguments: StatementArguments(chunk))
            }
        }

        return deferredShares
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

    private static func fetchRecords(ids: Set<String>, in db: Database) throws -> [String: (record: RemoteAssetRecord, owner: String)] {
        guard !ids.isEmpty else { return [:] }
        let all = Array(ids)
        var result: [String: (record: RemoteAssetRecord, owner: String)] = [:]
        result.reserveCapacity(all.count)
        for start in stride(from: 0, to: all.count, by: 500) {
            let chunk = Array(all[start..<min(start + 500, all.count)])
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM partner_assets WHERE immich_id IN (\(databaseQuestionMarks(count: chunk.count)))",
                arguments: StatementArguments(chunk)
            )
            for row in rows {
                let record = try RemoteAssetRecord(row: row)
                let owner: String = row["owner_id"]
                result[record.immichID] = (record, owner)
            }
        }
        return result
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
