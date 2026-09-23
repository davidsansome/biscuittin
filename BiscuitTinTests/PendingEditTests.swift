import XCTest
import GRDB
@testable import BiscuitTin

/// The pending-edit retry queue (DESIGN.md D22): a local edit whose remote leg failed, queued
/// for catch-up once the server is reachable again.
final class PendingEditTests: XCTestCase {

    private var databaseURL: URL!
    private var database: AppDatabase!

    override func setUpWithError() throws {
        databaseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pending-edits-\(UUID().uuidString).sqlite")
        database = AppDatabase(fileURL: databaseURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: databaseURL)
        try super.tearDownWithError()
    }

    private func makeService() -> RemoteLibraryService {
        RemoteLibraryService(database: database,
                             session: ImmichAuthSession(defaults: UserDefaults(suiteName: "pending-edit-tests-\(UUID())")!),
                             resolver: PHAssetResolver(),
                             exporter: LocalAssetExporter())
    }

    private func rowCount() throws -> Int {
        try database.writer().read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_edits") ?? 0
        }
    }

    private func fetchRow(localIdentifier: String) throws -> PendingEditRecord? {
        try database.writer().read { db in
            try PendingEditRecord.filter(sql: "local_identifier = ?", arguments: [localIdentifier]).fetchOne(db)
        }
    }

    // MARK: - Schema

    /// Pins the two partial unique indexes directly against SQLite, independent of any
    /// application-level "check before insert" logic — the constraint is the actual backstop.
    func testLocalIdentifierIsUniqueAmongLocalBackedRows() throws {
        let writer = try database.writer()
        try writer.write { db in
            try PendingEditRecord(localIdentifier: "L1", immichID: "R1", editType: .rotation,
                                  mediaKind: .image, payload: nil, updatedAt: 1).insert(db)
        }
        XCTAssertThrowsError(try writer.write { db in
            try PendingEditRecord(localIdentifier: "L1", immichID: "R2", editType: .rotation,
                                  mediaKind: .image, payload: nil, updatedAt: 2).insert(db)
        })
    }

    func testImmichIDIsUniqueAmongRemoteOnlyRowsButNotAgainstLocalBackedOnes() throws {
        let writer = try database.writer()
        try writer.write { db in
            try PendingEditRecord(localIdentifier: nil, immichID: "R1", editType: .rotation,
                                  mediaKind: .image, payload: nil, updatedAt: 1).insert(db)
        }
        // A second remote-only row for the same immich id collides...
        XCTAssertThrowsError(try writer.write { db in
            try PendingEditRecord(localIdentifier: nil, immichID: "R1", editType: .rotation,
                                  mediaKind: .image, payload: nil, updatedAt: 2).insert(db)
        })
        // ...but a local-backed row naming that same immich id does not: the two identity
        // spaces are independent, since a local-backed row is keyed by local_identifier.
        XCTAssertNoThrow(try writer.write { db in
            try PendingEditRecord(localIdentifier: "L1", immichID: "R1", editType: .rotation,
                                  mediaKind: .image, payload: nil, updatedAt: 3).insert(db)
        })
    }

    // MARK: - RotationPayload

    func testRotationPayloadRoundTripsThroughJSON() throws {
        let json = try XCTUnwrap(RotationPayload(clockwise: true).jsonString)
        let decoded = try XCTUnwrap(RotationPayload(jsonString: json))
        XCTAssertTrue(decoded.clockwise)
    }

    func testRotationPayloadRejectsGarbage() {
        XCTAssertNil(RotationPayload(jsonString: "not json"))
    }

    // MARK: - Enqueue (D22)

    func testEnqueueLocalBackedRotationStoresNoPayload() async throws {
        let service = makeService()
        try await service.enqueuePendingRotation(localIdentifier: "L1", immichID: "R1",
                                                  mediaKind: .image, clockwise: true)
        let row = try XCTUnwrap(try fetchRow(localIdentifier: "L1"))
        XCTAssertNil(row.payload, "a local facet is state-based — nothing to remember")
        XCTAssertEqual(row.editType, .rotation)
        XCTAssertEqual(row.mediaKind, .image)
        XCTAssertEqual(row.retryCount, 0)
    }

    func testEnqueueRemoteOnlyRotationStoresDirection() async throws {
        let service = makeService()
        try await service.enqueuePendingRotation(localIdentifier: nil, immichID: "R1",
                                                  mediaKind: .image, clockwise: false)
        let row = try await database.writer().read { db in
            try PendingEditRecord.filter(sql: "immich_id = ? AND local_identifier IS NULL",
                                         arguments: ["R1"]).fetchOne(db)
        }
        let payload = try XCTUnwrap(row?.payload.flatMap(RotationPayload.init(jsonString:)))
        XCTAssertFalse(payload.clockwise)
    }

    /// Rotating the same asset twice while offline must not leave two queued edits — there is
    /// only ever one thing to reconcile per asset, however many times it was touched.
    func testReEnqueuingTheSameLocalAssetFoldsIntoOneRow() async throws {
        let service = makeService()
        try await service.enqueuePendingRotation(localIdentifier: "L1", immichID: "R1",
                                                  mediaKind: .image, clockwise: true)
        try await service.enqueuePendingRotation(localIdentifier: "L1", immichID: "R1",
                                                  mediaKind: .image, clockwise: false)
        XCTAssertEqual(try rowCount(), 1)
    }

    /// A retry that already failed once and is re-triggered by a fresh user action gets a clean
    /// slate — otherwise a transient failure from weeks ago could count toward today's bound.
    func testReEnqueuingResetsTheRetryClock() async throws {
        let service = makeService()
        try await service.enqueuePendingRotation(localIdentifier: "L1", immichID: "R1",
                                                  mediaKind: .image, clockwise: true)
        try await database.writer().write { db in
            try db.execute(sql: "UPDATE pending_edits SET retry_count = 3, last_error = 'boom' WHERE local_identifier = ?",
                           arguments: ["L1"])
        }
        try await service.enqueuePendingRotation(localIdentifier: "L1", immichID: "R1",
                                                  mediaKind: .image, clockwise: true)
        let row = try XCTUnwrap(try fetchRow(localIdentifier: "L1"))
        XCTAssertEqual(row.retryCount, 0)
        XCTAssertNil(row.lastError)
    }

    // MARK: - Retry (D22)

    /// The local asset no longer exists by the time the retry runs — the edit is moot, not an
    /// error, and clears without ever touching the network.
    func testRetryClearsALocalBackedEditWhoseAssetIsGone() async throws {
        let service = makeService()
        try await service.enqueuePendingRotation(localIdentifier: "does-not-exist-\(UUID())",
                                                  immichID: "R1", mediaKind: .image, clockwise: true)
        XCTAssertEqual(try rowCount(), 1)

        await service.retryPendingEdits()

        XCTAssertEqual(try rowCount(), 0, "a vanished local asset has nothing left to reconcile")
    }

    /// No signed-in session means every remote attempt fails the same deterministic way —
    /// enough to pin that a failure bumps the retry bookkeeping rather than silently vanishing.
    func testRetryBumpsRetryCountOnFailure() async throws {
        let service = makeService()
        try await service.enqueuePendingRotation(localIdentifier: nil, immichID: "R1",
                                                  mediaKind: .image, clockwise: true)

        await service.retryPendingEdits()

        let row = try await database.writer().read { db in
            try PendingEditRecord.filter(sql: "immich_id = ? AND local_identifier IS NULL",
                                         arguments: ["R1"]).fetchOne(db)
        }
        XCTAssertEqual(row?.retryCount, 1)
        XCTAssertNotNil(row?.lastError)
        XCTAssertEqual(try rowCount(), 1, "a failed retry stays queued, not dropped")
    }

    /// Once an edit has failed `maxEditRetries` times it is left alone rather than retried
    /// forever — mirrors `SyncEngine`'s bound for the upload queue.
    func testRetryLeavesExhaustedEditsAlone() async throws {
        let service = makeService()
        let deadIdentifier = "does-not-exist-\(UUID())"
        try await service.enqueuePendingRotation(localIdentifier: deadIdentifier, immichID: "R1",
                                                  mediaKind: .image, clockwise: true)
        try await database.writer().write { db in
            try db.execute(sql: "UPDATE pending_edits SET retry_count = 5 WHERE local_identifier = ?",
                           arguments: [deadIdentifier])
        }

        await service.retryPendingEdits()

        // If it had been attempted, the vanished-asset path above proves it would have cleared.
        // Still present means it was correctly skipped, not silently mishandled.
        XCTAssertEqual(try rowCount(), 1)
    }
}
