import Foundation
import GRDB

/// The upload queue's SQL over `backup_state` (DESIGN.md §12), kept apart from `SyncEngine` so
/// it can be tested without PhotoKit.
enum BackupQueue {
    /// Shown as "N failed"; they are still retried.
    static let persistentFailureThreshold = 5

    private static let pending = BackupStateRecord.State.pending.rawValue
    private static let deduped = BackupStateRecord.State.deduped.rawValue
    private static let uploading = BackupStateRecord.State.uploading.rawValue
    private static let failed = BackupStateRecord.State.failed.rawValue
    private static let ineligible = BackupStateRecord.State.ineligible.rawValue

    /// Deduped rows, and checksummed failed rows whose wait is over, oldest first.
    /// Rows still in `pending` (un-checksummed or un-deduped) are never selected for upload.
    static func uploadCandidates(_ db: Database, now: Date, limit: Int) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT local_identifier FROM backup_state
            WHERE state = ? OR (state = ? AND checksum_hex IS NOT NULL AND next_attempt_at <= ?)
            ORDER BY updated_at ASC
            LIMIT ?
            """, arguments: [deduped, failed, now.timeIntervalSince1970, limit])
    }

    /// What a run can still act on now: pending, deduped, uploading, and failed rows that are due.
    static func actionableCount(_ db: Database, now: Date) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM backup_state
            WHERE state IN (?, ?, ?) OR (state = ? AND next_attempt_at <= ?)
            """, arguments: [pending, deduped, uploading, failed, now.timeIntervalSince1970]) ?? 0
    }

    static func recordFailure(_ db: Database, identifier: String, error: String, now: Date,
                              ineligibleAfter: Int? = nil) throws {
        let failures = (try Int.fetchOne(db, sql: "SELECT retry_count FROM backup_state WHERE local_identifier = ?",
                                         arguments: [identifier]) ?? 0) + 1
        let at = now.timeIntervalSince1970
        if let threshold = ineligibleAfter, failures >= threshold {
            try db.execute(sql: """
                UPDATE backup_state
                SET state = ?, retry_count = ?, last_error = ?, updated_at = ?, next_attempt_at = 0
                WHERE local_identifier = ?
                """, arguments: [ineligible, failures, error, at, identifier])
            return
        }
        try db.execute(sql: """
            UPDATE backup_state
            SET state = ?, retry_count = ?, last_error = ?, updated_at = ?, next_attempt_at = ?
            WHERE local_identifier = ?
            """, arguments: [failed, failures, error, at,
                             at + RetryPolicy.delay(afterFailures: failures), identifier])
    }

    /// Failed and ineligible rows go back to pending with a clean slate.
    static func resetFailures(_ db: Database) throws {
        try db.execute(sql: """
            UPDATE backup_state
            SET state = ?, retry_count = 0, next_attempt_at = 0, last_error = NULL
            WHERE state IN (?, ?)
            """, arguments: [pending, failed, ineligible])
    }

    static func counts(_ db: Database) throws -> (remaining: Int, failed: Int, retrying: Int) {
        let placeholders = databaseQuestionMarks(count: BackupStateRecord.outstandingStates.count)
        let remaining = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM backup_state WHERE state IN (\(placeholders))
            """, arguments: StatementArguments(BackupStateRecord.outstandingStates)) ?? 0
        let failedTotal = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM backup_state WHERE state = ?",
                                           arguments: [failed]) ?? 0
        let persistent = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM backup_state WHERE state = ? AND retry_count >= ?
            """, arguments: [failed, persistentFailureThreshold]) ?? 0
        return (remaining, persistent, failedTotal - persistent)
    }

    // MARK: - Library scan

    struct LibraryRow {
        let identifier: String
        let created: Date
        let modified: Date?
        let kind: MediaKind
    }

    struct ScanResult: Equatable {
        var edited: [String] = []
        var requeued: [String] = []
    }

    /// Slack for the `Date` → `Double` round trip.
    private static let modificationTolerance: TimeInterval = 0.5

    /// Brings backup_state in line with the library: adds rows for new assets and notices
    /// uploaded ones that have changed since their bytes were read.
    static func applyLibraryScan(_ db: Database, rows: [LibraryRow], anchor: Date?, now: Date) throws -> ScanResult {
        var known: [String: (state: String, modifiedAt: Double?)] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT local_identifier, state, modified_at FROM backup_state") {
            known[row["local_identifier"]] = (row["state"], row["modified_at"])
        }
        let uploaded = BackupStateRecord.State.uploaded.rawValue
        var result = ScanResult()

        for row in rows {
            guard let existing = known[row.identifier] else {
                // Out of scope assets are recorded, not skipped, so upgrading later is a
                // state flip rather than a re-enumeration of the whole library.
                let state: BackupStateRecord.State =
                    (anchor.map { row.created < $0 } ?? false) ? .outOfScope : .pending
                try BackupStateRecord(localIdentifier: row.identifier, state: state, updatedAt: now).insert(db)
                continue
            }
            guard existing.state == uploaded else { continue }
            guard let stored = existing.modifiedAt else {
                // First sight since this was recorded: a baseline is all that can be taken.
                if let modified = row.modified {
                    try db.execute(sql: "UPDATE backup_state SET modified_at = ? WHERE local_identifier = ?",
                                   arguments: [modified.timeIntervalSince1970, row.identifier])
                }
                continue
            }
            guard let modified = row.modified,
                  modified.timeIntervalSince1970 > stored + modificationTolerance else { continue }

            let immichID = try String.fetchOne(db, sql: """
                SELECT immich_id FROM facet_links
                WHERE local_identifier = ? AND immich_id IS NOT NULL LIMIT 1
                """, arguments: [row.identifier])
            if let immichID {
                // Only a check: the push compares checksums and sends nothing if the bytes match.
                try PendingEditRecord.upsert(db, localIdentifier: row.identifier, immichID: immichID,
                                             editType: .rotation, mediaKind: row.kind, payload: nil,
                                             now: now.timeIntervalSince1970)
                try db.execute(sql: "UPDATE backup_state SET modified_at = ? WHERE local_identifier = ?",
                               arguments: [modified.timeIntervalSince1970, row.identifier])
                result.edited.append(row.identifier)
            } else {
                // No known server copy to replace; the ordinary pipeline uploads it afresh.
                try db.execute(sql: "DELETE FROM facet_links WHERE local_identifier = ? AND immich_id IS NULL",
                               arguments: [row.identifier])
                try db.execute(sql: """
                    UPDATE backup_state
                    SET state = ?, checksum_hex = NULL, modified_at = NULL,
                        retry_count = 0, next_attempt_at = 0, last_error = NULL
                    WHERE local_identifier = ?
                    """, arguments: [pending, row.identifier])
                result.requeued.append(row.identifier)
            }
        }
        return result
    }
}
