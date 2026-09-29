import XCTest
import GRDB
@testable import BiscuitTin

/// Rotating a photo this device has only just uploaded: `SyncEngine` links it in `facet_links`
/// immediately, but its `remote_assets` row waits for the next sync stream, so the server leg
/// of a rotation has to describe the asset some other way.
final class RemoteRecordFallbackTests: XCTestCase {

    private var databaseURL: URL!
    private var database: AppDatabase!

    override func setUpWithError() throws {
        databaseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remote-record-\(UUID().uuidString).sqlite")
        database = AppDatabase(fileURL: databaseURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: databaseURL)
        try super.tearDownWithError()
    }

    private func makeService() -> RemoteLibraryService {
        RemoteLibraryService(database: database,
                             session: ImmichAuthSession(defaults: UserDefaults(suiteName: "remote-record-tests-\(UUID())")!),
                             resolver: PHAssetResolver(),
                             exporter: LocalAssetExporter())
    }

    private func makeClient(_ recorder: RequestRecorder) -> ImmichClient {
        ImmichClient(baseURL: URL(string: "https://s.example.com")!,
                     session: StubURLProtocol.makeSession(recorder),
                     tokenProvider: { "tok" })
    }

    /// What `SyncEngine.upload` writes on success, and nothing more.
    private func linkJustUploaded(localIdentifier: String, immichID: String) throws {
        try database.writer().write { db in
            try db.execute(sql: """
                INSERT INTO facet_links (checksum_hex, local_identifier, immich_id) VALUES (?, ?, ?)
                """, arguments: ["abc123", localIdentifier, immichID])
        }
    }

    func testJustUploadedAssetIsLinkedButHasNoCachedRow() async throws {
        let service = makeService()
        try linkJustUploaded(localIdentifier: "L1", immichID: "R1")

        let linked = try await service.immichID(forLocalIdentifier: "L1")
        XCTAssertEqual(linked, "R1", "the timeline treats this photo as on the server")
        let cached = try await service.record(for: "R1")
        XCTAssertNil(cached, "but the row a rotation reads has not been synced yet")
    }

    func testMissingRowIsFetchedFromServer() async throws {
        let service = makeService()
        try linkJustUploaded(localIdentifier: "L1", immichID: "R1")

        let recorder = RequestRecorder()
        await recorder.stub(path: "/api/assets/R1", json: """
            {"id":"R1","type":"IMAGE","checksum":"q83vEjQ=","originalFileName":"IMG_0001.HEIC",
             "localDateTime":"2026-08-18T10:00:00.000Z","fileCreatedAt":"2026-08-18T00:00:00.000Z",
             "width":4032,"height":3024,"duration":"0:00:00.00000"}
            """)

        let record = try await service.remoteRecord(for: "R1", client: makeClient(recorder))

        let request = await recorder.lastRequest
        XCTAssertEqual(request?.httpMethod, "GET")
        XCTAssertEqual(record.immichID, "R1")
        XCTAssertEqual(record.fileName, "IMG_0001.HEIC")
        XCTAssertEqual(record.width, 4032)
        XCTAssertEqual(record.height, 3024)
        // The replacement upload takes its capture date from here; it must match what the sync
        // stream would have stored, or the rotated copy moves in the timeline.
        XCTAssertEqual(record.captureAt,
                       try XCTUnwrap(Immich.parseDate("2026-08-18T10:00:00.000Z")).timeIntervalSince1970)
    }

    func testCachedRowIsUsedWithoutARequest() async throws {
        let service = makeService()
        var cached = RemoteAssetRecord(placeholderID: "R1")
        cached.fileName = "cached.jpg"
        try await database.writer().write { db in try cached.insert(db) }

        let recorder = RequestRecorder()
        let record = try await service.remoteRecord(for: "R1", client: makeClient(recorder))

        XCTAssertEqual(record.fileName, "cached.jpg")
        let request = await recorder.lastRequest
        XCTAssertNil(request)
    }
}
