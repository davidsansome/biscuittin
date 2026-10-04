import XCTest
import GRDB
@testable import BiscuitTin

/// Immich answers `SyncResetV1` alone, instead of changes, once a session's checkpoint is older
/// than its 30-day audit retention. Deletes from before then are never reported, so a cache kept
/// across that gap would show hard-deleted server photos forever.
final class SyncResetTests: XCTestCase {

    private var databaseURL: URL!
    private var database: AppDatabase!

    override func setUpWithError() throws {
        databaseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sync-reset-\(UUID().uuidString).sqlite")
        database = AppDatabase(fileURL: databaseURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: databaseURL)
        try super.tearDownWithError()
    }

    private func makeService() -> RemoteLibraryService {
        RemoteLibraryService(database: database,
                             session: ImmichAuthSession(defaults: UserDefaults(suiteName: "sync-reset-tests-\(UUID())")!),
                             resolver: PHAssetResolver(),
                             exporter: LocalAssetExporter())
    }

    private func makeClient(_ recorder: RequestRecorder) -> ImmichClient {
        ImmichClient(baseURL: URL(string: "https://s.example.com")!,
                     session: StubURLProtocol.makeSession(recorder),
                     tokenProvider: { "tok" })
    }

    /// `gone` was hard-deleted on the server more than 30 days ago; `kept` still exists. `L1` is
    /// a local photo that was uploaded as `gone`, `L2` one uploaded as `kept`.
    private func seedStaleCache() throws {
        try database.writer().write { db in
            for (id, checksum) in [("gone", "aa"), ("kept", "bb"), ("gone-remote-only", "cc")] {
                var record = RemoteAssetRecord(placeholderID: id)
                record.checksumHex = checksum
                try record.insert(db)
            }
            try db.execute(sql: """
                INSERT INTO facet_links (checksum_hex, local_identifier, immich_id) VALUES
                    ('aa', 'L1', 'gone'), ('bb', 'L2', 'kept'), ('cc', NULL, 'gone-remote-only')
                """)
            try BackupStateRecord(localIdentifier: "L1", checksumHex: "aa", state: .uploaded).insert(db)
            try BackupStateRecord(localIdentifier: "L2", checksumHex: "bb", state: .uploaded).insert(db)
            try db.execute(sql: "INSERT INTO kv (key, value) VALUES ('cache_owner', 'me')")
        }
    }

    /// `checksum` is base64, as the server sends it; "uw==" is hex "bb".
    private static let keptLine = """
        {"type":"AssetV2","ack":"AssetV2|0002","data":{"id":"kept","originalFileName":"x.jpg",\
        "checksum":"uw==","fileCreatedAt":"2026-08-18T10:00:00.000Z","fileModifiedAt":null,\
        "localDateTime":"2026-08-18T10:00:00.000Z","duration":null,"type":"IMAGE",\
        "deletedAt":null,"visibility":"timeline","livePhotoVideoId":null,"width":100,"height":100}}
        """
    private static let completeLine = #"{"type":"SyncCompleteV1","ack":"SyncCompleteV1|0003","data":{}}"#
    private static let resetLine = #"{"type":"SyncResetV1","ack":"SyncResetV1|reset","data":{}}"#

    private func remoteIDs() throws -> [String] {
        try database.writer().read { db in
            try String.fetchAll(db, sql: "SELECT immich_id FROM remote_assets ORDER BY immich_id")
        }
    }

    private func streamRequests(_ recorder: RequestRecorder) async throws -> [Bool] {
        try await recorder.bodies.filter { $0.path == "/api/sync/stream" }.map {
            try JSONDecoder().decode(StreamRequest.self, from: XCTUnwrap($0.body)).reset
        }
    }

    private func acks(_ recorder: RequestRecorder) async throws -> [String] {
        try await recorder.bodies.filter { $0.path == "/api/sync/ack" }.flatMap {
            try JSONDecoder().decode(AckRequest.self, from: XCTUnwrap($0.body)).acks
        }
    }

    private struct StreamRequest: Decodable { let reset: Bool }
    private struct AckRequest: Decodable { let acks: [String] }

    func testServerResetReplaysAndReplacesTheCache() async throws {
        try seedStaleCache()
        let recorder = RequestRecorder()
        await recorder.enqueue(path: "/api/sync/stream", json: Self.resetLine)
        await recorder.enqueue(path: "/api/sync/stream", json: Self.keptLine + "\n" + Self.completeLine)
        await recorder.stub(path: "/api/sync/ack", json: "", status: 204)
        let service = makeService()

        try await service.syncStream(client: makeClient(recorder), reset: false, isSignedIn: { true })

        let requests = try await streamRequests(recorder)
        XCTAssertEqual(requests, [false, true], "a reset line must be answered with a full replay")
        XCTAssertEqual(try remoteIDs(), ["kept"])

        let (links, states, owner) = try await database.writer().read { db in
            (try Row.fetchAll(db, sql: "SELECT checksum_hex, local_identifier, immich_id FROM facet_links ORDER BY checksum_hex"),
             try Row.fetchAll(db, sql: "SELECT local_identifier, state FROM backup_state ORDER BY local_identifier"),
             try String.fetchOne(db, sql: "SELECT value FROM kv WHERE key = 'cache_owner'"))
        }
        XCTAssertEqual(links.map { $0["checksum_hex"] as String }, ["aa", "bb"],
                       "a remote-only link goes with its asset; local halves stay")
        XCTAssertNil(links[0]["immich_id"] as String?, "L1's server copy is gone")
        XCTAssertEqual(links[1]["immich_id"], "kept", "L2 is relinked by the replay")
        XCTAssertEqual(states.map { $0["state"] as String }, ["uploaded", "uploaded"],
                       "re-queuing L1 would re-upload a photo deliberately deleted on the server")
        XCTAssertEqual(owner, "me", "same server, so the cache keeps its owner")

        let acked = try await acks(recorder)
        XCTAssertEqual(Set(acked), ["AssetV2|0002", "SyncCompleteV1|0003"])
        XCTAssertFalse(acked.contains { $0.hasPrefix("SyncResetV1") },
                       "acking the reset after the replay would discard the replay's checkpoints")
    }

    /// The control: an ordinary incremental sync must not touch rows it was not told about.
    func testIncrementalSyncKeepsUnmentionedRows() async throws {
        try seedStaleCache()
        let recorder = RequestRecorder()
        await recorder.stub(path: "/api/sync/stream", json: Self.keptLine + "\n" + Self.completeLine)
        await recorder.stub(path: "/api/sync/ack", json: "", status: 204)

        try await makeService().syncStream(client: makeClient(recorder), reset: false, isSignedIn: { true })

        let requests = try await streamRequests(recorder)
        XCTAssertEqual(requests, [false])
        XCTAssertEqual(try remoteIDs(), ["gone", "gone-remote-only", "kept"])
    }

    /// Sign-in asks for a replay itself; that one is just as authoritative about what is gone.
    func testRequestedResetAlsoReplacesTheCache() async throws {
        try seedStaleCache()
        let recorder = RequestRecorder()
        await recorder.stub(path: "/api/sync/stream", json: Self.keptLine + "\n" + Self.completeLine)
        await recorder.stub(path: "/api/sync/ack", json: "", status: 204)

        try await makeService().syncStream(client: makeClient(recorder), reset: true, isSignedIn: { true })

        let requests = try await streamRequests(recorder)
        XCTAssertEqual(requests, [true])
        XCTAssertEqual(try remoteIDs(), ["kept"])
    }

    /// A replay that fails must leave the old cache in place rather than an empty grid.
    func testFailedReplayKeepsTheCache() async throws {
        try seedStaleCache()
        let recorder = RequestRecorder()
        await recorder.enqueue(path: "/api/sync/stream", json: Self.resetLine)
        await recorder.enqueue(path: "/api/sync/stream", json: "{}", status: 500)

        do {
            try await makeService().syncStream(client: makeClient(recorder), reset: false, isSignedIn: { true })
            XCTFail("expected the replay's failure to propagate")
        } catch {}

        XCTAssertEqual(try remoteIDs(), ["gone", "gone-remote-only", "kept"])
        let acked = try await acks(recorder)
        XCTAssertEqual(acked, [])
    }
}
