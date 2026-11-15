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

    private func makeService(client: ImmichClient) -> RemoteLibraryService {
        RemoteLibraryService(database: database,
                             session: ImmichAuthSession(defaults: UserDefaults(suiteName: "pending-edit-tests-\(UUID())")!),
                             resolver: PHAssetResolver(),
                             exporter: LocalAssetExporter(),
                             clientProvider: { client })
    }

    private func stubClient(_ recorder: RequestRecorder) -> ImmichClient {
        ImmichClient(baseURL: URL(string: "https://s.example.com")!,
                     session: StubURLProtocol.makeSession(recorder),
                     tokenProvider: { "tok" })
    }

    private func remoteOnlyRow() async throws -> PendingEditRecord? {
        try await database.writer().read { db in
            try PendingEditRecord.filter(sql: "immich_id = ? AND local_identifier IS NULL",
                                         arguments: ["R1"]).fetchOne(db)
        }
    }

    /// A failure that is the edit's own fault is counted and waits before it is tried again.
    func testRetryBumpsRetryCountOnFailure() async throws {
        let recorder = RequestRecorder()
        await recorder.stub(path: "/api/assets/R1", json: "{}", status: 400)
        let service = makeService(client: stubClient(recorder))
        try await service.enqueuePendingRotation(localIdentifier: nil, immichID: "R1",
                                                  mediaKind: .image, clockwise: true)

        let before = Date().timeIntervalSince1970
        await service.retryPendingEdits()

        let row = try await remoteOnlyRow()
        XCTAssertEqual(row?.retryCount, 1)
        XCTAssertNotNil(row?.lastError)
        XCTAssertEqual(try XCTUnwrap(row?.nextAttemptAt) - before, 60, accuracy: 5)
        XCTAssertEqual(try rowCount(), 1, "a failed retry stays queued, not dropped")

        let requestsAfterFirst = await recorder.requests.count
        await service.retryPendingEdits()
        let requestsAfterSecond = await recorder.requests.count
        XCTAssertEqual(requestsAfterSecond, requestsAfterFirst, "an edit that is not due is not tried")
    }

    /// No network is not the edit's fault, so it costs the edit nothing.
    func testTransportFailureIsNotCounted() async throws {
        // Nothing listens on port 1, so the connection is refused.
        let client = ImmichClient(baseURL: URL(string: "http://127.0.0.1:1")!, tokenProvider: { "tok" })
        let service = makeService(client: client)
        try await service.enqueuePendingRotation(localIdentifier: nil, immichID: "R1",
                                                  mediaKind: .image, clockwise: true)

        await service.retryPendingEdits()

        let row = try await remoteOnlyRow()
        XCTAssertEqual(row?.retryCount, 0)
        XCTAssertEqual(row?.nextAttemptAt, 0)
    }

    /// Nothing is abandoned: an edit waits until it is due, then is tried however often it
    /// has failed before.
    func testRetryWaitsForNextAttemptAt() async throws {
        let service = makeService()
        let deadIdentifier = "does-not-exist-\(UUID())"
        try await service.enqueuePendingRotation(localIdentifier: deadIdentifier, immichID: "R1",
                                                  mediaKind: .image, clockwise: true)
        try await database.writer().write { db in
            try db.execute(sql: "UPDATE pending_edits SET retry_count = 9, next_attempt_at = ? WHERE local_identifier = ?",
                           arguments: [Date().timeIntervalSince1970 + 3600, deadIdentifier])
        }

        await service.retryPendingEdits()
        // If it had been attempted, the vanished-asset path above proves it would have cleared.
        XCTAssertEqual(try rowCount(), 1)

        try await database.writer().write { db in
            try db.execute(sql: "UPDATE pending_edits SET next_attempt_at = ? WHERE local_identifier = ?",
                           arguments: [Date().timeIntervalSince1970 - 1, deadIdentifier])
        }
        await service.retryPendingEdits()
        XCTAssertEqual(try rowCount(), 0)
    }

    // MARK: - Unfinished replacements (D22)

    private func stubFinishingReplacement(_ recorder: RequestRecorder) async {
        let asset = { (id: String) in """
            {"id":"\(id)","type":"IMAGE","checksum":"qg==","originalFileName":"IMG_1.HEIC",
             "localDateTime":"2026-08-18T10:00:00.000Z","fileCreatedAt":"2026-08-17T23:00:00.000Z",
             "width":400,"height":300,"duration":"0:00:00.00000","isTrashed":false}
            """ }
        await recorder.stub(method: "GET", path: "/api/assets/R1", json: asset("R1"))
        await recorder.stub(method: "GET", path: "/api/assets/N1", json: asset("N1"))
        await recorder.stub(method: "PUT", path: "/api/assets/N1", json: "{}")
        await recorder.stub(method: "DELETE", path: "/api/assets", json: "", status: 204)
    }

    func testRetryFinishesAnUploadedReplacementWithoutUploadingAgain() async throws {
        let recorder = RequestRecorder()
        await stubFinishingReplacement(recorder)
        let service = makeService(client: stubClient(recorder))
        try await service.enqueuePendingRotation(localIdentifier: nil, immichID: "R1", mediaKind: .image,
                                                  clockwise: true, uploadedID: "N1", uploadedChecksum: "bb")

        await service.retryPendingEdits()

        let log = await recorder.log
        XCTAssertFalse(log.contains("POST /api/assets"), "\(log)")
        XCTAssertFalse(log.contains { $0.hasSuffix("/original") }, "\(log)")
        XCTAssertTrue(log.contains("DELETE /api/assets"), "\(log)")
        let requests = await recorder.requests
        let delete = try XCTUnwrap(requests.first { $0.method == "DELETE" }?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: delete) as? [String: Any])
        XCTAssertEqual(json["ids"] as? [String], ["R1"])
        XCTAssertEqual(try rowCount(), 0)
    }

    func testConcurrentDrainsSendEachRequestOnce() async throws {
        let recorder = RequestRecorder()
        await stubFinishingReplacement(recorder)
        let service = makeService(client: stubClient(recorder))
        try await service.enqueuePendingRotation(localIdentifier: nil, immichID: "R1", mediaKind: .image,
                                                  clockwise: true, uploadedID: "N1", uploadedChecksum: "bb")

        async let first: Void = service.retryPendingEdits()
        async let second: Void = service.retryPendingEdits()
        _ = await (first, second)

        let log = await recorder.log
        XCTAssertEqual(log.filter { $0 == "DELETE /api/assets" }.count, 1, "\(log)")
        XCTAssertEqual(log.filter { $0 == "PUT /api/assets/N1" }.count, 1, "\(log)")
    }
}
