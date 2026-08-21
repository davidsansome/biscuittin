import Foundation

/// Codable DTOs mirroring the Immich API (DESIGN.md D8, target v3.1.0).
///
/// Every field the app relies on is optional or defaulted where the server may omit it, so a
/// schema drift between server versions degrades a row rather than failing a whole sync page.
enum Immich {

    // MARK: - Auth and server

    struct LoginRequest: Encodable {
        let email: String
        let password: String
    }

    struct LoginResponse: Decodable {
        let accessToken: String
        let userId: String?
        let userEmail: String?
        let name: String?
    }

    struct ServerAbout: Decodable {
        let version: String
        let versionUrl: String?
    }

    struct UserResponse: Decodable {
        let id: String
        let email: String?
        let name: String?
    }

    // MARK: - Assets

    enum AssetType: String, Decodable {
        case image = "IMAGE"
        case video = "VIDEO"
        case audio = "AUDIO"
        case other = "OTHER"
    }

    struct ExifInfo: Codable {
        let make: String?
        let model: String?
        let lensModel: String?
        let fNumber: Double?
        let focalLength: Double?
        let iso: Double?
        let exposureTime: String?
        let latitude: Double?
        let longitude: Double?
        let city: String?
        let state: String?
        let country: String?
        let fileSizeInByte: Int64?
        let exifImageWidth: Double?
        let exifImageHeight: Double?
        let dateTimeOriginal: String?
        let description: String?
    }

    struct Asset: Decodable {
        let id: String
        /// Verified absent from v3.1.0 responses even when supplied at upload, so the
        /// `(deviceId, deviceAssetId)` link of D5 can never fire. Checksum is the only
        /// identity the server actually gives back.
        let deviceAssetId: String?
        let deviceId: String?
        let type: AssetType
        let originalFileName: String?
        /// Base64-encoded SHA-1 — see `checksumHex`.
        let checksum: String?
        /// v3.1.0 reports dimensions at the top level; `exifInfo` may omit them.
        let width: Int?
        let height: Int?
        let fileCreatedAt: String?
        let fileModifiedAt: String?
        let localDateTime: String?
        let updatedAt: String?
        /// Immich reports duration as "H:MM:SS.sss".
        let duration: String?
        let isTrashed: Bool?
        let isOffline: Bool?
        let livePhotoVideoId: String?
        let exifInfo: ExifInfo?

        var mediaKind: MediaKind {
            if type == .video { return .video }
            return livePhotoVideoId != nil ? .livePhoto : .image
        }

        var durationSeconds: Double {
            Immich.parseDuration(duration)
        }

        /// Prefers the local capture time so the merged timeline orders remote assets the same
        /// way the device would.
        var captureDate: Date {
            Immich.parseDate(localDateTime)
                ?? Immich.parseDate(fileCreatedAt)
                ?? Immich.parseDate(exifInfo?.dateTimeOriginal)
                ?? .distantPast
        }

        var updatedDate: Date? { Immich.parseDate(updatedAt) }

        /// SHA-1 as lowercase hex.
        ///
        /// The server returns it base64-encoded, but every local checksum in this app is hex
        /// (`LocalAssetExporter`), and `facet_links` is keyed on it. Storing the raw base64
        /// would mean a local and remote copy of the same photo never matched, so the asset
        /// would appear twice in the grid instead of once with two facets (D5).
        var checksumHex: String {
            Immich.normalizedChecksumHex(checksum)
        }

        var pixelWidth: Int32 {
            Int32(clamping: width ?? Int(exifInfo?.exifImageWidth ?? 0))
        }

        var pixelHeight: Int32 {
            Int32(clamping: height ?? Int(exifInfo?.exifImageHeight ?? 0))
        }
    }

    // MARK: - Search

    struct MetadataSearchRequest: Encodable {
        var page: Int = 1
        var size: Int = 1000
        var order: String = "desc"
        var withExif: Bool = true
        var withDeleted: Bool = false
        var isVisible: Bool? = true
        /// ISO-8601; drives delta sync (D9).
        var updatedAfter: String?
    }

    struct SearchPage: Decodable {
        struct Bucket: Decodable {
            let items: [Asset]
            let total: Int?
            let count: Int?
            let nextPage: String?
        }
        let assets: Bucket
    }

    // MARK: - Mutations

    struct DeleteRequest: Encodable {
        let ids: [String]
        let force: Bool
    }

    struct BulkUploadCheckItem: Encodable {
        let id: String
        let checksum: String
    }

    struct BulkUploadCheckRequest: Encodable {
        let assets: [BulkUploadCheckItem]
    }

    struct BulkUploadCheckResponse: Decodable {
        struct Result: Decodable {
            let id: String
            let action: String        // "accept" | "reject"
            let reason: String?       // "duplicate" | "unsupported-format"
            let assetId: String?      // set when the server already has it
        }
        let results: [Result]
    }

    struct UploadResponse: Decodable {
        let id: String
        let status: String            // "created" | "duplicate" | "replaced"
    }

    // MARK: - Parsing helpers

    /// Canonicalises a checksum to lowercase hex.
    ///
    /// Immich returns SHA-1 base64-encoded ("41ipRRJcK31MhPDdCW6B8j/1JJo="); this app keys
    /// everything on hex ("e358a945…"). `bulk-upload-check` happens to accept either, which is
    /// why only the *linking* path was affected — and why a mock speaking one convention could
    /// never have surfaced it.
    static func normalizedChecksumHex(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }

        // Already hex (40 chars for SHA-1): just normalise case.
        if raw.count == 40, raw.allSatisfy(\.isHexDigit) { return raw.lowercased() }

        guard let data = Data(base64Encoded: raw), !data.isEmpty else {
            // Unrecognised shape: keep it stable rather than dropping the value, so two rows
            // carrying the same odd checksum still link to each other.
            return raw.lowercased()
        }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    /// Immich emits ISO-8601 with and without fractional seconds depending on the field.
    static func parseDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        if let date = iso8601WithFraction.date(from: string) { return date }
        if let date = iso8601.date(from: string) { return date }
        return plainDateTime.date(from: string)
    }

    /// "0:01:23.500" → 83.5
    static func parseDuration(_ string: String?) -> Double {
        guard let string, !string.isEmpty else { return 0 }
        let parts = string.split(separator: ":")
        guard !parts.isEmpty else { return 0 }
        return parts.reduce(0.0) { total, part in
            total * 60 + (Double(part) ?? 0)
        }
    }

    private static let iso8601WithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// `localDateTime` can arrive without a zone designator.
    private static let plainDateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return f
    }()

    static func iso8601String(from date: Date) -> String {
        iso8601WithFraction.string(from: date)
    }
}

/// Errors surfaced to the UI (DESIGN.md §15).
enum ImmichError: LocalizedError, Equatable {
    case notConfigured
    /// An existing token was rejected — the session is over.
    case unauthorized
    /// The credentials just supplied were rejected. Distinct from `unauthorized`, which would
    /// otherwise tell a user signing in for the first time that their session had expired.
    case invalidCredentials
    case unreachable
    case serverTooOld(found: String, required: String)
    case http(status: Int)
    case decoding(String)
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No Immich server is configured."
        case .unauthorized: return "Session expired. Sign in again."
        case .invalidCredentials: return "Incorrect email or password."
        case .unreachable: return "Server unreachable."
        case let .serverTooOld(found, required):
            return "This server runs Immich \(found); \(required) or newer is required."
        case let .http(status): return "Server error (\(status))."
        case let .decoding(detail): return "Unexpected response from server. \(detail)"
        case .invalidURL: return "That server URL isn’t valid."
        }
    }
}
