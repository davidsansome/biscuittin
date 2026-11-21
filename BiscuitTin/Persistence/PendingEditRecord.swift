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
    var nextAttemptAt: Double
    /// Set when a replacement was uploaded but the old asset was not yet retired; a retry
    /// finishes that replacement rather than uploading another.
    var uploadedID: String?
    var uploadedChecksum: String?

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
        case nextAttemptAt = "next_attempt_at"
        case uploadedID = "uploaded_id"
        case uploadedChecksum = "uploaded_checksum"
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
        updatedAt: Double,
        nextAttemptAt: Double = 0,
        uploadedID: String? = nil,
        uploadedChecksum: String? = nil) {
        self.id = nil
        self.localIdentifier = localIdentifier
        self.immichID = immichID
        self.editTypeRaw = editType.rawValue
        self.mediaKindRaw = Int(mediaKind.rawValue)
        self.payload = payload
        self.retryCount = retryCount
        self.lastError = lastError
        self.updatedAt = updatedAt
        self.nextAttemptAt = nextAttemptAt
        self.uploadedID = uploadedID
        self.uploadedChecksum = uploadedChecksum
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Queues an edit, or resets the retry clock of the one already queued for the same asset.
    ///
    /// `uploadedID`/`uploadedChecksum` name a replacement that reached the server but whose
    /// old asset was not retired.
    static func upsert(_ db: Database,
                       localIdentifier: String?,
                       immichID: String,
                       editType: EditType,
                       mediaKind: MediaKind,
                       payload: String?,
                       uploadedID: String? = nil,
                       uploadedChecksum: String? = nil,
                       now: Double) throws {
        let existing: PendingEditRecord?
        if let localIdentifier {
            existing = try PendingEditRecord
                .filter(sql: "local_identifier = ?", arguments: [localIdentifier])
                .fetchOne(db)
        } else {
            existing = try PendingEditRecord
                .filter(sql: "immich_id = ? AND local_identifier IS NULL", arguments: [immichID])
                .fetchOne(db)
        }

        if var row = existing {
            if localIdentifier == nil,
               editType == .rotation,
               row.uploadedID == nil,
               uploadedID == nil,
               let existingPayloadString = row.payload,
               let existingPayload = RotationPayload(jsonString: existingPayloadString),
               let incomingPayloadString = payload,
               let incomingPayload = RotationPayload(jsonString: incomingPayloadString) {
                let combined = existingPayload.composed(with: incomingPayload)
                if combined.quarterTurns == 0 {
                    try row.delete(db)
                    return
                }
                row.payload = combined.jsonString
            } else {
                row.payload = payload
            }
            row.immichID = immichID
            row.mediaKindRaw = Int(mediaKind.rawValue)
            row.retryCount = 0
            row.lastError = nil
            row.updatedAt = now
            row.nextAttemptAt = 0
            // An unfinished replacement already on record must not be forgotten because a
            // later attempt failed before uploading anything.
            if let uploadedID {
                row.uploadedID = uploadedID
                row.uploadedChecksum = uploadedChecksum
            }
            try row.update(db)
        } else {
            try PendingEditRecord(localIdentifier: localIdentifier, immichID: immichID,
                                  editType: editType, mediaKind: mediaKind, payload: payload,
                                  updatedAt: now, uploadedID: uploadedID,
                                  uploadedChecksum: uploadedChecksum).insert(db)
        }
    }
}

/// The remote-only fallback payload for `EditType.rotation` — see `PendingEditRecord`'s doc
/// comment for why this is only meaningful when there is no local facet to read state from.
struct RotationPayload: Codable, Equatable {
    /// Net clockwise 90° quarter-turns, normalized to `0..<4` (1 = 90° CW, 2 = 180°, 3 = 90° CCW).
    let quarterTurns: Int

    /// True for a single clockwise turn; false for a single counter-clockwise turn.
    var clockwise: Bool { quarterTurns == 1 }

    var jsonString: String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    init(clockwise: Bool) {
        self.quarterTurns = clockwise ? 1 : 3
    }

    init(quarterTurns: Int) {
        self.quarterTurns = ((quarterTurns % 4) + 4) % 4
    }

    func composed(with other: RotationPayload) -> RotationPayload {
        RotationPayload(quarterTurns: quarterTurns + other.quarterTurns)
    }

    private enum CodingKeys: String, CodingKey {
        case quarterTurns, clockwise
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let turns = try container.decodeIfPresent(Int.self, forKey: .quarterTurns) {
            self.quarterTurns = ((turns % 4) + 4) % 4
        } else {
            let cw = try container.decode(Bool.self, forKey: .clockwise)
            self.quarterTurns = cw ? 1 : 3
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(quarterTurns, forKey: .quarterTurns)
        try container.encode(clockwise, forKey: .clockwise)
    }

    init?(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(RotationPayload.self, from: data) else { return nil }
        self = decoded
    }
}
