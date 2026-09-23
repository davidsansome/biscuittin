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

    struct ServerPing: Decodable {
        let res: String
    }

    /// Public, unlike `ServerAbout`, so the version gate can run before sign-in.
    struct ServerVersion: Decodable, Equatable {
        let major: Int
        let minor: Int
        let patch: Int

        var description: String { "v\(major).\(minor).\(patch)" }
    }

    /// The subset of `/api/server/features` that shapes the sign-in screen.
    struct ServerFeatures: Decodable, Equatable {
        let oauth: Bool
        let oauthAutoLaunch: Bool
        let passwordLogin: Bool

        init(oauth: Bool, oauthAutoLaunch: Bool, passwordLogin: Bool) {
            self.oauth = oauth
            self.oauthAutoLaunch = oauthAutoLaunch
            self.passwordLogin = passwordLogin
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            oauth = try c.decodeIfPresent(Bool.self, forKey: .oauth) ?? false
            oauthAutoLaunch = try c.decodeIfPresent(Bool.self, forKey: .oauthAutoLaunch) ?? false
            // Absent on a server that predates the flag, all of which allowed password login.
            passwordLogin = try c.decodeIfPresent(Bool.self, forKey: .passwordLogin) ?? true
        }

        private enum CodingKeys: String, CodingKey {
            case oauth, oauthAutoLaunch, passwordLogin
        }
    }

    struct ServerConfig: Decodable, Equatable {
        let loginPageMessage: String?
        let oauthButtonText: String?
    }

    /// `/.well-known/immich`, which lets a server live behind a proxy path while users type
    /// only its hostname.
    struct WellKnown: Decodable {
        struct API: Decodable { let endpoint: String }
        let api: API
    }

    struct OAuthAuthorizeRequest: Encodable {
        let redirectUri: String
        let state: String
        let codeChallenge: String
    }

    struct OAuthAuthorizeResponse: Decodable {
        let url: String
    }

    struct OAuthCallbackRequest: Encodable {
        let url: String
        let state: String
        let codeVerifier: String
    }

    struct ErrorBody: Decodable {
        let message: String
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

        /// From a `sync/stream` `AssetExifV1` line — same information, different shape
        /// (`iso`/`exifImageWidth`/`exifImageHeight` are integers there, doubles here).
        init(_ exif: SyncAssetExifV1) {
            make = exif.make
            model = exif.model
            lensModel = exif.lensModel
            fNumber = exif.fNumber
            focalLength = exif.focalLength
            iso = exif.iso.map(Double.init)
            exposureTime = exif.exposureTime
            latitude = exif.latitude
            longitude = exif.longitude
            city = exif.city
            state = exif.state
            country = exif.country
            fileSizeInByte = exif.fileSizeInByte.map(Int64.init)
            exifImageWidth = exif.exifImageWidth.map(Double.init)
            exifImageHeight = exif.exifImageHeight.map(Double.init)
            dateTimeOriginal = exif.dateTimeOriginal
            description = exif.description
        }
    }

    /// An asset's duration, however the server chooses to express it.
    ///
    /// v3.1.0 sends **integer milliseconds** for videos (4000 for a four-second clip) and null
    /// for images, but older builds send a `"H:MM:SS.sss"` string. Accepting only the string
    /// form made the whole sync page fail to decode, so no remote asset appeared at all — and
    /// treating the number as seconds would have put "1:06:40" on a four-second video.
    struct Duration: Decodable, Equatable {
        let seconds: Double

        init(seconds: Double) { self.seconds = seconds }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                seconds = 0
            } else if let milliseconds = try? container.decode(Double.self) {
                seconds = milliseconds / 1000
            } else if let text = try? container.decode(String.self) {
                seconds = Immich.parseDuration(text)
            } else {
                seconds = 0
            }
        }
    }

    /// Decodes a value, or yields nil instead of failing its whole container.
    struct Failable<Wrapped: Decodable>: Decodable {
        let value: Wrapped?
        init(from decoder: Decoder) throws {
            value = try? Wrapped(from: decoder)
        }
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
        let duration: Duration?
        let isTrashed: Bool?
        let isOffline: Bool?
        let livePhotoVideoId: String?
        let exifInfo: ExifInfo?

        var mediaKind: MediaKind {
            if type == .video { return .video }
            return livePhotoVideoId != nil ? .livePhoto : .image
        }

        var durationSeconds: Double {
            duration?.seconds ?? 0
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
            /// Assets on the page that could not be decoded at all.
            let skippedCount: Int

            private enum CodingKeys: String, CodingKey {
                case items, total, count, nextPage
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                total = try container.decodeIfPresent(Int.self, forKey: .total)
                count = try container.decodeIfPresent(Int.self, forKey: .count)
                nextPage = try container.decodeIfPresent(String.self, forKey: .nextPage)

                // Decode assets individually: a single unexpected field otherwise fails the
                // entire page, which is how one numeric `duration` hid an entire library.
                let raw = try container.decodeIfPresent([Failable<Asset>].self, forKey: .items) ?? []
                items = raw.compactMap(\.value)
                skippedCount = raw.count - items.count
            }
        }
        let assets: Bucket
    }

    // MARK: - Sync stream (D9)
    //
    // Verified against a real v3.1.0 server: `POST /sync/stream` reports changes against a
    // cursor Immich tracks server-side per access token — upserts *and* explicit delete events —
    // replacing both the paged full/delta sync above and the weekly hard-delete sweep it needed.
    // A hard delete shows up as an `AssetDeleteV1` line on the very next call, so there is
    // nothing left to reconcile locally.

    /// What `sync/stream` may be asked for. Note the plural: the *request* names are "AssetsV2"
    /// / "AssetExifsV1", but each returned *line*'s `type` is the singular "AssetV2" etc.
    /// (`SyncEntityType` below) — easy to conflate, verified against the live server.
    enum SyncRequestType: String, Encodable {
        case assets = "AssetsV2"
        case assetExifs = "AssetExifsV1"
    }

    struct SyncStreamRequest: Encodable {
        let types: [SyncRequestType]
        let reset: Bool
    }

    struct SyncAckRequest: Encodable {
        let acks: [String]
    }

    /// Just enough of a `sync/stream` line to route it to the right payload type. Decoded twice
    /// per line (header, then typed payload) rather than a custom single-pass decoder — simpler,
    /// and a line is a few hundred bytes at most.
    struct SyncLineHeader: Decodable {
        let type: String
        let ack: String
    }

    struct SyncLine<Payload: Decodable>: Decodable {
        let data: Payload
        let ack: String
    }

    enum AssetVisibility: String, Decodable {
        case archive, timeline, hidden, locked
    }

    struct SyncAssetV2: Decodable {
        let id: String
        let originalFileName: String?
        let checksum: String?
        let fileCreatedAt: String?
        let fileModifiedAt: String?
        let localDateTime: String?
        /// Milliseconds, nullable — unlike the mixed string/int `Duration` the old
        /// `search/metadata` endpoint sends (see `Duration` above).
        let duration: Int?
        let type: AssetType
        /// Non-nil once trashed; still present, not yet purged (D9).
        let deletedAt: String?
        let visibility: AssetVisibility
        let livePhotoVideoId: String?
        let width: Int?
        let height: Int?

        var checksumHex: String { Immich.normalizedChecksumHex(checksum) }
        var durationSeconds: Double { Double(duration ?? 0) / 1000 }
    }

    /// A separate sync line from the asset it describes — may arrive before, after, or without
    /// its matching `AssetV2` line in a given batch (D9).
    struct SyncAssetExifV1: Decodable {
        let assetId: String
        let description: String?
        let exifImageWidth: Int?
        let exifImageHeight: Int?
        let fileSizeInByte: Int?
        let dateTimeOriginal: String?
        let latitude: Double?
        let longitude: Double?
        let city: String?
        let state: String?
        let country: String?
        let make: String?
        let model: String?
        let lensModel: String?
        let fNumber: Double?
        let focalLength: Double?
        let iso: Int?
        let exposureTime: String?
    }

    struct SyncAssetDeleteV1: Decodable {
        let assetId: String
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
            /// True when the matching asset is in the server's trash. Immich still reports it
            /// as a duplicate, but a copy awaiting permanent deletion is not a backup.
            let isTrashed: Bool?
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
    case invalidAPIKey
    case unreachable
    /// Something answered, but not as Immich.
    case notImmich
    case oauthFailed(String?)
    /// A 400 carrying the server's own explanation.
    case rejected(String)
    case serverTooOld(found: String, required: String)
    case http(status: Int)
    case decoding(String)
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No Immich server is configured."
        case .unauthorized: return "Session expired. Sign in again."
        case .invalidCredentials: return "Incorrect email or password."
        case .invalidAPIKey:
            return "That API key wasn’t accepted. Check it’s complete and has the permissions "
                + "Biscuit Tin needs."
        case .unreachable: return "Server unreachable."
        case .notImmich: return "That address doesn’t look like an Immich server."
        case let .oauthFailed(detail):
            return detail.map { "Sign-in didn’t complete: \($0)" } ?? "Sign-in didn’t complete."
        case let .serverTooOld(found, required):
            return "This server runs Immich \(found); \(required) or newer is required."
        case let .http(status): return "Server error (\(status))."
        case let .rejected(message): return message
        case let .decoding(detail): return "Unexpected response from server. \(detail)"
        case .invalidURL: return "That server URL isn’t valid."
        }
    }
}
