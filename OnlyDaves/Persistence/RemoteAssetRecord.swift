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
        case updatedAt = "updated_at"
    }

    var mediaKind: MediaKind {
        if type == Immich.AssetType.video.rawValue { return .video }
        return livePhotoVideoID != nil ? .livePhoto : .image
    }

    var stub: AssetStub {
        AssetStub(id: .remote(immichID),
                  captureDate: Date(timeIntervalSince1970: captureAt),
                  hasLocal: false,
                  hasRemote: true,
                  kind: mediaKind,
                  durationSeconds: Float(durationSeconds),
                  pixelWidth: Int32(clamping: width ?? 0),
                  pixelHeight: Int32(clamping: height ?? 0))
    }

    init(_ asset: Immich.Asset) {
        immichID = asset.id
        checksumHex = asset.checksum ?? ""
        deviceAssetID = asset.deviceAssetId
        deviceID = asset.deviceId
        type = asset.type.rawValue
        livePhotoVideoID = asset.livePhotoVideoId
        durationSeconds = asset.durationSeconds
        fileName = asset.originalFileName
        captureAt = asset.captureDate.timeIntervalSince1970
        width = Int(asset.pixelWidth)
        height = Int(asset.pixelHeight)
        isTrashed = asset.isTrashed ?? false
        exifJSON = asset.exifInfo.flatMap { info in
            (try? JSONEncoder().encode(info)).flatMap { String(data: $0, encoding: .utf8) }
        }
        updatedAt = (asset.updatedDate ?? Date()).timeIntervalSince1970
    }

    var exifInfo: Immich.ExifInfo? {
        guard let exifJSON, let data = exifJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Immich.ExifInfo.self, from: data)
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
