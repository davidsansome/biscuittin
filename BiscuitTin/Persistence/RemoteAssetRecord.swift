import Foundation
import GRDB

/// Row in `remote_assets` — the local cache of Immich metadata (DESIGN.md §7.3).
struct RemoteAssetRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "remote_assets"

    var immichID: String
    var checksumHex: String
    var deviceAssetID: String?
    var deviceID: String?
    var type: String
    var livePhotoVideoID: String?
    var durationSeconds: Double
    var fileName: String?
    var captureAt: Double
    var width: Int?
    var height: Int?
    var isTrashed: Bool
    var exifJSON: String?
    /// Promoted out of `exif_json` so the timeline can build map-ready stubs without decoding
    /// JSON per asset (§20.1).
    var latitude: Double?
    var longitude: Double?
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case immichID = "immich_id"
        case checksumHex = "checksum_hex"
        case deviceAssetID = "device_asset_id"
        case deviceID = "device_id"
        case type
        case livePhotoVideoID = "live_photo_video_id"
        case durationSeconds = "duration_seconds"
        case fileName = "file_name"
        case captureAt = "capture_at"
        case width, height
        case isTrashed = "is_trashed"
        case exifJSON = "exif_json"
        case latitude, longitude
        case updatedAt = "updated_at"
    }

    var mediaKind: MediaKind {
        Self.mediaKind(type: type, livePhotoVideoID: livePhotoVideoID)
    }

    private static func mediaKind(type: String, livePhotoVideoID: String?) -> MediaKind {
        if type == Immich.AssetType.video.rawValue { return .video }
        return livePhotoVideoID != nil ? .livePhoto : .image
    }

    var stub: AssetStub {
        Self.stub(immichID: immichID, type: type, livePhotoVideoID: livePhotoVideoID,
                  durationSeconds: durationSeconds, captureAt: captureAt, width: width,
                  height: height, latitude: latitude, longitude: longitude)
    }

    /// The columns `stub(row:)` reads, in its order. Selecting only these rather than whole
    /// records skips decoding every row's EXIF JSON, which a stub never uses.
    static let stubColumns =
        "immich_id, type, live_photo_video_id, duration_seconds, capture_at, width, height, latitude, longitude"

    static func stub(row: Row) -> AssetStub {
        stub(immichID: row[0], type: row[1], livePhotoVideoID: row[2], durationSeconds: row[3],
             captureAt: row[4], width: row[5], height: row[6], latitude: row[7], longitude: row[8])
    }

    private static func stub(immichID: String, type: String, livePhotoVideoID: String?,
                             durationSeconds: Double, captureAt: Double, width: Int?, height: Int?,
                             latitude: Double?, longitude: Double?) -> AssetStub {
        AssetStub(id: .remote(immichID),
                  captureDate: Date(timeIntervalSince1970: captureAt),
                  hasLocal: false,
                  hasRemote: true,
                  kind: mediaKind(type: type, livePhotoVideoID: livePhotoVideoID),
                  durationSeconds: Float(durationSeconds),
                  pixelWidth: Int32(clamping: width ?? 0),
                  pixelHeight: Int32(clamping: height ?? 0),
                  latitude: latitude.map(Float.init) ?? .nan,
                  longitude: longitude.map(Float.init) ?? .nan)
    }

    init(_ asset: Immich.Asset) {
        immichID = asset.id
        // Normalised to hex so it can match a locally-computed checksum in `facet_links` (D5).
        checksumHex = asset.checksumHex
        deviceAssetID = asset.deviceAssetId
        deviceID = asset.deviceId
        type = asset.type.rawValue
        livePhotoVideoID = asset.livePhotoVideoId
        durationSeconds = asset.durationSeconds
        fileName = asset.originalFileName
        captureAt = asset.captureDate.timeIntervalSince1970
        width = asset.width ?? Int(asset.pixelWidth)
        height = asset.height ?? Int(asset.pixelHeight)
        isTrashed = asset.isTrashed ?? false
        exifJSON = asset.exifInfo.flatMap { info in
            (try? JSONEncoder().encode(info)).flatMap { String(data: $0, encoding: .utf8) }
        }
        latitude = asset.exifInfo?.latitude
        longitude = asset.exifInfo?.longitude
        updatedAt = (asset.updatedDate ?? Date()).timeIntervalSince1970
    }

    var exifInfo: Immich.ExifInfo? {
        guard let exifJSON, let data = exifJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Immich.ExifInfo.self, from: data)
    }

    // MARK: - Sync stream merge (D9)
    //
    // An `AssetV2` line and its `AssetExifV1` line are independent — one can change without the
    // other, and either may be missing from a given batch. `apply` therefore only ever *overlays*
    // fields the line actually carries, onto whatever this row already has, rather than
    // reconstructing the row from scratch and losing the other side.

    /// A not-yet-populated row for an id seen for the first time this batch. Always followed
    /// immediately by `apply(_ asset:)`, which fills in everything that matters.
    init(placeholderID immichID: String) {
        self.immichID = immichID
        checksumHex = ""
        deviceAssetID = nil
        deviceID = nil
        type = Immich.AssetType.image.rawValue
        livePhotoVideoID = nil
        durationSeconds = 0
        fileName = nil
        captureAt = 0
        width = nil
        height = nil
        isTrashed = false
        exifJSON = nil
        latitude = nil
        longitude = nil
        updatedAt = 0
    }

    /// Overlays a `sync/stream` `AssetV2` line. EXIF fields are left untouched — a changed asset
    /// row does not imply changed EXIF, which arrives as its own line.
    mutating func apply(_ asset: Immich.SyncAssetV2) {
        checksumHex = asset.checksumHex
        type = asset.type.rawValue
        livePhotoVideoID = asset.livePhotoVideoId
        durationSeconds = asset.durationSeconds
        fileName = asset.originalFileName
        captureAt = (Immich.parseDate(asset.localDateTime) ?? Immich.parseDate(asset.fileCreatedAt) ?? .distantPast)
            .timeIntervalSince1970
        if let assetWidth = asset.width { width = assetWidth }
        if let assetHeight = asset.height { height = assetHeight }
        // Immich reports trashing through `deletedAt`; the old `isTrashed` boolean doesn't exist
        // on this DTO.
        isTrashed = asset.deletedAt != nil
        updatedAt = Date().timeIntervalSince1970
    }

    /// Overlays a `sync/stream` `AssetExifV1` line. Dimensions fill in only where `apply(_
    /// asset:)` had none (v3.1.0 reports them at the asset's top level too, which takes priority).
    mutating func apply(_ exif: Immich.SyncAssetExifV1) {
        if width == nil { width = exif.exifImageWidth }
        if height == nil { height = exif.exifImageHeight }
        latitude = exif.latitude
        longitude = exif.longitude
        let info = Immich.ExifInfo(exif)
        exifJSON = (try? JSONEncoder().encode(info)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// Row in `facet_links` — the checksum-keyed join between a local and a remote copy (D5).
struct FacetLinkRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "facet_links"

    var checksumHex: String
    var localIdentifier: String?
    var immichID: String?

    enum CodingKeys: String, CodingKey {
        case checksumHex = "checksum_hex"
        case localIdentifier = "local_identifier"
        case immichID = "immich_id"
    }
}

/// Row in `kv` — sync cursors and small scalars.
struct KeyValueRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "kv"
    var key: String
    var value: String?
}
