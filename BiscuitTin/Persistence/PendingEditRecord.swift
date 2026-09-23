import Foundation
import GRDB

/// Row in `pending_edits` — a local edit whose remote leg failed, queued for catch-up once the
/// server is reachable again (D22).
///
/// Reconciliation takes one of two shapes, chosen by whether `localIdentifier` is set:
///
/// - **A local facet exists.** PhotoKit content edits are always baked into pixels (never a
///   flag-only change — see DESIGN.md's "Why image rotation re-encodes"), so the local asset's
///   *current* rendition already **is** the final state, however many edits landed on it while
///   offline, in whatever order. `payload` is unused here: there is nothing to remember, because
///   the processor re-reads PhotoKit fresh at retry time rather than replaying a stored
///   operation. Re-enqueuing the same asset is a no-op beyond resetting the retry clock, which
///   is what the partial unique index on `local_identifier` enforces.
/// - **No local facet** (a remote-only asset). There is no local truth to fall back on, so
///   `payload` carries what the retry needs to replay the operation against whatever the remote
///   currently has — the same model the online path already uses, and the same last-writer-wins
///   exposure it already accepts (D10).
///
/// `mediaKind` is captured at enqueue time so a remote-only retry can look up the right
/// `AssetRotator` without re-resolving a `PHAsset` that, by definition, does not exist here.
struct PendingEditRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "pending_edits"

    /// What kind of edit this is. Currently only rotation; a future kind adds a case here and a
    /// branch in `RemoteLibraryService.reconcile(_:)`, not a schema change — `payload` is already
    /// a free-form column for whatever a new type's remote-only fallback needs.
    enum EditType: String {
        case rotation
    }

    var id: Int64?
    var localIdentifier: String?
    var immichID: String
    var editTypeRaw: String
    var mediaKindRaw: Int
    var payload: String?
    var retryCount: Int
    var lastError: String?
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case localIdentifier = "local_identifier"
        case immichID = "immich_id"
        case editTypeRaw = "edit_type"
        case mediaKindRaw = "media_kind"
        case payload
        case retryCount = "retry_count"
        case lastError = "last_error"
        case updatedAt = "updated_at"
    }

    // `editType`/`mediaKind` are deliberately computed, not stored Codable properties: GRDB's
    // Codable-record bridging JSON-encodes a custom RawRepresentable type rather than storing
    // its raw value directly (it would land as the quoted text `"rotation"`, not `rotation`).
    // Storing the raw value explicitly and exposing the typed enum as a computed property —
    // exactly `RemoteAssetRecord.type`/`mediaKind`'s existing pattern — sidesteps that.
    var editType: EditType { EditType(rawValue: editTypeRaw) ?? .rotation }
    var mediaKind: MediaKind { MediaKind(rawValue: UInt8(clamping: mediaKindRaw)) ?? .image }

    init(localIdentifier: String?,
        immichID: String,
        editType: EditType,
        mediaKind: MediaKind,
        payload: String?,
        retryCount: Int = 0,
        lastError: String? = nil,
        updatedAt: Double) {
        self.id = nil
        self.localIdentifier = localIdentifier
        self.immichID = immichID
        self.editTypeRaw = editType.rawValue
        self.mediaKindRaw = Int(mediaKind.rawValue)
        self.payload = payload
        self.retryCount = retryCount
        self.lastError = lastError
        self.updatedAt = updatedAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// The remote-only fallback payload for `EditType.rotation` — see `PendingEditRecord`'s doc
/// comment for why this is only meaningful when there is no local facet to read state from.
struct RotationPayload: Codable {
    let clockwise: Bool

    var jsonString: String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    init(clockwise: Bool) {
        self.clockwise = clockwise
    }

    init?(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(RotationPayload.self, from: data) else { return nil }
        self = decoded
    }
}
