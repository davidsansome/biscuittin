import XCTest
import GRDB
@testable import BiscuitTin

/// The reads `TimelineStore` merges from: the narrow stub query must agree with the full record
/// mapping it replaced, and the by-id read is what keeps the timeline's cached rows current.
final class RemoteMergeReadTests: XCTestCase {

    private var databaseURL: URL!
    private var database: AppDatabase!

    override func setUpWithError() throws {
        databaseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remote-merge-\(UUID().uuidString).sqlite")
        database = AppDatabase(fileURL: databaseURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: databaseURL)
        try super.tearDownWithError()
    }

    private func makeService() -> RemoteLibraryService {
        RemoteLibraryService(database: database,
                             session: ImmichAuthSession(defaults: UserDefaults(suiteName: "remote-merge-tests-\(UUID())")!),
                             resolver: PHAssetResolver(),
                             exporter: LocalAssetExporter())
    }

    private func record(_ id: String, capturedAt: Double, trashed: Bool = false) -> RemoteAssetRecord {
        var record = RemoteAssetRecord(placeholderID: id)
        record.checksumHex = "sum-\(id)"
        record.captureAt = capturedAt
        record.isTrashed = trashed
        return record
    }

    private func insert(_ records: [RemoteAssetRecord]) throws {
        try database.writer().write { db in
            for record in records { try record.insert(db) }
        }
    }

    func testNarrowQueryMatchesRecordMapping() async throws {
        var video = record("video", capturedAt: 300)
        video.type = Immich.AssetType.video.rawValue
        video.durationSeconds = 75.5
        video.width = 1920
        video.height = 1080
        var live = record("live", capturedAt: 200)
        live.livePhotoVideoID = "motion"
        live.latitude = -33.8688
        live.longitude = 151.2093
        let plain = record("plain", capturedAt: 100)
        try insert([plain, video, live])

        let stubs = try await makeService().remoteStubs()

        XCTAssertEqual(stubs, [video.stub, live.stub, plain.stub])
    }

    func testTrashedRowsAreLeftOut() async throws {
        try insert([record("kept", capturedAt: 2), record("binned", capturedAt: 1, trashed: true)])
        let service = makeService()

        let all = try await service.remoteStubs()
        let byID = try await service.remoteStubs(ids: ["kept", "binned"])

        XCTAssertEqual(all.map(\.id), [.remote("kept")])
        XCTAssertEqual(byID.map(\.id), [.remote("kept")])
    }

    /// Past one statement's worth of bound parameters, the read is split into chunks.
    func testLookupByIDReturnsExactlyTheNamedRows() async throws {
        try insert((0..<1_200).map { record("a\($0)", capturedAt: Double($0)) })
        let wanted = Set((0..<1_200).filter { $0 % 2 == 0 }.map { "a\($0)" }).union(["missing"])

        let stubs = try await makeService().remoteStubs(ids: wanted)

        let expected = Set(wanted.subtracting(["missing"]).map { AssetID.remote($0) })
        XCTAssertEqual(Set(stubs.map(\.id)), expected)
    }

    func testOnlyCompleteLinksAreMerged() async throws {
        try await database.writer().write { db in
            try db.execute(sql: """
                INSERT INTO facet_links (checksum_hex, local_identifier, immich_id) VALUES
                    ('both', 'L1', 'R1'), ('local-only', 'L2', NULL), ('remote-only', NULL, 'R3')
                """)
        }

        let links = try await makeService().mergeLinks()

        XCTAssertEqual(links.localIdentifierByImmichID, ["R1": "L1"])
        XCTAssertEqual(links.linkedLocalIdentifiers, ["L1"])
        XCTAssertTrue(links.stubs.isEmpty)
    }
}
