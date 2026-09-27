import XCTest
import GRDB
@testable import BiscuitTin

/// Signing in to a different server or account must not leave the previous one's assets in the
/// cache, where the grid still shows them but their images can no longer be fetched.
final class CacheOwnerTests: XCTestCase {

    private var databaseURL: URL!
    private var database: AppDatabase!

    override func setUpWithError() throws {
        databaseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cache-owner-\(UUID().uuidString).sqlite")
        database = AppDatabase(fileURL: databaseURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: databaseURL)
        try super.tearDownWithError()
    }

    private func makeService() -> RemoteLibraryService {
        RemoteLibraryService(database: database,
                             session: ImmichAuthSession(defaults: UserDefaults(suiteName: "cache-owner-tests-\(UUID())")!),
                             resolver: PHAssetResolver(),
                             exporter: LocalAssetExporter())
    }

    private func seedOldServer() throws {
        try database.writer().write { db in
            var record = RemoteAssetRecord(placeholderID: "R1")
            record.checksumHex = "linked"
            try record.insert(db)
            try db.execute(sql: """
                INSERT INTO facet_links (checksum_hex, local_identifier, immich_id) VALUES
                    ('linked', 'L1', 'R1'), ('remote-only', NULL, 'R2')
                """)
            try BackupStateRecord(localIdentifier: "L1", checksumHex: "linked", state: .uploaded).insert(db)
            try BackupStateRecord(localIdentifier: "L2", state: .outOfScope).insert(db)
        }
    }

    private func remoteCount() throws -> Int {
        try database.writer().read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM remote_assets") ?? 0
        }
    }

    func testSameOwnerKeepsTheCache() async throws {
        let service = makeService()
        try await service.claimCache(for: "a@example.com https://one.example")
        try seedOldServer()

        let wiped = try await service.claimCache(for: "a@example.com https://one.example")

        XCTAssertFalse(wiped)
        XCTAssertEqual(try remoteCount(), 1)
    }

    func testDifferentOwnerWipesServerDataButKeepsLocalChecksums() async throws {
        let service = makeService()
        try await service.claimCache(for: "a@example.com https://one.example")
        try seedOldServer()

        let wiped = try await service.claimCache(for: "a@example.com https://two.example")

        XCTAssertTrue(wiped)
        XCTAssertEqual(try remoteCount(), 0)
        let (links, states) = try await database.writer().read { db in
            (try Row.fetchAll(db, sql: "SELECT checksum_hex, local_identifier, immich_id FROM facet_links"),
             try Row.fetchAll(db, sql: "SELECT local_identifier, state FROM backup_state ORDER BY local_identifier"))
        }
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?["checksum_hex"], "linked")
        XCTAssertEqual(links.first?["local_identifier"], "L1")
        XCTAssertNil(links.first?["immich_id"] as String?)
        XCTAssertEqual(states.map { $0["state"] as String }, ["pending", "out_of_scope"])
    }

    /// A cache filled before owners were recorded cannot be attributed to anyone.
    func testUnownedCacheIsWiped() async throws {
        try seedOldServer()

        let wiped = try await makeService().claimCache(for: "a@example.com https://one.example")

        XCTAssertTrue(wiped)
        XCTAssertEqual(try remoteCount(), 0)
    }
}
