import XCTest
@testable import BiscuitTin

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

    // MARK: - Checksum encoding
    //
    // Verified against a real Immich v3.1.0 server: the asset DTO reports SHA-1 **base64**
    // encoded, while every locally-computed checksum in this app is hex and `facet_links` is
    // keyed on it. Storing the raw base64 meant a local and remote copy of the same photo could
    // never match, so it appeared twice in the grid instead of once with two facets (D5).

    func testServerBase64ChecksumNormalisesToHex() {
        // Exact pair observed from the live server for a known file.
        let base64 = "41ipRRJcK31MhPDdCW6B8j/1JJo="
        let hex = "e358a945125c2b7d4c84f0dd096e81f23ff5249a"
        XCTAssertEqual(Immich.normalizedChecksumHex(base64), hex)
    }

    func testHexChecksumPassesThroughUnchanged() {
        let hex = "e358a945125c2b7d4c84f0dd096e81f23ff5249a"
        XCTAssertEqual(Immich.normalizedChecksumHex(hex), hex)
        XCTAssertEqual(Immich.normalizedChecksumHex(hex.uppercased()), hex,
                       "case must be normalised so links still match")
    }

    func testChecksumNormalisationHandlesEmptyAndJunk() {
        XCTAssertEqual(Immich.normalizedChecksumHex(nil), "")
        XCTAssertEqual(Immich.normalizedChecksumHex(""), "")
        // Unrecognised input stays stable rather than collapsing to empty, so two rows carrying
        // the same odd value still link to each other.
        let junk = "not-a-checksum"
        XCTAssertEqual(Immich.normalizedChecksumHex(junk), Immich.normalizedChecksumHex(junk))
    }

    /// The whole point of the fix: a remote asset and its local twin must produce the same key.
    func testRemoteAndLocalChecksumsLinkAfterNormalisation() throws {
        let json = """
        {"assets":{"items":[{"id":"a1","type":"IMAGE","checksum":"41ipRRJcK31MhPDdCW6B8j/1JJo=",
          "localDateTime":"2026-08-18T10:00:00.000Z","duration":"0:00:00.00000",
          "width":240,"height":160}],"total":1,"count":1,"nextPage":null}}
        """
        let page = try JSONDecoder().decode(Immich.SearchPage.self, from: Data(json.utf8))
        let record = RemoteAssetRecord(page.assets.items[0])

        // What LocalAssetExporter would compute for the same bytes.
        let localChecksum = "e358a945125c2b7d4c84f0dd096e81f23ff5249a"
        XCTAssertEqual(record.checksumHex, localChecksum,
                       "remote and local checksums must collide, or the asset shows up twice")
    }

    /// v3.1.0 reports dimensions at the top level and may omit them from exifInfo.
    func testTopLevelDimensionsArePreferred() throws {
        let json = """
        {"assets":{"items":[{"id":"a1","type":"IMAGE","checksum":"c1","width":240,"height":160,
          "localDateTime":"2026-08-18T10:00:00.000Z","duration":"0:00:00.00000"}],
          "total":1,"count":1,"nextPage":null}}
        """
        let page = try JSONDecoder().decode(Immich.SearchPage.self, from: Data(json.utf8))
        let asset = page.assets.items[0]
        XCTAssertEqual(asset.pixelWidth, 240)
        XCTAssertEqual(asset.pixelHeight, 160)
        XCTAssertNil(asset.exifInfo, "dimensions must survive without exifInfo")
    }

    /// Confirmed absent from v3.1.0 responses, so nothing may depend on them.
    func testDeviceIdentifiersAreOptional() throws {
        let json = """
        {"assets":{"items":[{"id":"a1","type":"IMAGE","checksum":"c1",
          "localDateTime":"2026-08-18T10:00:00.000Z","duration":"0:00:00.00000"}],
          "total":1,"count":1,"nextPage":null}}
        """
        let page = try JSONDecoder().decode(Immich.SearchPage.self, from: Data(json.utf8))
        XCTAssertNil(page.assets.items[0].deviceAssetId)
        XCTAssertNil(page.assets.items[0].deviceId)
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

    // MARK: - Sync stream (D9)
    //
    // Verified against a real v3.1.0 server: `sync/stream` reports upserts and explicit delete
    // events against a cursor Immich tracks server-side, replacing the old paged full/delta sync
    // and its weekly hard-delete sweep. Two easy-to-conflate namings, both pinned below: the
    // *request* type is plural ("AssetsV2"), the *response* line's `type` is singular ("AssetV2").

    func testSyncLineHeaderRoutesByType() throws {
        let assetLine = """
        {"type":"AssetV2","data":{"id":"a1"},"ack":"AssetV2|01a"}
        """
        let header = try JSONDecoder().decode(Immich.SyncLineHeader.self, from: Data(assetLine.utf8))
        XCTAssertEqual(header.type, "AssetV2")
        XCTAssertEqual(header.ack, "AssetV2|01a")
    }

    func testSyncAssetV2DecodesRealServerShape() throws {
        // One line as returned by a live server, duration in milliseconds and a base64 checksum.
        let json = """
        {"id":"a1","ownerId":"o1","originalFileName":"IMG_1.HEIC","thumbhash":"abc",
         "checksum":"41ipRRJcK31MhPDdCW6B8j/1JJo=","fileCreatedAt":"2026-08-25T08:16:42.153Z",
         "fileModifiedAt":"2026-08-25T08:17:18.000Z","createdAt":"2026-08-25T09:45:32.101Z",
         "localDateTime":"2026-08-25T18:16:42.153Z","duration":4000,"type":"VIDEO",
         "deletedAt":null,"isFavorite":false,"visibility":"timeline","livePhotoVideoId":null,
         "stackId":null,"libraryId":null,"width":3024,"height":4032,"isEdited":false}
        """
        let asset = try JSONDecoder().decode(Immich.SyncAssetV2.self, from: Data(json.utf8))
        XCTAssertEqual(asset.id, "a1")
        XCTAssertEqual(asset.durationSeconds, 4, accuracy: 0.001, "duration is milliseconds, not seconds")
        XCTAssertEqual(asset.checksumHex, "e358a945125c2b7d4c84f0dd096e81f23ff5249a")
        XCTAssertEqual(asset.visibility, .timeline)
        XCTAssertNil(asset.deletedAt)
    }

    func testSyncAssetV2DecodesDeletedAtAndNonTimelineVisibility() throws {
        let json = """
        {"id":"a1","originalFileName":"x.jpg","checksum":"c1","fileCreatedAt":null,
         "fileModifiedAt":null,"localDateTime":null,"duration":null,"type":"IMAGE",
         "deletedAt":"2026-09-22T22:15:53.441Z","visibility":"archive","livePhotoVideoId":null,
         "width":null,"height":null}
        """
        let asset = try JSONDecoder().decode(Immich.SyncAssetV2.self, from: Data(json.utf8))
        XCTAssertNotNil(asset.deletedAt)
        XCTAssertEqual(asset.visibility, .archive)
        XCTAssertEqual(asset.durationSeconds, 0)
    }

    func testSyncAssetExifV1Decodes() throws {
        let json = """
        {"assetId":"a1","description":null,"exifImageWidth":4000,"exifImageHeight":3000,
         "fileSizeInByte":1234,"orientation":"1","dateTimeOriginal":"2026-08-25T08:16:42.000Z",
         "modifyDate":null,"timeZone":null,"latitude":48.85,"longitude":2.29,
         "projectionType":null,"city":"Paris","state":null,"country":"France","make":"Immich",
         "model":"Cam","lensModel":null,"fNumber":1.8,"focalLength":24,"iso":100,
         "exposureTime":"1/125","profileDescription":null,"rating":null,"fps":null}
        """
        let exif = try JSONDecoder().decode(Immich.SyncAssetExifV1.self, from: Data(json.utf8))
        XCTAssertEqual(exif.assetId, "a1")
        XCTAssertEqual(exif.latitude ?? 0, 48.85, accuracy: 0.0001)
        XCTAssertEqual(exif.city, "Paris")
        XCTAssertEqual(exif.iso, 100)
    }

    func testSyncAssetDeleteV1Decodes() throws {
        let json = #"{"assetId":"deleted-1"}"#
        let delete = try JSONDecoder().decode(Immich.SyncAssetDeleteV1.self, from: Data(json.utf8))
        XCTAssertEqual(delete.assetId, "deleted-1")
    }

    /// The request names are plural ("AssetsV2"/"AssetExifsV1") though the lines that come back
    /// are singular ("AssetV2"/"AssetExifV1") — conflating them means requesting a type the
    /// server rejects.
    func testSyncRequestTypeRawValuesArePlural() {
        XCTAssertEqual(Immich.SyncRequestType.assets.rawValue, "AssetsV2")
        XCTAssertEqual(Immich.SyncRequestType.assetExifs.rawValue, "AssetExifsV1")
    }

    func testSyncStreamPostsTypesAndResetFlag() async throws {
        let recorder = RequestRecorder()
        let client = ImmichClient(baseURL: URL(string: "https://s.example.com")!,
                                  session: StubURLProtocol.makeSession(recorder),
                                  tokenProvider: { "tok" })

        await recorder.stub(path: "/api/sync/stream", json: "")
        _ = try await client.syncStream(types: [.assets, .assetExifs], reset: true)

        let request = await recorder.lastRequest
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.url?.path, "/api/sync/stream")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")

        let capturedBody = await recorder.lastBody
        let body = try XCTUnwrap(capturedBody)
        let decoded = try JSONDecoder().decode(DecodedSyncStreamRequest.self, from: body)
        XCTAssertEqual(decoded.types, ["AssetsV2", "AssetExifsV1"])
        XCTAssertTrue(decoded.reset)
    }

    func testSyncAckPostsAckIDs() async throws {
        let recorder = RequestRecorder()
        let client = ImmichClient(baseURL: URL(string: "https://s.example.com")!,
                                  session: StubURLProtocol.makeSession(recorder),
                                  tokenProvider: { "tok" })

        await recorder.stub(path: "/api/sync/ack", json: "", status: 204)
        try await client.syncAck(["AssetV2|01a", "AssetExifV1|01b"])

        let request = await recorder.lastRequest
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.url?.path, "/api/sync/ack")
        let capturedBody = await recorder.lastBody
        let body = try XCTUnwrap(capturedBody)
        let decoded = try JSONDecoder().decode(DecodedSyncAck.self, from: body)
        XCTAssertEqual(decoded.acks, ["AssetV2|01a", "AssetExifV1|01b"])
    }

    func testSyncAckSkipsRequestWhenEmpty() async throws {
        let recorder = RequestRecorder()
        let client = ImmichClient(baseURL: URL(string: "https://s.example.com")!,
                                  session: StubURLProtocol.makeSession(recorder),
                                  tokenProvider: { "tok" })
        try await client.syncAck([])
        let request = await recorder.lastRequest
        XCTAssertNil(request, "an empty ack batch must not make a request")
    }

    private struct DecodedSyncStreamRequest: Decodable { let types: [String]; let reset: Bool }
    private struct DecodedSyncAck: Decodable { let acks: [String] }

    // MARK: - RemoteAssetRecord merge (D9)
    //
    // An `AssetV2` line and its `AssetExifV1` line are independent and may arrive in either
    // order, or not both in the same batch — `apply` must overlay, never clobber.

    func testApplyAssetPreservesExistingEXIF() throws {
        var record = RemoteAssetRecord(placeholderID: "a1")
        record.apply(try decodeSyncAsset(id: "a1", width: 100, height: 200))
        record.apply(try decodeSyncExif(assetID: "a1", latitude: 48.85, longitude: 2.29))
        XCTAssertEqual(record.latitude ?? 0, 48.85, accuracy: 0.0001)

        // A later batch's asset-only line (no EXIF this time) must not erase what is cached.
        record.apply(try decodeSyncAsset(id: "a1", width: 100, height: 200))
        XCTAssertEqual(record.latitude ?? 0, 48.85, accuracy: 0.0001,
                       "an asset-only update must not clobber previously-known EXIF")
    }

    func testApplyExifFillsDimensionsOnlyWhenAssetOmitsThem() throws {
        var withDims = RemoteAssetRecord(placeholderID: "a1")
        withDims.apply(try decodeSyncAsset(id: "a1", width: 100, height: 200))
        withDims.apply(try decodeSyncExif(assetID: "a1", exifWidth: 9999, exifHeight: 9999))
        XCTAssertEqual(withDims.width, 100, "top-level asset dimensions take priority over EXIF")

        var withoutDims = RemoteAssetRecord(placeholderID: "a2")
        withoutDims.apply(try decodeSyncAsset(id: "a2", width: nil, height: nil))
        withoutDims.apply(try decodeSyncExif(assetID: "a2", exifWidth: 640, exifHeight: 480))
        XCTAssertEqual(withoutDims.width, 640, "EXIF fills in dimensions the asset line omitted")
    }

    func testApplyAssetMarksTrashedFromDeletedAt() throws {
        var record = RemoteAssetRecord(placeholderID: "a1")
        record.apply(try decodeSyncAsset(id: "a1", deletedAt: "2026-09-22T22:15:53.441Z"))
        XCTAssertTrue(record.isTrashed)
    }

    /// `jsonLiteral(_:)` renders a value as JSON source text ("null" for nil, quoted for a
    /// string) — kept as a plain function rather than inline in the interpolations below, which
    /// otherwise crashes the type checker ("failed to produce diagnostic for expression").
    private func jsonLiteral(_ value: Int?) -> String { value.map { "\($0)" } ?? "null" }
    private func jsonLiteral(_ value: Double?) -> String { value.map { "\($0)" } ?? "null" }
    private func jsonLiteral(_ value: String?) -> String { value.map { "\"\($0)\"" } ?? "null" }

    private func decodeSyncAsset(id: String, width: Int? = 100, height: Int? = 100,
                                 deletedAt: String? = nil) throws -> Immich.SyncAssetV2 {
        let widthLiteral = jsonLiteral(width)
        let heightLiteral = jsonLiteral(height)
        let deletedAtLiteral = jsonLiteral(deletedAt)
        let json = """
        {"id":"\(id)","originalFileName":"x.jpg","checksum":"c1",
         "fileCreatedAt":"2026-08-18T10:00:00.000Z","fileModifiedAt":null,
         "localDateTime":"2026-08-18T10:00:00.000Z","duration":null,"type":"IMAGE",
         "deletedAt":\(deletedAtLiteral),"visibility":"timeline",
         "livePhotoVideoId":null,"width":\(widthLiteral),"height":\(heightLiteral)}
        """
        return try JSONDecoder().decode(Immich.SyncAssetV2.self, from: Data(json.utf8))
    }

    private func decodeSyncExif(assetID: String, exifWidth: Int? = nil, exifHeight: Int? = nil,
                                latitude: Double? = nil, longitude: Double? = nil) throws -> Immich.SyncAssetExifV1 {
        let widthLiteral = jsonLiteral(exifWidth)
        let heightLiteral = jsonLiteral(exifHeight)
        let latitudeLiteral = jsonLiteral(latitude)
        let longitudeLiteral = jsonLiteral(longitude)
        let json = """
        {"assetId":"\(assetID)","description":null,
         "exifImageWidth":\(widthLiteral),"exifImageHeight":\(heightLiteral),
         "fileSizeInByte":null,"dateTimeOriginal":null,
         "latitude":\(latitudeLiteral),"longitude":\(longitudeLiteral),
         "city":null,"state":null,"country":null,"make":null,"model":null,"lensModel":null,
         "fNumber":null,"focalLength":null,"iso":null,"exposureTime":null}
        """
        return try JSONDecoder().decode(Immich.SyncAssetExifV1.self, from: Data(json.utf8))
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

    /// `/api/server/about` requires authentication on a stock Immich deployment (verified: 401
    /// without a token, 200 with one). Calling it unauthenticated made the version gate fail
    /// before the password was ever sent, and reported it as an expired session.
    func testServerAboutSendsBearerToken() async throws {
        let recorder = RequestRecorder()
        let client = ImmichClient(baseURL: URL(string: "https://s.example.com")!,
                                  session: StubURLProtocol.makeSession(recorder),
                                  tokenProvider: { "tok" })

        await recorder.stub(path: "/api/server/about", json: #"{"version":"v3.1.0"}"#)
        _ = try await client.serverAbout()

        let request = await recorder.lastRequest
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer tok",
                       "the version gate must authenticate, or it 401s before login")
    }

    func testInvalidCredentialsIsDistinctFromExpiredSession() {
        // Same HTTP status, very different meaning to someone signing in for the first time.
        XCTAssertNotEqual(ImmichError.invalidCredentials, ImmichError.unauthorized)
        XCTAssertEqual(ImmichError.invalidCredentials.errorDescription,
                       "Incorrect email or password.")
        XCTAssertEqual(ImmichError.unauthorized.errorDescription,
                       "Session expired. Sign in again.")
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
        // A stock server answers an unauthenticated DELETE with 401, which the caller reads
        // as an expired session.
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        let capturedBody = await recorder.lastBody
        let body = try XCTUnwrap(capturedBody)
        let decoded = try JSONDecoder().decode(DecodedDelete.self, from: body)
        XCTAssertEqual(decoded.ids, ["a", "b"])
        XCTAssertFalse(decoded.force)
    }

    private struct DecodedDelete: Decodable { let ids: [String]; let force: Bool }
    /// The request type is Encodable-only, so decode into a mirror for assertions.
    private struct DecodedLogin: Decodable { let email: String; let password: String }

    // MARK: - Trashed duplicates
    //
    // Verified against a real server: bulk-upload-check reports an asset sitting in Immich's
    // trash as `action: reject, reason: duplicate, isTrashed: true`. Treating that as backed up
    // marked 72 local photos safe while their only server copy was awaiting permanent deletion.

    func testBulkUploadCheckReportsTrashedDuplicates() throws {
        let json = """
        {"results":[
          {"id":"live","action":"reject","reason":"duplicate","assetId":"a1","isTrashed":false},
          {"id":"binned","action":"reject","reason":"duplicate","assetId":"a2","isTrashed":true},
          {"id":"fresh","action":"accept"}
        ]}
        """
        let decoded = try JSONDecoder().decode(Immich.BulkUploadCheckResponse.self,
                                               from: Data(json.utf8))
        XCTAssertEqual(decoded.results.count, 3)
        XCTAssertEqual(decoded.results[0].isTrashed, false)
        XCTAssertEqual(decoded.results[1].isTrashed, true,
                       "a trashed duplicate must be distinguishable from a live one")
        // `accept` results omit the field entirely, so it has to stay optional.
        XCTAssertNil(decoded.results[2].isTrashed)
        XCTAssertNil(decoded.results[2].reason)
    }

    /// The rule SyncEngine applies: only a *live* duplicate counts as backed up.
    func testOnlyLiveDuplicatesCountAsBackedUp() throws {
        let json = """
        {"results":[
          {"id":"live","action":"reject","reason":"duplicate","assetId":"a1","isTrashed":false},
          {"id":"binned","action":"reject","reason":"duplicate","assetId":"a2","isTrashed":true}
        ]}
        """
        let decoded = try JSONDecoder().decode(Immich.BulkUploadCheckResponse.self,
                                               from: Data(json.utf8))
        let backedUp = decoded.results.filter {
            $0.action == "reject" && $0.reason == "duplicate" && $0.isTrashed != true
        }
        XCTAssertEqual(backedUp.map(\.id), ["live"])
    }

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
    /// Every request body in order, keyed by path.
    private(set) var bodies: [(path: String, body: Data?)] = []
    private var stubs: [String: (Int, Data)] = [:]
    private var queued: [String: [(Int, Data)]] = [:]

    func stub(path: String, json: String, status: Int = 200) {
        stubs[path] = (status, Data(json.utf8))
    }

    /// Served once each, in order, before falling back to `stub(path:)`.
    func enqueue(path: String, json: String, status: Int = 200) {
        queued[path, default: []].append((status, Data(json.utf8)))
    }

    func record(_ request: URLRequest, body: Data?) {
        lastRequest = request
        lastBody = body
        bodies.append((request.url?.path ?? "", body))
    }

    func response(for path: String) -> (Int, Data) {
        if var pending = queued[path], !pending.isEmpty {
            let next = pending.removeFirst()
            queued[path] = pending
            return next
        }
        return stubs[path] ?? (404, Data("{}".utf8))
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
