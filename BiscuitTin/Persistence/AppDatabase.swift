import Foundation
import GRDB

/// SQLite store for the Immich metadata cache, facet links and backup state (DESIGN.md §7.3).
///
/// Opens lazily: the launch path must not touch SQLite before the first frame (D19), so the
/// connection and migrations are created on first real use — which in practice is the first
/// remote sync (M5), not launch.
final class AppDatabase: @unchecked Sendable {
    private var pool: DatabasePool?
    private let lock = NSLock()
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil,
                                                     create: false))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.fileURL = base.appendingPathComponent("BiscuitTin", isDirectory: true)
                .appendingPathComponent("biscuittin.sqlite")
        }
    }

    /// Opens (once) and returns the writer. Never call this on the main thread.
    func writer() throws -> DatabaseWriter {
        lock.lock(); defer { lock.unlock() }
        if let pool { return pool }

        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        let newPool = try DatabasePool(path: fileURL.path, configuration: config)
        try Self.migrator.migrate(newPool)
        pool = newPool
        Log.timeline.info("Database opened at \(self.fileURL.lastPathComponent, privacy: .public)")
        return newPool
    }

    /// True once the database has actually been opened — lets callers avoid forcing it open
    /// on paths that only want to read opportunistically.
    var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return pool != nil
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "remote_assets") { t in
                t.primaryKey("immich_id", .text)
                t.column("checksum_hex", .text).notNull()
                t.column("device_asset_id", .text)
                t.column("device_id", .text)
                t.column("type", .text).notNull()
                t.column("live_photo_video_id", .text)
                t.column("duration_seconds", .double).notNull().defaults(to: 0)
                t.column("file_name", .text)
                t.column("capture_at", .double).notNull()
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("is_trashed", .integer).notNull().defaults(to: 0)
                t.column("exif_json", .text)
                t.column("updated_at", .double).notNull()
            }
            // Raw SQL: the timeline always reads newest-first, so the index is descending.
            try db.execute(sql: "CREATE INDEX idx_remote_capture ON remote_assets(capture_at DESC)")
            try db.create(index: "idx_remote_checksum", on: "remote_assets", columns: ["checksum_hex"])

            try db.create(table: "facet_links") { t in
                t.primaryKey("checksum_hex", .text)
                t.column("local_identifier", .text)
                t.column("immich_id", .text)
            }
            try db.create(index: "idx_links_local", on: "facet_links", columns: ["local_identifier"])

            try db.create(table: "backup_state") { t in
                t.primaryKey("local_identifier", .text)
                t.column("checksum_hex", .text)
                t.column("state", .text).notNull()
                t.column("last_error", .text)
                t.column("retry_count", .integer).notNull().defaults(to: 0)
                t.column("updated_at", .double).notNull()
            }

            try db.create(table: "kv") { t in
                t.primaryKey("key", .text)
                t.column("value", .text)
            }
        }

        migrator.registerMigration("v2-clip-embeddings") { db in
            try db.create(table: "clip_embedding") { t in
                // AssetID.raw — namespaced ("L:…" / "R:…"), so a local and a remote asset can
                // never collide (D5).
                t.primaryKey("asset_id", .text)
                // Which model produced this vector. Comparing vectors across models is
                // meaningless, so a mismatch re-embeds rather than silently ranking garbage.
                t.column("model_version", .text).notNull()
                t.column("vector", .blob).notNull()
                t.column("indexed_at", .double).notNull()
            }
            // The indexing pass sweeps rows whose model is stale; the query path reads every
            // row for the current model.
            try db.create(index: "idx_clip_model", on: "clip_embedding", columns: ["model_version"])
        }

        migrator.registerMigration("v3-remote-coordinates") { db in
            // Promoted out of `exif_json` into columns: the map builds a stub for every remote
            // asset on each index rebuild, and decoding a JSON blob per asset to reach two
            // numbers would put that cost on a hot path (§20.1).
            try db.alter(table: "remote_assets") { t in
                t.add(column: "latitude", .double)
                t.add(column: "longitude", .double)
            }
            // Backfill from the EXIF already cached, so existing installs get a populated map
            // without waiting for a full re-sync.
            let rows = try Row.fetchAll(db, sql: "SELECT immich_id, exif_json FROM remote_assets WHERE exif_json IS NOT NULL")
            for row in rows {
                guard let json: String = row["exif_json"],
                      let data = json.data(using: .utf8),
                      let exif = try? JSONDecoder().decode(Immich.ExifInfo.self, from: data),
                      let latitude = exif.latitude, let longitude = exif.longitude else { continue }
                try db.execute(sql: "UPDATE remote_assets SET latitude = ?, longitude = ? WHERE immich_id = ?",
                               arguments: [latitude, longitude, row["immich_id"] as String])
            }
        }

        migrator.registerMigration("v4-pending-edits") { db in
            // A local edit whose remote leg failed, queued for catch-up once the server is
            // reachable again (D22). `local_identifier` is nullable: a remote-only asset has
            // nothing local to reconcile from, so it carries an operation `payload` instead —
            // see RemoteLibraryService's doc comment on `PendingEditRecord` for the two
            // reconciliation strategies this supports.
            try db.create(table: "pending_edits") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("local_identifier", .text)
                t.column("immich_id", .text).notNull()
                t.column("edit_type", .text).notNull()
                t.column("media_kind", .integer).notNull()
                t.column("payload", .text)
                t.column("retry_count", .integer).notNull().defaults(to: 0)
                t.column("last_error", .text)
                t.column("updated_at", .double).notNull()
            }
            // Partial unique indexes: at most one pending edit per local asset, and separately
            // at most one per remote-only asset — the two id spaces never collide, so they need
            // independent uniqueness rather than one index over both columns.
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_pending_edits_local
                ON pending_edits(local_identifier) WHERE local_identifier IS NOT NULL
                """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_pending_edits_remote_only
                ON pending_edits(immich_id) WHERE local_identifier IS NULL
                """)
        }

        migrator.registerMigration("v5-links-by-immich-id") { db in
            // The timeline looks links up by server id on every server change, and sync, delete
            // and rotation all update them by it. Without this each was a scan of one row per
            // synced asset: 5–30 ms per lookup at 70k rows on an iPhone 13.
            try db.create(index: "idx_links_immich", on: "facet_links", columns: ["immich_id"])
        }

        migrator.registerMigration("v6-partner-sharing") { db in
            // Partners' libraries (§22) are kept apart from `remote_assets`: everything that
            // reads that table — the timeline merge, facet links, Free Up Space, search — is
            // about the user's own library, and must not have to filter partners out.
            // Same columns as `remote_assets` plus the owner, so `RemoteAssetRecord` reads both.
            try db.create(table: "partner_assets") { t in
                t.primaryKey("immich_id", .text)
                t.column("owner_id", .text).notNull()
                t.column("checksum_hex", .text).notNull()
                t.column("device_asset_id", .text)
                t.column("device_id", .text)
                t.column("type", .text).notNull()
                t.column("live_photo_video_id", .text)
                t.column("duration_seconds", .double).notNull().defaults(to: 0)
                t.column("file_name", .text)
                t.column("capture_at", .double).notNull()
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("is_trashed", .integer).notNull().defaults(to: 0)
                t.column("exif_json", .text)
                t.column("latitude", .double)
                t.column("longitude", .double)
                t.column("updated_at", .double).notNull()
            }
            try db.execute(sql: "CREATE INDEX idx_partner_owner_capture ON partner_assets(owner_id, capture_at DESC)")

            // Only shares *with* the signed-in user; the other direction has nothing to browse.
            try db.create(table: "partners") { t in
                t.primaryKey("shared_by_id", .text)
                t.column("in_timeline", .boolean).notNull().defaults(to: false)
            }

            // Names arrive on their own lines, not with the share, and possibly in an earlier
            // sync than the share itself — so every user the server reports is kept.
            try db.create(table: "immich_users") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("email", .text)
            }
        }

        return migrator
    }
}
