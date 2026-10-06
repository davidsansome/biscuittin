import Foundation
import CryptoKit

/// Typed HTTP client for the Immich API (DESIGN.md §7.1).
///
/// Deliberately storage-free: it holds no cache, no database and no credentials of its own —
/// the credential arrives through `credentialProvider`. That keeps it trivially testable with a stubbed
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
    private let credentialProvider: @Sendable () async -> ImmichCredential?

    private static let metadataTimeout: TimeInterval = 10
    private static let binaryTimeout: TimeInterval = 60

    init(baseURL: URL,
         session: URLSession = .shared,
         credentialProvider: @escaping @Sendable () async -> ImmichCredential?) {
        self.baseURL = baseURL
        self.session = session
        self.credentialProvider = credentialProvider
    }

    init(baseURL: URL,
         session: URLSession = .shared,
         tokenProvider: @escaping @Sendable () async -> String?) {
        self.init(baseURL: baseURL, session: session,
                  credentialProvider: { await tokenProvider().map(ImmichCredential.accessToken) })
    }

    // MARK: - Auth and server

    func login(email: String, password: String) async throws -> Immich.LoginResponse {
        try await send(path: "/api/auth/login",
                       method: "POST",
                       body: Immich.LoginRequest(email: email, password: password),
                       authenticated: false)
    }

    // Unauthenticated, so a server can be identified and checked before any credentials exist.
    // `server/about` is not among them — see below.

    func ping() async throws -> Immich.ServerPing {
        try await send(path: "/api/server/ping", method: "GET", authenticated: false)
    }

    func serverVersion() async throws -> Immich.ServerVersion {
        try await send(path: "/api/server/version", method: "GET", authenticated: false)
    }

    func serverFeatures() async throws -> Immich.ServerFeatures {
        try await send(path: "/api/server/features", method: "GET", authenticated: false)
    }

    func serverConfig() async throws -> Immich.ServerConfig {
        try await send(path: "/api/server/config", method: "GET", authenticated: false)
    }

    /// Starts an OAuth login. The server builds the identity provider's authorization URL
    /// around the state and PKCE challenge supplied here, so the matching verifier never
    /// leaves this device until the callback.
    func oauthAuthorize(redirectURI: String, state: String,
                        codeChallenge: String) async throws -> Immich.OAuthAuthorizeResponse {
        try await send(path: "/api/oauth/authorize",
                       method: "POST",
                       body: Immich.OAuthAuthorizeRequest(redirectUri: redirectURI, state: state,
                                                          codeChallenge: codeChallenge),
                       authenticated: false)
    }

    func oauthCallback(url: URL, state: String,
                       codeVerifier: String) async throws -> Immich.LoginResponse {
        try await send(path: "/api/oauth/callback",
                       method: "POST",
                       body: Immich.OAuthCallbackRequest(url: url.absoluteString, state: state,
                                                         codeVerifier: codeVerifier),
                       authenticated: false)
    }

    /// Authenticated: a stock Immich deployment returns 401 for this without a token, so it can
    /// only be called once sign-in has produced one.
    func serverAbout() async throws -> Immich.ServerAbout {
        try await send(path: "/api/server/about", method: "GET")
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

    // MARK: - Sync (D9)

    /// The NDJSON lines of a `sync/stream` batch as they download — one line per change since the
    /// cursor Immich tracks server-side for this access token, or the whole history when `reset`
    /// is true. Lines are left undecoded: `RemoteLibraryService` routes each by its own `type`.
    ///
    /// Streamed rather than returned whole because a full replay of a large library (or a
    /// partner's) runs to hundreds of thousands of lines and minutes of transfer, and nothing
    /// could be shown until the last byte arrived. HTTP and transport failures surface as the
    /// same `ImmichError`s as every other call, thrown from the iteration.
    func syncStream(types: [Immich.SyncRequestType],
                    reset: Bool) async throws -> AsyncThrowingStream<[Data], Error> {
        var request = try makeRequest(path: "/api/sync/stream", method: "POST",
                                      body: Immich.SyncStreamRequest(types: types, reset: reset),
                                      timeout: Self.binaryTimeout)
        await applyCredential(to: &request)
        return LineStreamDelegate.lines(for: request, session: session)
    }

    /// Advances the server-side cursor so acknowledged lines are not sent again. At most one ack
    /// per type is ever needed — ack ids are a per-type watermark, not a per-line receipt
    /// (verified against a real server: acking only the last id of a batch advanced the cursor
    /// past every line before it).
    func syncAck(_ acks: [String]) async throws {
        guard !acks.isEmpty else { return }
        var request = try makeRequest(path: "/api/sync/ack", method: "POST",
                                      body: Immich.SyncAckRequest(acks: acks),
                                      timeout: Self.metadataTimeout)
        await applyCredential(to: &request)
        _ = try await dataForRequest(request)
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
        await applyCredential(to: &request)
        return request
    }

    /// Headers `AVURLAsset` needs to authenticate its own range requests.
    func playbackHeaders() async -> [String: String] {
        guard let credential = await credentialProvider() else { return [:] }
        return [credential.headerField: credential.headerValue]
    }

    func playbackURL(id: String) -> URL {
        baseURL.appendingPathComponent("api/assets/\(id)/video/playback")
    }

    // MARK: - Mutations

    func deleteAssets(ids: [String], force: Bool = false) async throws {
        guard !ids.isEmpty else { return }
        var request = try makeRequest(path: "/api/assets",
                                      method: "DELETE",
                                      body: Immich.DeleteRequest(ids: ids, force: force),
                                      timeout: Self.metadataTimeout)
        await applyCredential(to: &request)
        _ = try await dataForRequest(request)
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
        await applyCredential(to: &request)
        request.setValue(checksumHex, forHTTPHeaderField: "x-immich-checksum")

        let boundary = "BiscuitTin-\(UUID().uuidString)"
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
        await applyCredential(to: &request)
        request.setValue(checksum, forHTTPHeaderField: "x-immich-checksum")

        let boundary = "BiscuitTin-\(UUID().uuidString)"
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

    /// Forces an asset's capture date.
    ///
    /// Needed after a rotation replacement: the multipart `fileCreatedAt` is only honoured when
    /// the file carries no date of its own. A rotated JPEG keeps its EXIF and so survives, but a
    /// remuxed video does not, and Immich re-derives the date — landing the replacement at
    /// "now" and jumping it to the top of the timeline. Setting it explicitly covers every kind.
    func updateCaptureDate(id: String, to date: Date) async throws {
        struct Update: Encodable { let dateTimeOriginal: String }
        var request = try makeRequest(path: "/api/assets/\(id)",
                                      method: "PUT",
                                      body: Update(dateTimeOriginal: Immich.iso8601String(from: date)),
                                      timeout: Self.metadataTimeout)
        await applyCredential(to: &request)
        _ = try await dataForRequest(request)
    }

    private func applyCredential(to request: inout URLRequest) async {
        guard let credential = await credentialProvider() else { return }
        request.setValue(credential.headerValue, forHTTPHeaderField: credential.headerField)
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
        if authenticated { await applyCredential(to: &request) }
        return try decode(try await dataForRequest(request))
    }

    private func send<Body: Encodable, Response: Decodable>(path: String,
                                                            method: String,
                                                            body: Body,
                                                            authenticated: Bool = true) async throws -> Response {
        var request = try makeRequest(path: path, method: method, body: body,
                                      timeout: Self.metadataTimeout)
        if authenticated { await applyCredential(to: &request) }
        return try decode(try await dataForRequest(request))
    }

    private func data(path: String, query: [URLQueryItem] = []) async throws -> Data {
        var request = try makeRequest(path: path, method: "GET", query: query,
                                      timeout: Self.binaryTimeout)
        await applyCredential(to: &request)
        return try await dataForRequest(request)
    }

    private func dataForRequest(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return data }
            if let error = Self.error(forStatus: http.statusCode, body: data) { throw error }
            return data
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    /// nil for a success status.
    fileprivate static func error(forStatus status: Int, body: Data) -> ImmichError? {
        switch status {
        case 200..<300:
            return nil
        case 401, 403:
            return .unauthorized
        case 400:
            // Immich explains a 400 in `message` ("OAuth is not enabled"), which is the only
            // actionable part of the response.
            if let message = try? JSONDecoder().decode(Immich.ErrorBody.self, from: body).message {
                return .rejected(message)
            }
            return .http(status: 400)
        default:
            return .http(status: status)
        }
    }

    fileprivate static func mapTransportError(_ error: Error) -> Error {
        switch error {
        case let error as ImmichError: error
        case let error as URLError where error.code == .cancelled: CancellationError()
        case is CancellationError: error
        default: ImmichError.unreachable
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

/// Cuts a byte stream into newline-separated lines, holding a line split across two network
/// chunks until its end arrives. Empty lines are dropped.
struct NDJSONLineSplitter {
    private var partial = Data()

    mutating func append(_ data: Data) -> [Data] {
        partial.append(data)
        guard let lastNewline = partial.lastIndex(of: Self.newline) else { return [] }
        let lines = partial[..<lastNewline].split(separator: Self.newline).map { Data($0) }
        partial = Data(partial[partial.index(after: lastNewline)...])
        return lines
    }

    /// Whatever followed the last newline: the server need not end its final line with one.
    mutating func finish() -> [Data] {
        defer { partial = Data() }
        return partial.isEmpty ? [] : [partial]
    }

    private static let newline = UInt8(ascii: "\n")
}

/// Feeds a data task's body to an `AsyncThrowingStream` as complete lines.
///
/// A per-task delegate rather than `URLSession.bytes(for:)`: that yields one byte per
/// iteration, which is far too slow for a body that can run past a hundred megabytes.
private final class LineStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // URLSession calls one task's delegate methods serially, so this state needs no lock.
    private let continuation: AsyncThrowingStream<[Data], Error>.Continuation
    private var splitter = NDJSONLineSplitter()
    private var status: Int?
    /// The body of a failure response, kept whole for `ImmichClient.error(forStatus:body:)`.
    private var errorBody = Data()

    private init(continuation: AsyncThrowingStream<[Data], Error>.Continuation) {
        self.continuation = continuation
    }

    static func lines(for request: URLRequest, session: URLSession) -> AsyncThrowingStream<[Data], Error> {
        AsyncThrowingStream { continuation in
            let task = session.dataTask(with: request)
            task.delegate = LineStreamDelegate(continuation: continuation)
            continuation.onTermination = { _ in task.cancel() }
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard isSuccess else {
            errorBody.append(data)
            return
        }
        let lines = splitter.append(data)
        if !lines.isEmpty { continuation.yield(lines) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation.finish(throwing: ImmichClient.mapTransportError(error))
        } else if let status, let failure = ImmichClient.error(forStatus: status, body: errorBody) {
            continuation.finish(throwing: failure)
        } else {
            let rest = splitter.finish()
            if !rest.isEmpty { continuation.yield(rest) }
            continuation.finish()
        }
    }

    private var isSuccess: Bool { status.map { (200..<300).contains($0) } ?? true }
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
