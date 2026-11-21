import Foundation
import GRDB

extension RemoteLibraryService {

    // MARK: - Remote mutations

    /// Rotates the server's copy of an asset that has no local copy (M7, D10), by downloading,
    /// rotating and re-uploading it. An asset with a local copy is rotated locally and that
    /// rendition pushed instead (`pushLocalRendition`), so both copies hold the same bytes.
    ///
    /// Immich v3.1.0 has **no endpoint that replaces an existing asset's file** — verified
    /// against a real server: `PUT/POST /api/assets/{id}/original`, `/file` and `/replace` all
    /// return the route-missing response, and there is no server-side edit or rotate route
    /// either. So "rotate the server copy" has to be expressed as upload-the-rotated-file then
    /// trash the old asset.
    ///
    /// Caveat worth knowing: the rotated copy is a *new* asset id, so server-side album
    /// membership, favourites and ratings for that photo do not carry over.
    func rotateRemote(immichID: String, clockwise: Bool, rotator: any AssetRotator) async throws {
        try await rotateRemote(immichID: immichID, quarterTurns: clockwise ? 1 : 3, rotator: rotator)
    }

    /// Applies `quarterTurns` (normalized mod 4) clockwise 90° turns to a remote-only asset.
    func rotateRemote(immichID: String, quarterTurns: Int, rotator: any AssetRotator) async throws {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return }

        let client = try makeClient()
        let record = try await remoteRecord(for: immichID, client: client)
        let rawFilename = record.fileName ?? "\(immichID).jpg"
        let lastComponent = (rawFilename as NSString).lastPathComponent
        let filename = (lastComponent.isEmpty || lastComponent == "." || lastComponent == "..")
            ? "\(immichID).jpg" : lastComponent

        let downloaded = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-rotate-\(UUID().uuidString)-\(filename)")
        try await client.downloadOriginal(id: immichID, to: downloaded)
        defer { try? FileManager.default.removeItem(at: downloaded) }

        let rotated: URL
        if turns == 2 {
            let half = try await rotator.rotateRemoteOriginal(fileURL: downloaded, clockwise: true)
            defer { try? FileManager.default.removeItem(at: half) }
            rotated = try await rotator.rotateRemoteOriginal(fileURL: half, clockwise: true)
        } else {
            rotated = try await rotator.rotateRemoteOriginal(fileURL: downloaded, clockwise: turns == 1)
        }
        defer { try? FileManager.default.removeItem(at: rotated) }

        try await replaceRemoteFile(oldID: immichID, fileURL: rotated, exportedFilename: filename,
                                    record: record, localIdentifier: nil, localModifiedAt: nil,
                                    width: nil, height: nil, swapDimensions: turns != 2)
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
    /// `pushLocalRendition` (push a local photo's current rendition).
    ///
    /// The replacement is uploaded with the original's true capture instant, which v3.1.0
    /// honours. Without that the new asset would take "now" as its capture date and jump to
    /// the top of the timeline.
    ///
    /// `localIdentifier` is set when `fileURL` is that local photo's current rendition.
    func replaceRemoteFile(oldID: String, fileURL: URL, exportedFilename: String,
                           record: RemoteAssetRecord, localIdentifier: String?,
                           localModifiedAt: Date?, width: Int?, height: Int?,
                           swapDimensions: Bool = true) async throws {
        let client = try makeClient()
        let old = try await client.assetInfo(id: oldID)
        let capture = ReplacementPlan.captureTime(fileCreatedAt: old.fileCreatedAt,
                                                  localDateTime: old.localDateTime,
                                                  fallback: Date(timeIntervalSince1970: record.captureAt))
        let name = ReplacementPlan.filename(serverName: old.originalFileName ?? record.fileName,
                                            exportedName: exportedFilename)
        let upload = try await client.uploadReplacement(fileURL: fileURL,
                                                        filename: name,
                                                        deviceID: session.deviceID,
                                                        fileCreatedAt: capture.instant,
                                                        fileModifiedAt: capture.instant)
        do {
            try await finishReplacement(oldID: oldID, newID: upload.id,
                                        newChecksumHex: upload.checksumHex,
                                        isDuplicate: upload.isDuplicate, capture: capture,
                                        record: record, localIdentifier: localIdentifier,
                                        localModifiedAt: localModifiedAt, width: width, height: height,
                                        swapDimensions: swapDimensions)
        } catch {
            // Cancellation included: the upload did happen.
            throw ReplacementIncomplete(newID: upload.id, newChecksumHex: upload.checksumHex,
                                        underlying: error)
        }
    }

    /// Everything after the upload. Also what a retry calls when a pending edit remembers an
    /// upload whose replacement never finished.
    func finishReplacement(oldID: String, newID: String, newChecksumHex: String,
                           isDuplicate: Bool, capture: (instant: Date, offsetSeconds: Int),
                           record: RemoteAssetRecord, localIdentifier: String?,
                           localModifiedAt: Date?, width: Int?, height: Int?,
                           swapDimensions: Bool = true) async throws {
        // `newID == oldID`: the server already holds these bytes as this very asset.
        if newID != oldID {
            let client = try makeClient()
            if isDuplicate {
                // The server may hold these bytes in its trash, which is no home for the photo.
                try await ensureLive(immichID: newID, client: client)
            }
            // The multipart timestamps only stick when the file carries no date of its own,
            // which is true of a rotated JPEG but not a remuxed video, and a duplicate keeps
            // whatever date it already had.
            try await client.updateCaptureDate(id: newID, to: capture.instant,
                                               offsetSeconds: capture.offsetSeconds)
            // Only trash the original once the replacement is safely stored.
            try await client.deleteAssets(ids: [oldID])
        }
        try await repointAfterReplacement(oldID: oldID, newID: newID, newChecksumHex: newChecksumHex,
                                          record: record, localIdentifier: localIdentifier,
                                          localModifiedAt: localModifiedAt, width: width, height: height,
                                          swapDimensions: swapDimensions)
    }

    /// Swaps the replacement in for the old asset locally, so the grid updates without waiting
    /// for the next metadata sync.
    ///
    /// The link is re-keyed to the new bytes' checksum: a full sync replay drops any link whose
    /// checksum does not match its server row. `width`/`height` are the authoritative new
    /// dimensions when known; omitting them swaps the old ones for a 90° replacement (when
    /// `newID != oldID` and `swapDimensions` is true).
    private func repointAfterReplacement(oldID: String, newID: String, newChecksumHex: String,
                                         record: RemoteAssetRecord, localIdentifier: String?,
                                         localModifiedAt: Date?, width: Int?, height: Int?,
                                         swapDimensions: Bool) async throws {
        let writer = try database.writer()
        try await writer.write { db in
            let linkedLocal = try localIdentifier ?? String.fetchOne(db, sql: """
                SELECT local_identifier FROM facet_links
                WHERE immich_id = ? AND local_identifier IS NOT NULL LIMIT 1
                """, arguments: [oldID])

            var replaced = record
            replaced.immichID = newID
            replaced.checksumHex = newChecksumHex
            // The next sync replaces this row with the server's own; this bridges until then.
            if let width, let height {
                replaced.width = width
                replaced.height = height
            } else if newID != oldID, swapDimensions {
                replaced.width = width ?? record.height
                replaced.height = height ?? record.width
            } else {
                replaced.width = width ?? record.width
                replaced.height = height ?? record.height
            }
            replaced.isTrashed = false
            replaced.updatedAt = Date().timeIntervalSince1970
            try replaced.save(db)
            if newID != oldID {
                try db.execute(sql: "DELETE FROM remote_assets WHERE immich_id = ?", arguments: [oldID])
            }

            try db.execute(sql: "UPDATE facet_links SET immich_id = NULL WHERE immich_id IN (?, ?)",
                           arguments: [oldID, newID])
            if let linkedLocal {
                try db.execute(sql: "DELETE FROM facet_links WHERE local_identifier = ?",
                               arguments: [linkedLocal])
            }
            try db.execute(sql: """
                INSERT INTO facet_links (checksum_hex, local_identifier, immich_id) VALUES (?, ?, ?)
                ON CONFLICT(checksum_hex) DO UPDATE SET
                    local_identifier = excluded.local_identifier, immich_id = excluded.immich_id
                """, arguments: [newChecksumHex, linkedLocal, newID])
            try db.execute(sql: "DELETE FROM facet_links WHERE local_identifier IS NULL AND immich_id IS NULL")

            // Only when the bytes pushed are the local photo's own: otherwise backup_state
            // would claim a checksum the local photo does not have.
            if let localIdentifier {
                try db.execute(sql: """
                    UPDATE backup_state
                    SET checksum_hex = ?, state = 'uploaded', modified_at = ?,
                        retry_count = 0, next_attempt_at = 0, last_error = NULL
                    WHERE local_identifier = ?
                    """, arguments: [newChecksumHex, localModifiedAt?.timeIntervalSince1970, localIdentifier])
            }
        }
        // Every rotation and pending-edit retry ends here.
        changesContinuation.yield(.assets([oldID, newID]))
    }

    /// Takes the asset out of the server's trash if it is in it.
    func ensureLive(immichID: String, client: ImmichClient) async throws {
        guard try await client.assetInfo(id: immichID).isTrashed == true else { return }
        try await restoreFromTrash(ids: [immichID], client: client)
    }

    func restoreFromTrash(ids: [String], client: ImmichClient) async throws {
        guard !ids.isEmpty else { return }
        try await client.restoreAssets(ids: ids)
        let writer = try database.writer()
        try await writer.write { db in
            for start in stride(from: 0, to: ids.count, by: 500) {
                let chunk = Array(ids[start..<min(start + 500, ids.count)])
                let placeholders = databaseQuestionMarks(count: chunk.count)
                try db.execute(sql: "UPDATE remote_assets SET is_trashed = 0 WHERE immich_id IN (\(placeholders))",
                               arguments: StatementArguments(chunk))
            }
        }
        changesContinuation.yield(.assets(Set(ids)))
    }

    func deleteRemote(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let client = try makeClient()
        try await client.deleteAssets(ids: ids)

        let writer = try database.writer()
        try await writer.write { db in
            for start in stride(from: 0, to: ids.count, by: 500) {
                let chunk = Array(ids[start..<min(start + 500, ids.count)])
                let placeholders = databaseQuestionMarks(count: chunk.count)
                try db.execute(sql: "UPDATE remote_assets SET is_trashed = 1 WHERE immich_id IN (\(placeholders))",
                               arguments: StatementArguments(chunk))
                try db.execute(sql: "UPDATE facet_links SET immich_id = NULL WHERE immich_id IN (\(placeholders))",
                               arguments: StatementArguments(chunk))
            }
            try db.execute(sql: "DELETE FROM facet_links WHERE local_identifier IS NULL AND immich_id IS NULL")
        }
        changesContinuation.yield(.assets(Set(ids)))
    }
}
