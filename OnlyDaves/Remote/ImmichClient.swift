import Foundation
import CryptoKit

/// Typed HTTP client for the Immich API (DESIGN.md §7.1).
///
/// Deliberately storage-free: it holds no cache, no database and no credentials of its own —
/// the token arrives through `tokenProvider`. That keeps it trivially testable with a stubbed
/// `URLProtocol`, which is how the endpoint contracts are pinned in `ImmichClientTests`.
///
/// Every call runs off the main actor with an explicit timeout and honours task cancellation
/// (§14 P5).
actor ImmichClient {
    enum ThumbnailSize: String {
        case thumbnail
        case preview
    }

    private let baseURL: URL
    private let session: URLSession
    private let tokenProvider: @Sendable () async -> String?

    private static let metadataTimeout: TimeInterval = 10
    private static let binaryTimeout: TimeInterval = 60

    init(baseURL: URL,
         session: URLSession = .shared,
         tokenProvider: @escaping @Sendable () async -> String?) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
    }

    // MARK: - Auth and server

    func login(email: String, password: String) async throws -> Immich.LoginResponse {
        try await send(path: "/api/auth/login",
                       method: "POST",
                       body: Immich.LoginRequest(email: email, password: password),
                       authenticated: false)
    }

    func serverAbout() async throws -> Immich.ServerAbout {
        try await send(path: "/api/server/about", method: "GET", authenticated: false)
    }

    func me() async throws -> Immich.UserResponse {
        try await send(path: "/api/users/me", method: "GET")
    }

    // MARK: - Metadata

    func searchAssets(_ request: Immich.MetadataSearchRequest) async throws -> Immich.SearchPage {
        try await send(path: "/api/search/metadata", method: "POST", body: request)
    }

    func assetInfo(id: String) async throws -> Immich.Asset {
        try await send(path: "/api/assets/\(id)", method: "GET")
    }

    // MARK: - Binary

    func thumbnailData(id: String, size: ThumbnailSize) async throws -> Data {
        try await data(path: "/api/assets/\(id)/thumbnail",
                       query: [URLQueryItem(name: "size", value: size.rawValue)])
    }

    func originalData(id: String) async throws -> Data {
        try await data(path: "/api/assets/\(id)/original")
    }

    /// Built, not executed: handed to `AVURLAsset` so the player streams directly (§10.1).
    func videoPlaybackRequest(id: String) async throws -> URLRequest {
        var request = try makeRequest(path: "/api/assets/\(id)/video/playback",
                                      method: "GET",
                                      timeout: Self.binaryTimeout)
        if let token = await tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Headers `AVURLAsset` needs to authenticate its own range requests.
    func playbackHeaders() async -> [String: String] {
        guard let token = await tokenProvider() else { return [:] }
        return ["Authorization": "Bearer \(token)"]
    }

    func playbackURL(id: String) -> URL {
        baseURL.appendingPathComponent("api/assets/\(id)/video/playback")
    }

    // MARK: - Mutations

    func deleteAssets(ids: [String], force: Bool = false) async throws {
        guard !ids.isEmpty else { return }
        _ = try await dataForRequest(
            makeRequest(path: "/api/assets",
                        method: "DELETE",
                        body: Immich.DeleteRequest(ids: ids, force: force),
                        timeout: Self.metadataTimeout))
    }

    func bulkUploadCheck(_ items: [Immich.BulkUploadCheckItem]) async throws
    -> Immich.BulkUploadCheckResponse {
        try await send(path: "/api/assets/bulk-upload-check",
                       method: "POST",
                       body: Immich.BulkUploadCheckRequest(assets: items))
    }

    /// Builds the multipart upload request. `SyncEngine` hands this to a *background*
    /// URLSession rather than executing it here, so uploads survive suspension (D12).
    func makeUploadRequest(fileURL: URL,
                           deviceAssetId: String,
                           deviceId: String,
                           fileCreatedAt: Date,
                           fileModifiedAt: Date,
                           filename: String,
                           checksumHex: String,
                           isFavorite: Bool = false) async throws -> (URLRequest, URL) {
        var request = try makeRequest(path: "/api/assets", method: "POST",
                                      timeout: Self.binaryTimeout)
        if let token = await tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(checksumHex, forHTTPHeaderField: "x-immich-checksum")

        let boundary = "OnlyDaves-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")

        let bodyURL = try MultipartBuilder.buildBody(
            boundary: boundary,
            fields: [
                "deviceAssetId": deviceAssetId,
                "deviceId": deviceId,
                "fileCreatedAt": Immich.iso8601String(from: fileCreatedAt),
                "fileModifiedAt": Immich.iso8601String(from: fileModifiedAt),
                "isFavorite": isFavorite ? "true" : "false",
                "filename": filename
            ],
            fileField: "assetData",
            fileURL: fileURL,
            filename: filename)

        return (request, bodyURL)
    }

    /// Uploads a rotated replacement for an existing asset and returns its new id.
    ///
    /// There is no replace-in-place endpoint in v3.1.0 (see `RemoteLibraryService.rotateRemote`),
    /// so this is an ordinary upload that deliberately carries the *original's* timestamps —
    /// the server honours them, keeping the photo in its original timeline position rather than
    /// resurfacing it as if it were taken now.
    func uploadReplacement(fileURL: URL,
                           filename: String,
                           deviceID: String,
                           fileCreatedAt: Date,
                           fileModifiedAt: Date) async throws -> String {
        let checksum = try Self.sha1Hex(ofFileAt: fileURL)

        var request = try makeRequest(path: "/api/assets", method: "POST",
                                      timeout: Self.binaryTimeout)
        if let token = await tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(checksum, forHTTPHeaderField: "x-immich-checksum")

        let boundary = "OnlyDaves-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")

        let bodyURL = try MultipartBuilder.buildBody(
            boundary: boundary,
            fields: [
                "deviceAssetId": "rotated-\(UUID().uuidString)",
                "deviceId": deviceID,
                "fileCreatedAt": Immich.iso8601String(from: fileCreatedAt),
                "fileModifiedAt": Immich.iso8601String(from: fileModifiedAt),
                "isFavorite": "false",
                "filename": filename
            ],
            fileField: "assetData",
            fileURL: fileURL,
            filename: filename)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let (data, response) = try await session.upload(for: request, fromFile: bodyURL)
        guard let http = response as? HTTPURLResponse else { throw ImmichError.unreachable }
        switch http.statusCode {
        case 200..<300:
            let decoded = try JSONDecoder().decode(Immich.UploadResponse.self, from: data)
            return decoded.id
        case 401, 403:
            throw ImmichError.unauthorized
        default:
            throw ImmichError.http(status: http.statusCode)
        }
    }

    /// Streaming SHA-1, so a large original never has to sit in memory.
    static func sha1Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Request plumbing

    private func makeRequest(path: String,
                             method: String,
                             query: [URLQueryItem] = [],
                             timeout: TimeInterval) throws -> URLRequest {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path),
            resolvingAgainstBaseURL: false) else {
            throw ImmichError.invalidURL
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ImmichError.invalidURL }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func makeRequest<Body: Encodable>(path: String,
                                              method: String,
                                              body: Body,
                                              timeout: TimeInterval) throws -> URLRequest {
        var request = try makeRequest(path: path, method: method, timeout: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func send<Response: Decodable>(path: String,
                                           method: String,
                                           authenticated: Bool = true) async throws -> Response {
        var request = try makeRequest(path: path, method: method, timeout: Self.metadataTimeout)
        if authenticated, let token = await tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try decode(try await dataForRequest(request))
    }

    private func send<Body: Encodable, Response: Decodable>(path: String,
                                                            method: String,
                                                            body: Body,
                                                            authenticated: Bool = true) async throws -> Response {
        var request = try makeRequest(path: path, method: method, body: body,
                                      timeout: Self.metadataTimeout)
        if authenticated, let token = await tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try decode(try await dataForRequest(request))
    }

    private func data(path: String, query: [URLQueryItem] = []) async throws -> Data {
        var request = try makeRequest(path: path, method: "GET", query: query,
                                      timeout: Self.binaryTimeout)
        if let token = await tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await dataForRequest(request)
    }

    private func dataForRequest(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return data }
            switch http.statusCode {
            case 200..<300:
                return data
            case 401, 403:
                throw ImmichError.unauthorized
            default:
                throw ImmichError.http(status: http.statusCode)
            }
        } catch let error as ImmichError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ImmichError.unreachable
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ImmichError.decoding(String(describing: error))
        }
    }
}

/// Streams a multipart body to a temp file so large uploads never sit in memory.
enum MultipartBuilder {
    static func buildBody(boundary: String,
                          fields: [String: String],
                          fileField: String,
                          fileURL: URL,
                          filename: String) throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)

        guard let handle = try? FileHandle(forWritingTo: outputURL) else {
            throw ImmichError.invalidURL
        }
        defer { try? handle.close() }

        func write(_ string: String) throws {
            try handle.write(contentsOf: Data(string.utf8))
        }

        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            try write("--\(boundary)\r\n")
            try write("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            try write("\(value)\r\n")
        }

        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\n")
        try write("Content-Type: application/octet-stream\r\n\r\n")

        // Copy in chunks: originals can be multi-gigabyte videos.
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try handle.write(contentsOf: chunk)
        }

        try write("\r\n--\(boundary)--\r\n")
        return outputURL
    }
}
