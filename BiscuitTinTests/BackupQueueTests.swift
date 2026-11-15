import XCTest
import GRDB
@testable import BiscuitTin

final class BackupQueueTests: XCTestCase {

    private var databaseURL: URL!
    private var database: AppDatabase!
    private let now = Date(timeIntervalSince1970: 1_000_000)

    override func setUpWithError() throws {
        databaseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("backup-queue-\(UUID().uuidString).sqlite")
        database = AppDatabase(fileURL: databaseURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: databaseURL)
        try super.tearDownWithError()
    }

    private func insert(_ id: String, _ state: BackupStateRecord.State, updatedAt: Double = 0,
                        retries: Int = 0, nextAttemptAt: Double = 0) throws {
        try database.writer().write { db in
            try BackupStateRecord(localIdentifier: id, state: state, retryCount: retries,
                                  updatedAt: Date(timeIntervalSince1970: updatedAt),
                                  nextAttemptAt: nextAttemptAt).insert(db)
        }
    }

    private func row(_ id: String) throws -> BackupStateRecord? {
        try database.writer().read { db in try BackupStateRecord.fetchOne(db, key: id) }
    }

    // MARK: - Upload queue

    func testUploadCandidatesAreDueRowsOldestFirst() throws {
        let past = now.timeIntervalSince1970 - 1
        let future = now.timeIntervalSince1970 + 60
        try insert("P2", .pending, updatedAt: 20)
        try insert("P1", .pending, updatedAt: 10)
        try insert("Fdue", .failed, updatedAt: 15, retries: 1, nextAttemptAt: past)
        try insert("Flater", .failed, updatedAt: 5, retries: 1, nextAttemptAt: future)
        try insert("U", .uploaded, updatedAt: 1)

        let all = try database.writer().read { db in try BackupQueue.uploadCandidates(db, now: self.now, limit: 10) }
        XCTAssertEqual(all, ["P1", "Fdue", "P2"])
        let two = try database.writer().read { db in try BackupQueue.uploadCandidates(db, now: self.now, limit: 2) }
        XCTAssertEqual(two, ["P1", "Fdue"])
    }

    func testNothingIsAbandoned() throws {
        try insert("F", .failed, retries: 9, nextAttemptAt: now.timeIntervalSince1970 - 1)
        let candidates = try database.writer().read { db in try BackupQueue.uploadCandidates(db, now: self.now, limit: 10) }
        XCTAssertEqual(candidates, ["F"])
    }

    func testRecordFailureBacksOff() throws {
        try insert("A", .pending)
        try database.writer().write { db in
            try BackupQueue.recordFailure(db, identifier: "A", error: "boom", now: self.now)
            try BackupQueue.recordFailure(db, identifier: "A", error: "boom again", now: self.now)
        }
        let record = try XCTUnwrap(try row("A"))
        XCTAssertEqual(record.backupState, .failed)
        XCTAssertEqual(record.retryCount, 2)
        XCTAssertEqual(record.lastError, "boom again")
        XCTAssertEqual(record.nextAttemptAt - now.timeIntervalSince1970, 120)
    }

    func testResetFailuresGivesACleanSlate() throws {
        try insert("F", .failed, retries: 7, nextAttemptAt: 99)
        try insert("I", .ineligible)
        try insert("U", .uploaded, retries: 2)
        try insert("O", .outOfScope)

        try database.writer().write { db in try BackupQueue.resetFailures(db) }

        for id in ["F", "I"] {
            let record = try XCTUnwrap(try row(id))
            XCTAssertEqual(record.backupState, .pending, id)
            XCTAssertEqual(record.retryCount, 0, id)
            XCTAssertEqual(record.nextAttemptAt, 0, id)
        }
        XCTAssertEqual(try row("U")?.backupState, .uploaded)
        XCTAssertEqual(try row("U")?.retryCount, 2)
        XCTAssertEqual(try row("O")?.backupState, .outOfScope)
    }

    func testActionableCountSkipsFailuresNotYetDue() throws {
        try insert("P", .pending)
        try insert("Up", .uploading)
        try insert("Fdue", .failed, nextAttemptAt: now.timeIntervalSince1970)
        try insert("Flater", .failed, nextAttemptAt: now.timeIntervalSince1970 + 60)
        try insert("U", .uploaded)
        let count = try database.writer().read { db in try BackupQueue.actionableCount(db, now: self.now) }
        XCTAssertEqual(count, 3)
    }

    func testCountsSplitPersistentFailuresFromRetrying() throws {
        try insert("P", .pending)
        try insert("F5", .failed, retries: 5)
        try insert("F9", .failed, retries: 9)
        try insert("F1", .failed, retries: 1)
        try insert("U", .uploaded)
        let counts = try database.writer().read { db in try BackupQueue.counts(db) }
        XCTAssertEqual(counts.remaining, 4)
        XCTAssertEqual(counts.failed, 2)
        XCTAssertEqual(counts.retrying, 1)
    }
}
