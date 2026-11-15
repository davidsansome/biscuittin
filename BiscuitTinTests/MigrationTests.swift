import XCTest
import GRDB
@testable import BiscuitTin

final class MigrationTests: XCTestCase {

    private var databaseURL: URL!

    override func setUpWithError() throws {
        databaseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("migration-\(UUID().uuidString).sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: databaseURL)
        try super.tearDownWithError()
    }

    func testV7ReleasesStrandedRows() throws {
        let queue = try DatabaseQueue(path: databaseURL.path)
        try AppDatabase.migrator.migrate(queue, upTo: "v6-partner-sharing")
        try queue.write { db in
            for (id, state, retries) in [("I", "ineligible", 0), ("F", "failed", 5), ("U", "uploaded", 2)] {
                try db.execute(sql: """
                    INSERT INTO backup_state (local_identifier, checksum_hex, state, last_error, retry_count, updated_at)
                    VALUES (?, NULL, ?, 'boom', ?, 0)
                    """, arguments: [id, state, retries])
            }
        }

        try AppDatabase.migrator.migrate(queue)

        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT local_identifier, state, retry_count, last_error FROM backup_state ORDER BY local_identifier
                """)
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0["local_identifier"] as String, $0) })
            for id in ["I", "F"] {
                XCTAssertEqual(byID[id]?["state"], "pending", id)
                XCTAssertEqual(byID[id]?["retry_count"], 0, id)
                XCTAssertNil(byID[id]?["last_error"] as String?, id)
            }
            XCTAssertEqual(byID["U"]?["state"], "uploaded")
            XCTAssertEqual(byID["U"]?["retry_count"], 2)
            XCTAssertEqual(byID["U"]?["last_error"], "boom")
        }
    }

    func testV7AddsColumns() throws {
        let queue = try DatabaseQueue(path: databaseURL.path)
        try AppDatabase.migrator.migrate(queue)

        let backup = BackupStateRecord(localIdentifier: "L1", checksumHex: "aa", state: .failed,
                                       updatedAt: Date(timeIntervalSince1970: 100),
                                       modifiedAt: 50, nextAttemptAt: 160)
        let edit = PendingEditRecord(localIdentifier: "L1", immichID: "R1", editType: .rotation,
                                     mediaKind: .image, payload: nil, updatedAt: 100,
                                     nextAttemptAt: 200, uploadedID: "R2", uploadedChecksum: "bb")
        try queue.write { db in
            try backup.insert(db)
            try edit.insert(db)
        }

        try queue.read { db in
            XCTAssertEqual(try BackupStateRecord.fetchOne(db, key: "L1"), backup)
            var fetched = try XCTUnwrap(PendingEditRecord.fetchOne(db))
            fetched.id = nil
            XCTAssertEqual(fetched, edit)
        }
    }
}
