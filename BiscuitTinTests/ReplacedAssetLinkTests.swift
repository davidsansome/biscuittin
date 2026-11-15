import XCTest
import GRDB
@testable import BiscuitTin

/// Replacing a server asset (a rotation, or pushing an edit made during upload) uploads a new
/// asset and trashes the old one. The next sync reports both: the old one, now trashed, still
/// carrying the checksum the local photo is linked under.
final class ReplacedAssetLinkTests: XCTestCase {

    private var databaseURL: URL!
    private var database: AppDatabase!

    override func setUpWithError() throws {
        databaseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("replaced-link-\(UUID().uuidString).sqlite")
        database = AppDatabase(fileURL: databaseURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: databaseURL)
        try super.tearDownWithError()
    }

    /// "qg==" is hex "aa", the bytes first uploaded; "uw==" is hex "bb", the replacement's.
    private static func line(id: String, checksum: String, deletedAt: String?) -> String {
        let deleted = deletedAt.map { "\"\($0)\"" } ?? "null"
        return """
            {"type":"AssetV2","ack":"AssetV2|\(id)","data":{"id":"\(id)","originalFileName":"x.jpg",\
            "checksum":"\(checksum)","fileCreatedAt":"2026-08-18T10:00:00.000Z","fileModifiedAt":null,\
            "localDateTime":"2026-08-18T10:00:00.000Z","duration":null,"type":"IMAGE",\
            "deletedAt":\(deleted),"visibility":"timeline","livePhotoVideoId":null,"width":100,"height":100}}
            """
    }

    func testTrashedOriginalDoesNotTakeTheLinkBackFromItsReplacement() async throws {
        // As `repointAfterRotation` leaves things: the local photo's link, still keyed by the
        // checksum it was uploaded under, now names the replacement.
        try await database.writer().write { db in
            var record = RemoteAssetRecord(placeholderID: "new")
            record.checksumHex = "bb"
            try record.insert(db)
            try db.execute(sql: """
                INSERT INTO facet_links (checksum_hex, local_identifier, immich_id) VALUES ('aa', 'L1', 'new')
                """)
        }

        let recorder = RequestRecorder()
        await recorder.enqueue(path: "/api/sync/stream", json: [
            Self.line(id: "old", checksum: "qg==", deletedAt: "2026-08-19T10:00:00.000Z"),
            Self.line(id: "new", checksum: "uw==", deletedAt: nil),
            #"{"type":"SyncCompleteV1","ack":"SyncCompleteV1|0003","data":{}}"#,
        ].joined(separator: "\n"))
        await recorder.stub(path: "/api/sync/ack", json: "", status: 204)

        let service = RemoteLibraryService(
            database: database,
            session: ImmichAuthSession(defaults: UserDefaults(suiteName: "replaced-link-tests-\(UUID())")!),
            resolver: PHAssetResolver(),
            exporter: LocalAssetExporter())
        let client = ImmichClient(baseURL: URL(string: "https://s.example.com")!,
                                  session: StubURLProtocol.makeSession(recorder),
                                  tokenProvider: { "tok" })
        try await service.syncStream(client: client, reset: false, isSignedIn: { true })

        let links = try await service.links()
        XCTAssertEqual(links, ["new": "L1"],
                       "the local photo must stay linked to the live replacement, or both show in the grid")
    }

    private func makeService() -> RemoteLibraryService {
        RemoteLibraryService(
            database: database,
            session: ImmichAuthSession(defaults: UserDefaults(suiteName: "replaced-link-tests-\(UUID())")!),
            resolver: PHAssetResolver(),
            exporter: LocalAssetExporter())
    }

    private func sync(_ service: RemoteLibraryService, lines: [String]) async throws {
        let recorder = RequestRecorder()
        await recorder.enqueue(path: "/api/sync/stream", json: (lines + [
            #"{"type":"SyncCompleteV1","ack":"SyncCompleteV1|0003","data":{}}"#,
        ]).joined(separator: "\n"))
        await recorder.stub(path: "/api/sync/ack", json: "", status: 204)
        let client = ImmichClient(baseURL: URL(string: "https://s.example.com")!,
                                  session: StubURLProtocol.makeSession(recorder),
                                  tokenProvider: { "tok" })
        try await service.syncStream(client: client, reset: false, isSignedIn: { true })
    }

    private func linkRows(checksum: String) async throws -> [[String?]] {
        try await database.writer().read { db in
            try Row.fetchAll(db, sql: """
                SELECT checksum_hex, local_identifier, immich_id FROM facet_links WHERE checksum_hex = ?
                """, arguments: [checksum]).map { [$0["checksum_hex"], $0["local_identifier"], $0["immich_id"]] }
        }
    }

    func testTrashingAServerAssetReleasesItsLink() async throws {
        try await database.writer().write { db in
            var record = RemoteAssetRecord(placeholderID: "r1")
            record.checksumHex = "aa"
            try record.insert(db)
            try db.execute(sql: "INSERT INTO facet_links (checksum_hex, local_identifier, immich_id) VALUES ('aa', 'L1', 'r1')")
        }
        let service = makeService()
        try await sync(service, lines: [Self.line(id: "r1", checksum: "qg==", deletedAt: "2026-08-19T10:00:00.000Z")])

        let links = try await service.links()
        XCTAssertEqual(links, [:])
        let rows = try await linkRows(checksum: "aa")
        XCTAssertEqual(rows, [["aa", "L1", nil]], "the local half must survive so a restore can relink it")
    }

    func testRestoringAServerAssetRelinksIt() async throws {
        try await testTrashingAServerAssetReleasesItsLink()
        let service = makeService()
        try await sync(service, lines: [Self.line(id: "r1", checksum: "qg==", deletedAt: nil)])
        let links = try await service.links()
        XCTAssertEqual(links, ["r1": "L1"])
    }

    func testTrashedRemoteOnlyAssetLeavesNoLinkRow() async throws {
        try await database.writer().write { db in
            var record = RemoteAssetRecord(placeholderID: "r2")
            record.checksumHex = "cc"
            try record.insert(db)
            try db.execute(sql: "INSERT INTO facet_links (checksum_hex, local_identifier, immich_id) VALUES ('cc', NULL, 'r2')")
        }
        let service = makeService()
        try await sync(service, lines: [Self.line(id: "r2", checksum: "zA==", deletedAt: "2026-08-19T10:00:00.000Z")])
        let rows = try await linkRows(checksum: "cc")
        XCTAssertEqual(rows, [])
    }
}
