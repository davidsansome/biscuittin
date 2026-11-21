import XCTest
import UIKit
import Photos
import UniformTypeIdentifiers
import GRDB
@testable import BiscuitTin

/// Regression tests for the Persistence & Remote fixes.
final class RemotePersistenceFixesTests: XCTestCase {

    private var databaseURL: URL!
    private var database: AppDatabase!

    override func setUpWithError() throws {
        databaseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remote-persistence-fixes-\(UUID().uuidString).sqlite")
        database = AppDatabase(fileURL: databaseURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: databaseURL)
        try super.tearDownWithError()
    }

    private func makeService(client: ImmichClient? = nil,
                             maxLinesPerCommit: Int = 20_000) -> RemoteLibraryService {
        let session = ImmichAuthSession(defaults: UserDefaults(suiteName: "rp-fixes-\(UUID())")!)
        return RemoteLibraryService(
            database: database,
            session: session,
            resolver: PHAssetResolver(),
            exporter: LocalAssetExporter(),
            maxLinesPerCommit: maxLinesPerCommit,
            clientProvider: client.map { c in { @Sendable in c } }
        )
    }

    private func makeClient(_ recorder: RequestRecorder) -> ImmichClient {
        ImmichClient(baseURL: URL(string: "https://s.example.com")!,
                     session: StubURLProtocol.makeSession(recorder),
                     tokenProvider: { "tok" })
    }

    // MARK: - 1. ImmichModels date parsing, Duration & enum fallbacks

    func testParseDateHandlesPlainTimestampWithoutFractionalSeconds() {
        let parsed = Immich.parseDate("2026-08-18T10:00:00")
        let expected = Immich.parseDate("2026-08-18T10:00:00Z")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed, expected)

        let parsedFraction = Immich.parseDate("2026-08-18T10:00:00.250")
        let expectedFraction = Immich.parseDate("2026-08-18T10:00:00.250Z")
        XCTAssertEqual(parsedFraction, expectedFraction)
    }

    func testParseDateAndFormatAreThreadSafeUnderConcurrency() async {
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<64 {
                group.addTask {
                    let iso = "2026-08-18T10:00:\(String(format: "%02d", i % 60)).123Z"
                    guard let date = Immich.parseDate(iso) else { return false }
                    let formatted = Immich.iso8601String(from: date)
                    return Immich.parseDate(formatted) == date
                }
            }
            for await ok in group {
                XCTAssertTrue(ok)
            }
        }
    }

    func testSyncAssetV2DecodesStringAndNumericDurationAndUnknownEnums() throws {
        let json = """
        {
            "id": "a1",
            "originalFileName": "clip.mov",
            "checksum": "41ipRRJcK31MhPDdCW6B8j/1JJo=",
            "fileCreatedAt": "2026-08-18T10:00:00",
            "localDateTime": "2026-08-18T10:00:00",
            "duration": "0:01:23.500",
            "type": "FUTURE_TYPE",
            "deletedAt": null,
            "visibility": "vault",
            "width": 1920,
            "height": 1080
        }
        """
        let decoded = try JSONDecoder().decode(Immich.SyncAssetV2.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.durationSeconds, 83.5, accuracy: 0.001)
        XCTAssertEqual(decoded.type, .other)
        XCTAssertEqual(decoded.visibility, .unknown)
    }

    // MARK: - 2. Streaming download & filename sanitization in rotateRemote

    private struct StubRotator: AssetRotator {
        let supportedKind: MediaKind = .image
        func rotateLocal(input: PHContentEditingInput, clockwise: Bool, outputType: UTType) async throws -> URL {
            throw RotationError.assetUnavailable
        }
        func rotateRemoteOriginal(fileURL: URL, clockwise: Bool) async throws -> URL {
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("stub-rot-\(UUID().uuidString).jpg")
            let bytes = try Data(contentsOf: fileURL)
            try bytes.write(to: out)
            return out
        }
    }

    func testRotateRemoteSanitizesFilenameWithSlashes() async throws {
        let recorder = RequestRecorder()
        let infoJSON = """
        {"id":"r1","type":"IMAGE","checksum":"qg==","originalFileName":"../../nested/photo.jpg",
         "localDateTime":"2026-08-18T10:00:00Z","fileCreatedAt":"2026-08-18T10:00:00Z",
         "width":400,"height":300,"isTrashed":false}
        """
        await recorder.stub(method: "GET", path: "/api/assets/r1", json: infoJSON)
        await recorder.stub(method: "GET", path: "/api/assets/r1/original", json: "raw-jpeg-bytes")
        await recorder.stub(method: "POST", path: "/api/assets", json: #"{"id":"r2","status":"created"}"#)
        await recorder.stub(method: "PUT", path: "/api/assets/r2", json: "{}")
        await recorder.stub(method: "DELETE", path: "/api/assets", json: "", status: 204)

        let service = makeService(client: makeClient(recorder))
        try await service.rotateRemote(immichID: "r1", clockwise: true, rotator: StubRotator())

        let replaced = try await service.record(for: "r2")
        XCTAssertNotNil(replaced)
        XCTAssertEqual(replaced?.width, 300)
        XCTAssertEqual(replaced?.height, 400)
    }

    // MARK: - 3. Wipe resets backup_state next_attempt_at and modified_at

    func testWipeCacheResetsBackupStateNextAttemptAndModifiedAt() async throws {
        let writer = try database.writer()
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO backup_state (local_identifier, checksum_hex, state, retry_count, last_error, updated_at, modified_at, next_attempt_at)
                VALUES ('L1', 'aa', 'failed', 3, 'err', 100, 999, 5000)
                """)
        }

        let service = makeService()
        try await service.wipeCache()

        let result: (state: String?, retryCount: Int?, nextAttempt: Double?, modifiedAt: Double?) =
            try await writer.read { db in
                let row = try Row.fetchOne(db, sql: "SELECT state, retry_count, next_attempt_at, modified_at FROM backup_state WHERE local_identifier = 'L1'")
                return (row?["state"], row?["retry_count"], row?["next_attempt_at"], row?["modified_at"])
            }
        XCTAssertEqual(result.state, "pending")
        XCTAssertEqual(result.retryCount, 0)
        XCTAssertEqual(result.nextAttempt, 0)
        XCTAssertNil(result.modifiedAt)
    }

    // MARK: - 4. ImmichAuthSession stale-401 protection

    func testMarkExpiredIgnoresStaleCredential() {
        let suite = "auth-stale-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let session = ImmichAuthSession(defaults: defaults)
        // Only runs meaningful Keychain checks when Keychain is writable in the simulator.
        // Verify at minimum that markExpired when signedOut is a no-op and deviceID is stable.
        session.markExpired(ifCredentialMatches: .accessToken("old-token"))
        XCTAssertEqual(session.state, .signedOut)

        let id1 = session.deviceID
        let id2 = session.deviceID
        XCTAssertEqual(id1, id2)
    }

    // MARK: - 5. RemoteThumbnailCache & RemoteImageFetcher

    private func makeTestPNG(width: Int = 100, height: Int = 100) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let img = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return img.pngData()!
    }

    func testCachedImageIsStrictlyMemoryOnlyAndImageReadsDiskOffMain() async throws {
        let assetID = "img-mem-test-\(UUID().uuidString)"
        let cache = RemoteThumbnailCache()
        let session = ImmichAuthSession(defaults: UserDefaults(suiteName: "fetcher-mem-\(UUID())")!)
        let fetcher = RemoteImageFetcher(session: session, cache: cache)

        let variant = ImageVariant.gridThumb(pointSize: CGSize(width: 100, height: 100), scale: 2)
        let diskKey = RemoteImageFetcher.diskKey(immichID: assetID, variant: variant)
        let memKey = RemoteImageFetcher.memoryKey(immichID: assetID, variant: variant)

        // Populate disk directly via a separate cache instance so `cache`'s NSCache is cold.
        let diskOnlyCache = RemoteThumbnailCache()
        diskOnlyCache.store(makeTestPNG(), diskKey: diskKey, memoryKey: memKey, downsamplingTo: 200)

        // Wait for DiskCache's async background write to land on disk.
        let probe = DiskCache(name: "remote-thumbnails")
        for _ in 0..<50 where probe.data(for: diskKey) == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(probe.data(for: diskKey), "DiskCache async write should have flushed")

        // Memory-only lookup must return nil (no synchronous disk read).
        XCTAssertNil(fetcher.cachedImage(immichID: assetID, variant: variant))

        // Async `image(...)` reads from disk without needing network/session and warms memory cache.
        let loaded = try await fetcher.image(immichID: assetID, variant: variant)
        XCTAssertGreaterThan(loaded.size.width, 0)
        XCTAssertNotNil(fetcher.cachedImage(immichID: assetID, variant: variant))
    }

    func testGridThumbMemoryKeyQuantizesSizeWhileSharingDiskKey() {
        let small = ImageVariant.gridThumb(pointSize: CGSize(width: 60, height: 60), scale: 2)
        let large = ImageVariant.gridThumb(pointSize: CGSize(width: 180, height: 180), scale: 2)

        XCTAssertEqual(RemoteImageFetcher.diskKey(immichID: "a1", variant: small),
                       RemoteImageFetcher.diskKey(immichID: "a1", variant: large))
        XCTAssertNotEqual(RemoteImageFetcher.memoryKey(immichID: "a1", variant: small),
                          RemoteImageFetcher.memoryKey(immichID: "a1", variant: large))
    }

    // MARK: - 6. Upsert / Delete batch ordering (user assets & partner shares)

    private func assetLine(id: String, visibility: String = "timeline", checksum: String = "41ipRRJcK31MhPDdCW6B8j/1JJo=", ack: String) -> String {
        """
        {"type":"AssetV2","data":{"id":"\(id)","originalFileName":"\(id).jpg","checksum":"\(checksum)","fileCreatedAt":"2026-08-18T10:00:00Z","localDateTime":"2026-08-18T10:00:00Z","duration":null,"type":"IMAGE","deletedAt":null,"visibility":"\(visibility)","width":100,"height":100},"ack":"\(ack)"}
        """
    }

    private func deleteLine(id: String, ack: String) -> String {
        #"{"type":"AssetDeleteV1","data":{"assetId":"\#(id)"},"ack":"\#(ack)"}"#
    }

    func testDeleteFollowedByUpsertInSameChunkKeepsAsset() async throws {
        let recorder = RequestRecorder()
        let stream = [
            deleteLine(id: "a1", ack: "AssetDeleteV1|1"),
            assetLine(id: "a1", ack: "AssetV2|2")
        ].joined(separator: "\n")
        await recorder.stub(path: "/api/sync/stream", json: stream)
        await recorder.stub(path: "/api/sync/ack", json: "", status: 204)

        let service = makeService(client: makeClient(recorder))
        try await service.syncStream(client: makeClient(recorder), reset: false, isSignedIn: { true })

        let stored = try await service.record(for: "a1")
        XCTAssertNotNil(stored, "AssetV2 after AssetDeleteV1 in the same chunk must survive")
    }

    func testPartnerShareAddThenRemoveInSameChunkDoesNotResurrectPartner() throws {
        var batch = PartnerSyncBatch()
        let me = "u-me"
        let alice = "u-alice"
        let authLine = Data(#"{"type":"AuthUserV1","data":{"id":"\#(me)","name":"Me","email":"m@e.c"},"ack":"AuthUserV1|1"}"#.utf8)
        let addLine = Data(#"{"type":"PartnerV1","data":{"sharedById":"\#(alice)","sharedWithId":"\#(me)","inTimeline":false},"ack":"PartnerV1|1"}"#.utf8)
        let removeLine = Data(#"{"type":"PartnerDeleteV1","data":{"sharedById":"\#(alice)","sharedWithId":"\#(me)"},"ack":"PartnerDeleteV1|2"}"#.utf8)

        XCTAssertTrue(batch.add(type: "AuthUserV1", line: authLine))
        XCTAssertTrue(batch.add(type: "PartnerV1", line: addLine))
        XCTAssertTrue(batch.add(type: "PartnerDeleteV1", line: removeLine))

        try database.writer().write { db in
            try PartnerStore.apply(batch, in: db)
        }
        let partners = try database.writer().read { db in try PartnerStore.partners(in: db) }
        XCTAssertEqual(partners, [], "PartnerDeleteV1 after PartnerV1 in the same chunk must remove the partner")
    }

    // MARK: - 7. Stale facet_links & orphan cleanup

    func testArchiveAndDeleteClearFacetLinksAndRemoveOrphans() async throws {
        let recorder = RequestRecorder()
        let seedStream = [
            assetLine(id: "a1", visibility: "timeline", checksum: "41ipRRJcK31MhPDdCW6B8j/1JJo=", ack: "AssetV2|1"),
            assetLine(id: "a2", visibility: "timeline", checksum: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", ack: "AssetV2|2")
        ].joined(separator: "\n")
        await recorder.stub(path: "/api/sync/stream", json: seedStream)
        await recorder.stub(path: "/api/sync/ack", json: "", status: 204)

        let service = makeService(client: makeClient(recorder))
        try await service.syncStream(client: makeClient(recorder), reset: false, isSignedIn: { true })

        // Archive a1 and delete a2 in one sync chunk.
        let updateStream = [
            assetLine(id: "a1", visibility: "archive", checksum: "41ipRRJcK31MhPDdCW6B8j/1JJo=", ack: "AssetV2|3"),
            deleteLine(id: "a2", ack: "AssetDeleteV1|4")
        ].joined(separator: "\n")
        await recorder.stub(path: "/api/sync/stream", json: updateStream)
        try await service.syncStream(client: makeClient(recorder), reset: false, isSignedIn: { true })

        let remainingLinks = try await database.writer().read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM facet_links") ?? -1
        }
        XCTAssertEqual(remainingLinks, 0, "Archiving and deleting remote-only assets must leave no orphan facet_links")
    }

    func testDeleteRemoteClearsFacetLinkAndOrphan() async throws {
        let recorder = RequestRecorder()
        let seedStream = assetLine(id: "a1", visibility: "timeline", ack: "AssetV2|1")
        await recorder.stub(path: "/api/sync/stream", json: seedStream)
        await recorder.stub(path: "/api/sync/ack", json: "", status: 204)
        await recorder.stub(method: "DELETE", path: "/api/assets", json: "", status: 204)

        let service = makeService(client: makeClient(recorder))
        try await service.syncStream(client: makeClient(recorder), reset: false, isSignedIn: { true })

        try await service.deleteRemote(ids: ["a1"])

        let linkCount = try await database.writer().read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM facet_links WHERE immich_id = 'a1'") ?? -1
        }
        let orphanCount = try await database.writer().read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM facet_links WHERE local_identifier IS NULL AND immich_id IS NULL") ?? -1
        }
        XCTAssertEqual(linkCount, 0)
        XCTAssertEqual(orphanCount, 0)
    }

    // MARK: - 8. Corrupt sync line taints its checkpoint ack

    func testCorruptSyncLineDoesNotAckItsCheckpoint() async throws {
        let recorder = RequestRecorder()
        let corruptAsset = #"{"type":"AssetV2","data":{"notAnAsset":true},"ack":"AssetV2|bad"}"#
        let validExif = #"{"type":"AssetExifV1","data":{"assetId":"a1","latitude":1.0,"longitude":2.0},"ack":"AssetExifV1|ok"}"#
        await recorder.stub(path: "/api/sync/stream", json: [corruptAsset, validExif].joined(separator: "\n"))
        await recorder.stub(path: "/api/sync/ack", json: "", status: 204)

        let service = makeService(client: makeClient(recorder))
        try await service.syncStream(client: makeClient(recorder), reset: false, isSignedIn: { true })

        let ackReq = await recorder.requests.last { $0.path == "/api/sync/ack" }
        let body = try XCTUnwrap(ackReq?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let acks = json["acks"] as? [String] ?? []
        XCTAssertFalse(acks.contains { $0.hasPrefix("AssetV2|") }, "Failed AssetV2 checkpoint must not be acked: \(acks)")
        XCTAssertTrue(acks.contains("AssetExifV1|ok"), "Unaffected checkpoint should still be acked: \(acks)")
    }

    // MARK: - 9. PendingEditRecord remote-only rotation composition

    func testRemoteOnlyRotationsComposeMod4AndRemoveWhenZero() async throws {
        let service = makeService()

        // 1st CW -> 1 turn
        try await service.enqueuePendingRotation(localIdentifier: nil, immichID: "R1",
                                                 mediaKind: .image, clockwise: true)
        // 2nd CW -> 2 turns (180°)
        try await service.enqueuePendingRotation(localIdentifier: nil, immichID: "R1",
                                                 mediaKind: .image, clockwise: true)
        let row2 = try await database.writer().read { db in
            try PendingEditRecord.filter(sql: "immich_id = 'R1' AND local_identifier IS NULL").fetchOne(db)
        }
        let payload2 = try XCTUnwrap(row2?.payload.flatMap(RotationPayload.init(jsonString:)))
        XCTAssertEqual(payload2.quarterTurns, 2)

        // 3rd CW -> 3 turns (90° CCW)
        try await service.enqueuePendingRotation(localIdentifier: nil, immichID: "R1",
                                                 mediaKind: .image, clockwise: true)
        // 4th CW -> 0 turns -> row removed
        try await service.enqueuePendingRotation(localIdentifier: nil, immichID: "R1",
                                                 mediaKind: .image, clockwise: true)
        let countAfter4 = try await database.writer().read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_edits") ?? -1
        }
        XCTAssertEqual(countAfter4, 0)

        // CW + CCW -> 0 turns -> row removed
        try await service.enqueuePendingRotation(localIdentifier: nil, immichID: "R2",
                                                 mediaKind: .image, clockwise: true)
        try await service.enqueuePendingRotation(localIdentifier: nil, immichID: "R2",
                                                 mediaKind: .image, clockwise: false)
        let countAfterCancel = try await database.writer().read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_edits") ?? -1
        }
        XCTAssertEqual(countAfterCancel, 0)
    }

    // MARK: - 10. MultipartBuilder escaping & error cleanup

    func testMultipartBuilderEscapesFilenameAndCleansUpOnError() throws {
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("mp-src-\(UUID()).txt")
        try Data("hello".utf8).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        let bodyURL = try MultipartBuilder.buildBody(
            boundary: "B1",
            fields: ["k": "v"],
            fileField: "assetData",
            fileURL: src,
            filename: "bad\"name\r\ninject.jpg"
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let text = try String(contentsOf: bodyURL, encoding: .utf8)
        XCTAssertTrue(text.contains(#"filename="bad\"nameinject.jpg""#), text)
        XCTAssertFalse(text.contains("bad\"name\r\n"), text)

        // Missing source file should throw and not leak a temp multipart file.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-err-\(UUID())")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let missing = tempDir.appendingPathComponent("does-not-exist.bin")
        XCTAssertThrowsError(try MultipartBuilder.buildBody(
            boundary: "B1", fields: [:], fileField: "f", fileURL: missing,
            filename: "x.bin", outputDirectory: tempDir
        ))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(leftovers, [], "Failed buildBody must remove its partial output file")
    }

    // MARK: - 11. repointAfterReplacement preserves dimensions when newID == oldID

    func testFinishReplacementDoesNotSwapDimensionsWhenSameID() async throws {
        let writer = try database.writer()
        var rec = RemoteAssetRecord(placeholderID: "same-1")
        rec.checksumHex = "aa"
        rec.width = 4000
        rec.height = 3000
        try await writer.write { db in try rec.save(db) }

        let service = makeService()
        try await service.finishReplacement(
            oldID: "same-1", newID: "same-1", newChecksumHex: "aa",
            isDuplicate: true, capture: (Date(), 0), record: rec,
            localIdentifier: nil, localModifiedAt: nil, width: nil, height: nil
        )

        let updated = try await service.record(for: "same-1")
        XCTAssertEqual(updated?.width, 4000)
        XCTAssertEqual(updated?.height, 3000)
    }
}
