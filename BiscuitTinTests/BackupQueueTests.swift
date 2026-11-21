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

    func testRecordFailureMarksIneligibleAtThreshold() throws {
        try insert("A", .pending)
        let threshold = BackupQueue.persistentFailureThreshold
        for attempt in 1..<threshold {
            try database.writer().write { db in
                try BackupQueue.recordFailure(db, identifier: "A", error: "PHPhotosErrorDomain -1",
                                              now: self.now, ineligibleAfter: threshold)
            }
            let record = try XCTUnwrap(try row("A"))
            XCTAssertEqual(record.backupState, .failed, "attempt \(attempt)")
            XCTAssertEqual(record.retryCount, attempt)
        }

        try database.writer().write { db in
            try BackupQueue.recordFailure(db, identifier: "A", error: "PHPhotosErrorDomain -1",
                                          now: self.now, ineligibleAfter: threshold)
        }
        let record = try XCTUnwrap(try row("A"))
        XCTAssertEqual(record.backupState, .ineligible)
        XCTAssertEqual(record.retryCount, threshold)
        XCTAssertEqual(record.lastError, "PHPhotosErrorDomain -1")
        XCTAssertEqual(record.nextAttemptAt, 0)

        let (counts, candidates) = try database.writer().read { db in
            (try BackupQueue.counts(db),
             try BackupQueue.uploadCandidates(db, now: self.now.addingTimeInterval(100_000), limit: 10))
        }
        XCTAssertEqual(counts.remaining, 0)
        XCTAssertEqual(counts.failed, 0)
        XCTAssertEqual(counts.retrying, 0)
        XCTAssertEqual(candidates, [])
    }

    func testRecordFailureImmediatelyMarksHighRetryRowIneligible() throws {
        try insert("A", .failed, retries: 21, nextAttemptAt: now.timeIntervalSince1970 - 1)
        try database.writer().write { db in
            try BackupQueue.recordFailure(db, identifier: "A", error: "PHPhotosErrorDomain -1",
                                          now: self.now,
                                          ineligibleAfter: BackupQueue.persistentFailureThreshold)
        }
        let record = try XCTUnwrap(try row("A"))
        XCTAssertEqual(record.backupState, .ineligible)
        XCTAssertEqual(record.retryCount, 22)
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

    // MARK: - Library scan

    private func scan(_ rows: [BackupQueue.LibraryRow], anchor: Date? = nil) throws -> BackupQueue.ScanResult {
        try database.writer().write { db in
            try BackupQueue.applyLibraryScan(db, rows: rows, anchor: anchor, now: self.now)
        }
    }

    private func libraryRow(_ id: String, created: Double = 0, modified: Double?) -> BackupQueue.LibraryRow {
        BackupQueue.LibraryRow(identifier: id, created: Date(timeIntervalSince1970: created),
                               modified: modified.map(Date.init(timeIntervalSince1970:)), kind: .image)
    }

    private func insertUploaded(_ id: String, modifiedAt: Double?, linkedTo immichID: String?) throws {
        try database.writer().write { db in
            try BackupStateRecord(localIdentifier: id, checksumHex: "c-\(id)", state: .uploaded,
                                  modifiedAt: modifiedAt).insert(db)
            try db.execute(sql: "INSERT INTO facet_links (checksum_hex, local_identifier, immich_id) VALUES (?, ?, ?)",
                           arguments: ["c-\(id)", id, immichID])
        }
    }

    private func pendingEdits() throws -> [PendingEditRecord] {
        try database.writer().read { db in try PendingEditRecord.fetchAll(db) }
    }

    func testScanAddsNewAssetsHonouringTheAnchor() throws {
        _ = try scan([libraryRow("old", created: 10, modified: nil), libraryRow("new", created: 30, modified: nil)],
                     anchor: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(try row("old")?.backupState, .outOfScope)
        XCTAssertEqual(try row("new")?.backupState, .pending)
    }

    func testFirstScanOfAnUploadedAssetOnlyTakesABaseline() throws {
        try insertUploaded("A", modifiedAt: nil, linkedTo: "R1")
        let result = try scan([libraryRow("A", modified: 500)])
        XCTAssertEqual(result, BackupQueue.ScanResult())
        XCTAssertEqual(try row("A")?.modifiedAt, 500)
        XCTAssertEqual(try pendingEdits().count, 0)
    }

    func testEditedLinkedAssetQueuesOneCheck() throws {
        try insertUploaded("A", modifiedAt: 500, linkedTo: "R1")
        let result = try scan([libraryRow("A", modified: 510)])
        XCTAssertEqual(result.edited, ["A"])
        let edits = try pendingEdits()
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits.first?.localIdentifier, "A")
        XCTAssertEqual(edits.first?.immichID, "R1")
        XCTAssertEqual(try row("A")?.modifiedAt, 510)

        let again = try scan([libraryRow("A", modified: 510)])
        XCTAssertEqual(again, BackupQueue.ScanResult())
        XCTAssertEqual(try pendingEdits().count, 1)
    }

    func testEditedUnlinkedAssetIsUploadedAfresh() throws {
        try insertUploaded("A", modifiedAt: 500, linkedTo: nil)
        let result = try scan([libraryRow("A", modified: 510)])
        XCTAssertEqual(result.requeued, ["A"])
        let record = try XCTUnwrap(try row("A"))
        XCTAssertEqual(record.backupState, .pending)
        XCTAssertNil(record.checksumHex)
        XCTAssertNil(record.modifiedAt)
        let halfLinks = try database.writer().read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM facet_links WHERE local_identifier = 'A'")
        }
        XCTAssertEqual(halfLinks, 0)
        XCTAssertEqual(try pendingEdits().count, 0)
    }

    func testSmallDateDriftIsIgnored() throws {
        try insertUploaded("A", modifiedAt: 500, linkedTo: "R1")
        let result = try scan([libraryRow("A", modified: 500.2)])
        XCTAssertEqual(result, BackupQueue.ScanResult())
        XCTAssertEqual(try pendingEdits().count, 0)
    }

    func testPendingRowIsNotTreatedAsEdited() throws {
        try database.writer().write { db in
            try BackupStateRecord(localIdentifier: "A", state: .pending, modifiedAt: 500).insert(db)
        }
        let result = try scan([libraryRow("A", modified: 900)])
        XCTAssertEqual(result, BackupQueue.ScanResult())
        XCTAssertEqual(try row("A")?.modifiedAt, 500)
    }

    func testExistingPendingEditIsUpdatedNotDuplicated() throws {
        try insertUploaded("A", modifiedAt: 500, linkedTo: "R1")
        try database.writer().write { db in
            try PendingEditRecord(localIdentifier: "A", immichID: "R1", editType: .rotation, mediaKind: .image,
                                  payload: nil, retryCount: 3, updatedAt: 1, nextAttemptAt: 99_999_999).insert(db)
        }
        _ = try scan([libraryRow("A", modified: 510)])
        let edits = try pendingEdits()
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits.first?.retryCount, 0)
        XCTAssertEqual(edits.first?.nextAttemptAt, 0)
    }
}
