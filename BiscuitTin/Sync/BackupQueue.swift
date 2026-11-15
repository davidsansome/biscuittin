import Foundation
import GRDB

/// The upload queue's SQL over `backup_state` (DESIGN.md §12), kept apart from `SyncEngine` so
/// it can be tested without PhotoKit.
enum BackupQueue {
    /// Shown as "N failed"; they are still retried.
    static let persistentFailureThreshold = 5

    private static let pending = BackupStateRecord.State.pending.rawValue
    private static let uploading = BackupStateRecord.State.uploading.rawValue
    private static let failed = BackupStateRecord.State.failed.rawValue
    private static let ineligible = BackupStateRecord.State.ineligible.rawValue

    /// Pending rows, and failed rows whose wait is over, oldest first.
    static func uploadCandidates(_ db: Database, now: Date, limit: Int) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT local_identifier FROM backup_state
            WHERE state = ? OR (state = ? AND next_attempt_at <= ?)
            ORDER BY updated_at ASC
            LIMIT ?
            """, arguments: [pending, failed, now.timeIntervalSince1970, limit])
    }

    /// What a run can still act on now: pending, uploading, and failed rows that are due.
    static func actionableCount(_ db: Database, now: Date) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM backup_state
            WHERE state IN (?, ?) OR (state = ? AND next_attempt_at <= ?)
            """, arguments: [pending, uploading, failed, now.timeIntervalSince1970]) ?? 0
    }

    static func recordFailure(_ db: Database, identifier: String, error: String, now: Date) throws {
        let failures = (try Int.fetchOne(db, sql: "SELECT retry_count FROM backup_state WHERE local_identifier = ?",
                                         arguments: [identifier]) ?? 0) + 1
        let at = now.timeIntervalSince1970
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
        let remaining = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM backup_state WHERE state IN (?, ?, ?)
            """, arguments: StatementArguments(BackupStateRecord.outstandingStates)) ?? 0
        let failedTotal = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM backup_state WHERE state = ?",
                                           arguments: [failed]) ?? 0
        let persistent = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM backup_state WHERE state = ? AND retry_count >= ?
            """, arguments: [failed, persistentFailureThreshold]) ?? 0
        return (remaining, persistent, failedTotal - persistent)
    }
}
