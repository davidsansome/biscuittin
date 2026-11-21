import Foundation
import GRDB

/// Per-asset upload state (DESIGN.md §7.3, §12).
struct BackupStateRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "backup_state"

    enum State: String, Codable {
        case pending
        /// Checksummed and accepted by the server's duplicate check, ready to upload.
        case deduped
        case uploading
        case uploaded
        case failed
        /// Original unavailable (e.g. offloaded to iCloud and network-restricted).
        case ineligible
        /// Excluded by the "new items only" scope (D17).
        case outOfScope = "out_of_scope"
    }

    var localIdentifier: String
    var checksumHex: String?
    var state: String
    var lastError: String?
    var retryCount: Int
    var updatedAt: Double
    /// `PHAsset.modificationDate` when the bytes the server holds were read.
    var modifiedAt: Double?
    /// Earliest time a failed row may be tried again.
    var nextAttemptAt: Double

    enum CodingKeys: String, CodingKey {
        case localIdentifier = "local_identifier"
        case checksumHex = "checksum_hex"
        case state
        case lastError = "last_error"
        case retryCount = "retry_count"
        case updatedAt = "updated_at"
        case modifiedAt = "modified_at"
        case nextAttemptAt = "next_attempt_at"
    }

    var backupState: State { State(rawValue: state) ?? .pending }

    init(localIdentifier: String,
         checksumHex: String? = nil,
         state: State = .pending,
         lastError: String? = nil,
         retryCount: Int = 0,
         updatedAt: Date = Date(),
         modifiedAt: Double? = nil,
         nextAttemptAt: Double = 0) {
        self.localIdentifier = localIdentifier
        self.checksumHex = checksumHex
        self.state = state.rawValue
        self.lastError = lastError
        self.retryCount = retryCount
        self.updatedAt = updatedAt.timeIntervalSince1970
        self.modifiedAt = modifiedAt
        self.nextAttemptAt = nextAttemptAt
    }

    /// Assets in these states still owe the server an upload, and so count toward the
    /// "not backed up" badge (requirement 14).
    static let outstandingStates: [String] = [
        State.pending.rawValue, State.deduped.rawValue, State.uploading.rawValue, State.failed.rawValue
    ]
}
