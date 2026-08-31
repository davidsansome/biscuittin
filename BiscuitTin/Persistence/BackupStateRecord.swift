import Foundation
import GRDB

/// Per-asset upload state (DESIGN.md §7.3, §12).
struct BackupStateRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "backup_state"

    enum State: String, Codable {
        case pending
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

    enum CodingKeys: String, CodingKey {
        case localIdentifier = "local_identifier"
        case checksumHex = "checksum_hex"
        case state
        case lastError = "last_error"
        case retryCount = "retry_count"
        case updatedAt = "updated_at"
    }

    var backupState: State { State(rawValue: state) ?? .pending }

    init(localIdentifier: String,
         checksumHex: String? = nil,
         state: State = .pending,
         lastError: String? = nil,
         retryCount: Int = 0,
         updatedAt: Date = Date()) {
        self.localIdentifier = localIdentifier
        self.checksumHex = checksumHex
        self.state = state.rawValue
        self.lastError = lastError
        self.retryCount = retryCount
        self.updatedAt = updatedAt.timeIntervalSince1970
    }

    /// Assets in these states still owe the server an upload, and so count toward the
    /// "not backed up" badge (requirement 14).
    static let outstandingStates: [String] = [
        State.pending.rawValue, State.uploading.rawValue, State.failed.rawValue
    ]
}
