import XCTest
@testable import OnlyDaves

/// Immich model parsing, URL/version handling, and the HTTP contracts the client depends on
/// (DESIGN.md §7.1, §16).
final class ImmichTests: XCTestCase {

    // MARK: - Server URL normalisation

    func testNormalizeAddsSchemeToBareHost() {
        let url = ImmichAuthSession.normalizeServerURL("immich.local:2283")
        XCTAssertEqual(url?.absoluteString, "http://immich.local:2283")
    }

    func testNormalizeKeepsExplicitHTTPS() {
        let url = ImmichAuthSession.normalizeServerURL("https://photos.example.com")
        XCTAssertEqual(url?.absoluteString, "https://photos.example.com")
    }

    func testNormalizeStripsTrailingSlashAndAPISuffix() {
        // Every client path already carries /api, so a pasted ".../api" would double it up.
        XCTAssertEqual(ImmichAuthSession.normalizeServerURL("https://x.com/api/")?.absoluteString,
                       "https://x.com")
        XCTAssertEqual(ImmichAuthSession.normalizeServerURL("https://x.com///")?.absoluteString,
                       "https://x.com")
    }

    func testNormalizeRejectsUnusableInput() {
        XCTAssertNil(ImmichAuthSession.normalizeServerURL(""))
        XCTAssertNil(ImmichAuthSession.normalizeServerURL("   "))
        XCTAssertNil(ImmichAuthSession.normalizeServerURL("ftp://x.com"))
    }

    // MARK: - Transport security (D14)

    func testLocalPlainHTTPIsNotFlaggedInsecure() {
        for host in ["http://localhost:2283", "http://127.0.0.1:4567", "http://nas.local",
                     "http://192.168.1.10", "http://10.0.0.5", "http://172.16.4.4"] {
            let url = URL(string: host)!
            XCTAssertFalse(ImmichAuthSession.isInsecureNonLocal(url), "\(host) is local")
        }
    }

    func testRemotePlainHTTPIsFlaggedInsecure() {
        XCTAssertTrue(ImmichAuthSession.isInsecureNonLocal(URL(string: "http://example.com")!))
        // 172.32 is outside the private 172.16–172.31 range.
        XCTAssertTrue(ImmichAuthSession.isInsecureNonLocal(URL(string: "http://172.32.0.1")!))
    }

    func testHTTPSIsNeverFlagged() {
        XCTAssertFalse(ImmichAuthSession.isInsecureNonLocal(URL(string: "https://example.com")!))
    }

    // MARK: - Version gate (D8)

    func testVersionGateAcceptsSupportedServers() {
        // Immich reports "v3.1.0"; a naive Int() on the leading component returns nil for that,
        // which silently rejected every real server until it was fixed.
        XCTAssertNoThrow(try ImmichAuthSession.validate(version: "v3.1.0"))
        XCTAssertNoThrow(try ImmichAuthSession.validate(version: "3.1.0"))
        XCTAssertNoThrow(try ImmichAuthSession.validate(version: "v4.0.0-beta"))
        XCTAssertEqual(ImmichAuthSession.majorVersion(of: "v3.1.0"), 3)
    }

    func testVersionGateRejectsOldOrUnparseableServers() {
        XCTAssertThrowsError(try ImmichAuthSession.validate(version: "v2.9.1"))
        XCTAssertThrowsError(try ImmichAuthSession.validate(version: "unknown"))
    }

    // MARK: - Parsing

    func testDurationParsing() {
        XCTAssertEqual(Immich.parseDuration("0:00:37.000"), 37, accuracy: 0.001)
        XCTAssertEqual(Immich.parseDuration("0:01:23.500"), 83.5, accuracy: 0.001)
        XCTAssertEqual(Immich.parseDuration("1:00:00.000"), 3600, accuracy: 0.001)
        XCTAssertEqual(Immich.parseDuration(nil), 0)
        XCTAssertEqual(Immich.parseDuration(""), 0)
    }

    func testDateParsingHandlesBothISOShapes() {
        XCTAssertNotNil(Immich.parseDate("2026-08-18T10:30:00.000Z"))
        XCTAssertNotNil(Immich.parseDate("2026-08-18T10:30:00Z"))
        XCTAssertNotNil(Immich.parseDate("2026-08-18T10:30:00.000"))
        XCTAssertNil(Immich.parseDate(nil))
        XCTAssertNil(Immich.parseDate("not a date"))
    }

    func testAssetDecodingMapsMediaKind() throws {
        let json = """
        {"assets":{"items":[
          {"id":"a1","type":"IMAGE","checksum":"c1","localDateTime":"2026-08-18T10:00:00.000Z",
           "duration":"0:00:00.00000","isTrashed":false,
           "exifInfo":{"exifImageWidth":4000,"exifImageHeight":3000,"make":"Immich"}},
          {"id":"a2","type":"VIDEO","checksum":"c2","localDateTime":"2026-08-17T10:00:00.000Z",
           "duration":"0:00:37.000","isTrashed":false},
          {"id":"a3","type":"IMAGE","checksum":"c3","livePhotoVideoId":"v9",
           "localDateTime":"2026-08-16T10:00:00.000Z","duration":"0:00:00.00000"}
        ],"total":3,"count":3,"nextPage":null}}
        """
        let page = try JSONDecoder().decode(Immich.SearchPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.assets.items.count, 3)
        XCTAssertEqual(page.assets.items[0].mediaKind, .image)
        XCTAssertEqual(page.assets.items[1].mediaKind, .video)
        XCTAssertEqual(page.assets.items[1].durationSeconds, 37, accuracy: 0.001)
        // A still with a paired video is a Live Photo, not a plain image (D3).
        XCTAssertEqual(page.assets.items[2].mediaKind, .livePhoto)
        XCTAssertEqual(page.assets.items[0].pixelWidth, 4000)
        XCTAssertNil(page.assets.items[1].exifInfo)
    }

    func testRecordRoundTripsExifThroughJSONColumn() throws {
        let json = """
        {"assets":{"items":[{"id":"a1","type":"IMAGE","checksum":"c1",
          "localDateTime":"2026-08-18T10:00:00.000Z","duration":"0:00:00.00000",
          "exifInfo":{"make":"Immich","model":"Cam","latitude":48.85,"longitude":2.29}}],
          "total":1,"count":1,"nextPage":null}}
        """
        let page = try JSONDecoder().decode(Immich.SearchPage.self, from: Data(json.utf8))
        let record = RemoteAssetRecord(page.assets.items[0])
        XCTAssertEqual(record.exifInfo?.make, "Immich")
        XCTAssertEqual(record.exifInfo?.latitude ?? 0, 48.85, accuracy: 0.0001)
        XCTAssertEqual(record.stub.id, .remote("a1"))
        XCTAssertTrue(record.stub.hasRemote)
        XCTAssertFalse(record.stub.hasLocal)
    }

    // MARK: - Client contracts

    func testLoginPostsCredentialsToExpectedPath() async throws {
        let recorder = RequestRecorder()
        let client = ImmichClient(baseURL: URL(string: "https://s.example.com")!,
                                  session: StubURLProtocol.makeSession(recorder),
                                  tokenProvider: { nil })

        await recorder.stub(path: "/api/auth/login",
                            json: #"{"accessToken":"tok","userId":"u","userEmail":"a@b.c"}"#)
        let response = try await client.login(email: "a@b.c", password: "pw")

        XCTAssertEqual(response.accessToken, "tok")
        let request = await recorder.lastRequest
        XCTAssertEqual(request?.url?.path, "/api/auth/login")
        XCTAssertEqual(request?.httpMethod, "POST")
        // Login must not carry a bearer header — there is no token yet.
        XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))

        let capturedBody = await recorder.lastBody
        let body = try XCTUnwrap(capturedBody)
        let decoded = try JSONDecoder().decode(DecodedLogin.self, from: body)
        XCTAssertEqual(decoded.email, "a@b.c")
        XCTAssertEqual(decoded.password, "pw")
    }

    func testAuthenticatedCallsSendBearerToken() async throws {
        let recorder = RequestRecorder()
        let client = ImmichClient(baseURL: URL(string: "https://s.example.com")!,
                                  session: StubURLProtocol.makeSession(recorder),
                                  tokenProvider: { "secret-token" })

        await recorder.stub(path: "/api/search/metadata",
                            json: #"{"assets":{"items":[],"total":0,"count":0,"nextPage":null}}"#)
        _ = try await client.searchAssets(Immich.MetadataSearchRequest())

        let request = await recorder.lastRequest
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertEqual(request?.url?.path, "/api/search/metadata")
    }

    func testThumbnailRequestCarriesSizeQuery() async throws {
        let recorder = RequestRecorder()
        let client = ImmichClient(baseURL: URL(string: "https://s.example.com")!,
                                  session: StubURLProtocol.makeSession(recorder),
                                  tokenProvider: { "t" })

        await recorder.stub(path: "/api/assets/abc/thumbnail", json: "{}")
        _ = try? await client.thumbnailData(id: "abc", size: .preview)

        let request = await recorder.lastRequest
        XCTAssertEqual(request?.url?.path, "/api/assets/abc/thumbnail")
        XCTAssertEqual(request?.url?.query, "size=preview")
    }

    func testUnauthorizedResponseMapsToTypedError() async {
        let recorder = RequestRecorder()
        let client = ImmichClient(baseURL: URL(string: "https://s.example.com")!,
                                  session: StubURLProtocol.makeSession(recorder),
                                  tokenProvider: { "stale" })

        await recorder.stub(path: "/api/users/me", json: #"{"message":"unauthorized"}"#, status: 401)
        do {
            _ = try await client.me()
            XCTFail("expected unauthorized")
        } catch let error as ImmichError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testServerErrorMapsToHTTPStatus() async {
        let recorder = RequestRecorder()
        let client = ImmichClient(baseURL: URL(string: "https://s.example.com")!,
                                  session: StubURLProtocol.makeSession(recorder),
                                  tokenProvider: { "t" })

        await recorder.stub(path: "/api/users/me", json: "{}", status: 503)
        do {
            _ = try await client.me()
            XCTFail("expected failure")
        } catch let error as ImmichError {
            XCTAssertEqual(error, .http(status: 503))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testDeleteSendsIDsInBody() async throws {
        let recorder = RequestRecorder()
        let client = ImmichClient(baseURL: URL(string: "https://s.example.com")!,
                                  session: StubURLProtocol.makeSession(recorder),
                                  tokenProvider: { "t" })

        await recorder.stub(path: "/api/assets", json: "{}", status: 204)
        try await client.deleteAssets(ids: ["a", "b"])

        let request = await recorder.lastRequest
        XCTAssertEqual(request?.httpMethod, "DELETE")
        let capturedBody = await recorder.lastBody
        let body = try XCTUnwrap(capturedBody)
        let decoded = try JSONDecoder().decode(DecodedDelete.self, from: body)
        XCTAssertEqual(decoded.ids, ["a", "b"])
        XCTAssertFalse(decoded.force)
    }

    private struct DecodedDelete: Decodable { let ids: [String]; let force: Bool }
    /// The request type is Encodable-only, so decode into a mirror for assertions.
    private struct DecodedLogin: Decodable { let email: String; let password: String }

    // MARK: - Disk cache keys

    func testDiskCacheHashIsStableAcrossCalls() {
        // Swift's `hashValue` is seeded per process; using it here meant the disk cache never
        // survived a relaunch. This must stay deterministic.
        let key = RemoteThumbnailCache.key(immichID: "asset-1", variant: "thumb")
        XCTAssertEqual(DiskCache.stableHash(key), DiskCache.stableHash(key))
        XCTAssertEqual(DiskCache.stableHash("remote-asset-00/thumb"),
                       DiskCache.stableHash("remote-asset-00/thumb"))
        XCTAssertNotEqual(DiskCache.stableHash("a/thumb"), DiskCache.stableHash("a/preview"))
    }
}

// MARK: - URLProtocol stub

/// Records outgoing requests and serves canned responses, so endpoint shapes are pinned
/// without a live server.
actor RequestRecorder {
    private(set) var lastRequest: URLRequest?
    private(set) var lastBody: Data?
    private var stubs: [String: (Int, Data)] = [:]

    func stub(path: String, json: String, status: Int = 200) {
        stubs[path] = (status, Data(json.utf8))
    }

    func record(_ request: URLRequest, body: Data?) {
        lastRequest = request
        lastBody = body
    }

    func response(for path: String) -> (Int, Data) {
        stubs[path] ?? (404, Data("{}".utf8))
    }
}

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var recorder: RequestRecorder?

    static func makeSession(_ recorder: RequestRecorder) -> URLSession {
        StubURLProtocol.recorder = recorder
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // `httpBody` is stripped by URLSession before it reaches the protocol, so read the
        // stream when the body is not directly available.
        let body = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            stream.open()
            defer { stream.close() }
            var data = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }

        let path = request.url?.path ?? ""
        let recorder = StubURLProtocol.recorder

        Task {
            await recorder?.record(self.request, body: body)
            let (status, data) = await recorder?.response(for: path) ?? (404, Data())
            let response = HTTPURLResponse(url: self.request.url!,
                                           statusCode: status,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
