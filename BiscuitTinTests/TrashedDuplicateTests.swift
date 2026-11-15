import XCTest
import GRDB
@testable import BiscuitTin

/// A server copy in the trash is not a backup: it is taken out of the trash instead.
final class TrashedDuplicateTests: XCTestCase {

    private var databaseURL: URL!
    private var database: AppDatabase!
    private var recorder: RequestRecorder!

    override func setUpWithError() throws {
        databaseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trashed-duplicate-\(UUID().uuidString).sqlite")
        database = AppDatabase(fileURL: databaseURL)
        recorder = RequestRecorder()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: databaseURL)
        try super.tearDownWithError()
    }

    private func makeClient() -> ImmichClient {
        ImmichClient(baseURL: URL(string: "https://s.example.com")!,
                     session: StubURLProtocol.makeSession(recorder),
                     tokenProvider: { "tok" })
    }

    private func makeService() -> RemoteLibraryService {
        RemoteLibraryService(database: database,
                             session: ImmichAuthSession(defaults: UserDefaults(suiteName: "trashed-duplicate-\(UUID())")!),
                             resolver: PHAssetResolver(),
                             exporter: LocalAssetExporter())
    }

    private static func assetJSON(id: String, isTrashed: Bool) -> String {
        """
        {"id":"\(id)","type":"IMAGE","checksum":"qg==","originalFileName":"IMG_1.HEIC",
         "localDateTime":"2026-08-18T10:00:00.000Z","fileCreatedAt":"2026-08-17T23:00:00.000Z",
         "width":400,"height":300,"duration":"0:00:00.00000","isTrashed":\(isTrashed)}
        """
    }

    func testRestoreFromTrashSendsTheIDsAndUntrashesTheRow() async throws {
        await recorder.stub(method: "POST", path: "/api/trash/restore/assets", json: "", status: 204)
        try await database.writer().write { db in
            var record = RemoteAssetRecord(placeholderID: "t1")
            record.checksumHex = "aa"
            record.isTrashed = true
            try record.insert(db)
        }

        try await makeService().restoreFromTrash(ids: ["t1"], client: makeClient())

        let requests = await recorder.requests
        let restore = try XCTUnwrap(requests.first { $0.path == "/api/trash/restore/assets" })
        XCTAssertEqual(restore.method, "POST")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(restore.body)) as? [String: Any])
        XCTAssertEqual(json["ids"] as? [String], ["t1"])
        let trashed = try await database.writer().read { db in
            try Bool.fetchOne(db, sql: "SELECT is_trashed FROM remote_assets WHERE immich_id = 't1'")
        }
        XCTAssertEqual(trashed, false)
    }

    func testEnsureLiveLeavesALiveAssetAlone() async throws {
        await recorder.stub(method: "GET", path: "/api/assets/a1", json: Self.assetJSON(id: "a1", isTrashed: false))
        try await makeService().ensureLive(immichID: "a1", client: makeClient())
        let log = await recorder.log
        XCTAssertEqual(log, ["GET /api/assets/a1"])
    }

    func testEnsureLiveRestoresATrashedAsset() async throws {
        await recorder.stub(method: "GET", path: "/api/assets/a1", json: Self.assetJSON(id: "a1", isTrashed: true))
        await recorder.stub(method: "POST", path: "/api/trash/restore/assets", json: "", status: 204)
        try await makeService().ensureLive(immichID: "a1", client: makeClient())
        let log = await recorder.log
        XCTAssertEqual(log, ["GET /api/assets/a1", "POST /api/trash/restore/assets"])
    }

    func testOnlyADuplicateNeedsATrashCheck() {
        XCTAssertTrue(SyncEngine.needsTrashCheck(Immich.UploadResponse(id: "a", status: "duplicate")))
        XCTAssertFalse(SyncEngine.needsTrashCheck(Immich.UploadResponse(id: "a", status: "created")))
        XCTAssertFalse(SyncEngine.needsTrashCheck(nil))
    }
}
