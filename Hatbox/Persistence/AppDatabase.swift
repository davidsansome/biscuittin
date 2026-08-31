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
            self.fileURL = base.appendingPathComponent("Hatbox", isDirectory: true)
                .appendingPathComponent("hatbox.sqlite")
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

        return migrator
    }
}
