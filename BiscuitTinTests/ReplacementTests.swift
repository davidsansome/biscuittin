import XCTest
import GRDB
@testable import BiscuitTin

/// Replacing a server asset's file: upload the new bytes, retire the old asset, re-key the link.
final class ReplacementTests: XCTestCase {

    private var databaseURL: URL!
    private var database: AppDatabase!
    private var renditionURL: URL!
    private var renditionSha: String!
    private var recorder: RequestRecorder!

    override func setUpWithError() throws {
        databaseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("replacement-\(UUID().uuidString).sqlite")
        database = AppDatabase(fileURL: databaseURL)
        renditionURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rendition-\(UUID().uuidString).jpg")
        try Data("rotated bytes \(UUID())".utf8).write(to: renditionURL)
        renditionSha = try ImmichClient.sha1Hex(ofFileAt: renditionURL)
        recorder = RequestRecorder()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: databaseURL)
        try? FileManager.default.removeItem(at: renditionURL)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeClient() -> ImmichClient {
        ImmichClient(baseURL: URL(string: "https://s.example.com")!,
                     session: StubURLProtocol.makeSession(recorder),
                     tokenProvider: { "tok" })
    }

    private func makeService() -> RemoteLibraryService {
        let client = makeClient()
        return RemoteLibraryService(
            database: database,
            session: ImmichAuthSession(defaults: UserDefaults(suiteName: "replacement-tests-\(UUID())")!),
            resolver: PHAssetResolver(),
            exporter: LocalAssetExporter(),
            clientProvider: { client })
    }

    private static let fileCreatedAt = "2026-08-17T23:00:00.000Z"
    private static let localDateTime = "2026-08-18T10:00:00.000Z"

    private static func assetJSON(id: String, isTrashed: Bool = false) -> String {
        """
        {"id":"\(id)","type":"IMAGE","checksum":"qg==","originalFileName":"IMG_1.HEIC",
         "localDateTime":"\(localDateTime)","fileCreatedAt":"\(fileCreatedAt)",
         "width":400,"height":300,"duration":"0:00:00.00000","isTrashed":\(isTrashed)}
        """
    }

    private func stubHappyPath(uploadJSON: String = #"{"id":"new","status":"created"}"#) async {
        await recorder.stub(method: "GET", path: "/api/assets/old", json: Self.assetJSON(id: "old"))
        await recorder.stub(method: "POST", path: "/api/assets", json: uploadJSON, status: 201)
        await recorder.stub(method: "PUT", path: "/api/assets/new", json: "{}")
        await recorder.stub(method: "DELETE", path: "/api/assets", json: "", status: 204)
    }

    private func seed(backupState: Bool = true) async throws -> RemoteAssetRecord {
        var record = RemoteAssetRecord(placeholderID: "old")
        record.checksumHex = "aa"
        record.fileName = "IMG_1.HEIC"
        record.width = 400
        record.height = 300
        record.captureAt = try XCTUnwrap(Immich.parseDate(Self.localDateTime)).timeIntervalSince1970
        let seeded = record
        try await database.writer().write { db in
            try seeded.insert(db)
            try db.execute(sql: "INSERT INTO facet_links (checksum_hex, local_identifier, immich_id) VALUES ('aa', 'L1', 'old')")
            if backupState {
                try BackupStateRecord(localIdentifier: "L1", checksumHex: "aa", state: .uploaded).insert(db)
            }
        }
        return seeded
    }

    private func linkRows() async throws -> [[String?]] {
        try await database.writer().read { db in
            try Row.fetchAll(db, sql: "SELECT checksum_hex, local_identifier, immich_id FROM facet_links ORDER BY checksum_hex")
                .map { [$0["checksum_hex"], $0["local_identifier"], $0["immich_id"]] }
        }
    }

    private func remoteIDs() async throws -> [String] {
        try await database.writer().read { db in
            try String.fetchAll(db, sql: "SELECT immich_id FROM remote_assets ORDER BY immich_id")
        }
    }

    private func backupRow() async throws -> BackupStateRecord? {
        try await database.writer().read { db in try BackupStateRecord.fetchOne(db, key: "L1") }
    }

    private func replace(_ service: RemoteLibraryService, record: RemoteAssetRecord,
                         localIdentifier: String?) async throws {
        try await service.replaceRemoteFile(oldID: "old", fileURL: renditionURL,
                                            exportedFilename: "FullSizeRender.jpg", record: record,
                                            localIdentifier: localIdentifier,
                                            localModifiedAt: Date(timeIntervalSince1970: 1_000),
                                            width: 300, height: 400)
    }

    private static func base64(hex: String) -> String {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return Data(bytes).base64EncodedString()
    }

    private static func syncLine(id: String, checksum: String, deletedAt: String?) -> String {
        let deleted = deletedAt.map { "\"\($0)\"" } ?? "null"
        return """
            {"type":"AssetV2","ack":"AssetV2|\(id)","data":{"id":"\(id)","originalFileName":"x.jpg",\
            "checksum":"\(checksum)","fileCreatedAt":"2026-08-18T10:00:00.000Z","fileModifiedAt":null,\
            "localDateTime":"2026-08-18T10:00:00.000Z","duration":null,"type":"IMAGE",\
            "deletedAt":\(deleted),"visibility":"timeline","livePhotoVideoId":null,"width":100,"height":100}}
            """
    }

    private func sync(_ service: RemoteLibraryService, reset: Bool, lines: [String]) async throws {
        await recorder.enqueue(path: "/api/sync/stream", json: (lines + [
            #"{"type":"SyncCompleteV1","ack":"SyncCompleteV1|0003","data":{}}"#,
        ]).joined(separator: "\n"))
        await recorder.stub(path: "/api/sync/ack", json: "", status: 204)
        try await service.syncStream(client: makeClient(), reset: reset, isSignedIn: { true })
    }

    private func multipartField(_ name: String, in body: Data) -> String? {
        let text = String(decoding: body, as: UTF8.self)
        guard let range = text.range(of: "name=\"\(name)\"\r\n\r\n") else { return nil }
        return text[range.upperBound...].components(separatedBy: "\r\n").first
    }

    // MARK: - Pure functions

    func testCaptureTimeRecoversTheOffset() throws {
        let fallback = Date(timeIntervalSince1970: 0)
        let instant = try XCTUnwrap(Immich.parseDate(Self.fileCreatedAt))
        let capture = ReplacementPlan.captureTime(fileCreatedAt: Self.fileCreatedAt,
                                                  localDateTime: Self.localDateTime, fallback: fallback)
        XCTAssertEqual(capture.instant, instant)
        XCTAssertEqual(capture.offsetSeconds, 39_600)

        XCTAssertEqual(ReplacementPlan.captureTime(fileCreatedAt: Self.fileCreatedAt, localDateTime: nil,
                                                   fallback: fallback).offsetSeconds, 0)
        XCTAssertEqual(ReplacementPlan.captureTime(fileCreatedAt: Self.fileCreatedAt,
                                                   localDateTime: "2026-08-18T19:00:00.000Z",
                                                   fallback: fallback).offsetSeconds, 0,
                       "20 hours is no real zone")
        XCTAssertEqual(ReplacementPlan.captureTime(fileCreatedAt: nil, localDateTime: Self.localDateTime,
                                                   fallback: fallback).instant, fallback)
    }

    func testISO8601WithOffset() throws {
        let instant = try XCTUnwrap(Immich.parseDate(Self.fileCreatedAt))
        XCTAssertEqual(Immich.iso8601String(from: instant, offsetSeconds: 39_600), "2026-08-18T10:00:00.000+11:00")
        let utc = Immich.iso8601String(from: instant, offsetSeconds: 0)
        XCTAssertEqual(utc, "2026-08-17T23:00:00.000Z")
        XCTAssertEqual(Immich.parseDate(utc), instant)
        XCTAssertEqual(Immich.parseDate("2026-08-18T10:00:00.000+11:00"), instant)
    }

    func testFilenameKeepsTheServerNameWithTheRenditionsExtension() {
        XCTAssertEqual(ReplacementPlan.filename(serverName: "IMG_1.HEIC", exportedName: "FullSizeRender.jpg"), "IMG_1.jpg")
        XCTAssertEqual(ReplacementPlan.filename(serverName: nil, exportedName: "a.jpg"), "a.jpg")
        XCTAssertEqual(ReplacementPlan.filename(serverName: "IMG_1.HEIC", exportedName: "noext"), "IMG_1.HEIC")
    }

    // MARK: - replaceRemoteFile

    func testReplacementRekeysTheLinkAndKeepsTheCaptureTime() async throws {
        await stubHappyPath()
        let record = try await seed()
        let service = makeService()

        try await replace(service, record: record, localIdentifier: "L1")

        let links = try await linkRows()
        XCTAssertEqual(links, [[renditionSha, "L1", "new"]])
        let backup = try await backupRow()
        XCTAssertEqual(backup?.checksumHex, renditionSha)
        XCTAssertEqual(backup?.modifiedAt, 1_000)
        let ids = try await remoteIDs()
        XCTAssertEqual(ids, ["new"])

        let requests = await recorder.requests
        let put = try XCTUnwrap(requests.first { $0.method == "PUT" }?.body)
        let putJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: put) as? [String: String])
        XCTAssertEqual(putJSON["dateTimeOriginal"], "2026-08-18T10:00:00.000+11:00")

        let upload = try XCTUnwrap(requests.first { $0.method == "POST" && $0.path == "/api/assets" }?.body,
                                   "the multipart body should reach the stub")
        XCTAssertEqual(multipartField("fileCreatedAt", in: upload), Self.fileCreatedAt)
        XCTAssertEqual(multipartField("filename", in: upload), "IMG_1.jpg")

        let delete = try XCTUnwrap(requests.first { $0.method == "DELETE" }?.body)
        let deleteJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: delete) as? [String: Any])
        XCTAssertEqual(deleteJSON["ids"] as? [String], ["old"])
    }

    /// D-C: the link must survive the sync that reports both assets, and a full replay.
    func testReplacementLinkSurvivesSyncAndReplay() async throws {
        try await testReplacementRekeysTheLinkAndKeepsTheCaptureTime()
        let service = makeService()
        let newChecksum = Self.base64(hex: renditionSha)

        try await sync(service, reset: false, lines: [
            Self.syncLine(id: "old", checksum: "qg==", deletedAt: "2026-08-19T10:00:00.000Z"),
            Self.syncLine(id: "new", checksum: newChecksum, deletedAt: nil),
        ])
        var links = try await service.links()
        XCTAssertEqual(links, ["new": "L1"])

        try await sync(service, reset: true, lines: [Self.syncLine(id: "new", checksum: newChecksum, deletedAt: nil)])
        links = try await service.links()
        XCTAssertEqual(links, ["new": "L1"])
    }

    func testFailedDeleteReportsTheUploadAndChangesNothing() async throws {
        await stubHappyPath()
        await recorder.stub(method: "DELETE", path: "/api/assets", json: "{}", status: 500)
        let record = try await seed()
        let service = makeService()
        let linksBefore = try await linkRows()
        let backupBefore = try await backupRow()

        do {
            try await replace(service, record: record, localIdentifier: "L1")
            XCTFail("expected ReplacementIncomplete")
        } catch let incomplete as ReplacementIncomplete {
            XCTAssertEqual(incomplete.newID, "new")
            XCTAssertEqual(incomplete.newChecksumHex, renditionSha)
        }

        let linksAfter = try await linkRows()
        XCTAssertEqual(linksAfter, linksBefore)
        let backupAfter = try await backupRow()
        XCTAssertEqual(backupAfter, backupBefore)
        let ids = try await remoteIDs()
        XCTAssertEqual(ids, ["old"])
    }

    func testDuplicateOfTheSameAssetSendsNothingMore() async throws {
        await stubHappyPath(uploadJSON: #"{"id":"old","status":"duplicate"}"#)
        let record = try await seed()
        let service = makeService()

        try await replace(service, record: record, localIdentifier: "L1")

        let log = await recorder.log
        XCTAssertFalse(log.contains { $0.hasPrefix("PUT ") }, "\(log)")
        XCTAssertFalse(log.contains("DELETE /api/assets"), "\(log)")
        let links = try await linkRows()
        XCTAssertEqual(links, [[renditionSha, "L1", "old"]])
    }

    func testDuplicateInTheTrashIsRestoredBeforeTheOldAssetIsDeleted() async throws {
        await stubHappyPath(uploadJSON: #"{"id":"t1","status":"duplicate"}"#)
        await recorder.stub(method: "GET", path: "/api/assets/t1", json: Self.assetJSON(id: "t1", isTrashed: true))
        await recorder.stub(method: "PUT", path: "/api/assets/t1", json: "{}")
        await recorder.stub(method: "POST", path: "/api/trash/restore/assets", json: "", status: 204)
        let record = try await seed()
        let service = makeService()

        try await replace(service, record: record, localIdentifier: "L1")

        let log = await recorder.log
        let restore = try XCTUnwrap(log.firstIndex(of: "POST /api/trash/restore/assets"), "\(log)")
        let delete = try XCTUnwrap(log.firstIndex(of: "DELETE /api/assets"), "\(log)")
        XCTAssertLessThan(restore, delete)
        let requests = await recorder.requests
        let body = try XCTUnwrap(requests[restore].body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["ids"] as? [String], ["t1"])
    }

    /// After Free Up Space the link row still names the deleted local photo. A rotation then
    /// runs on the server's own download, whose checksum backup_state must not take.
    func testRemoteOnlyReplacementMovesTheLinkButNotBackupState() async throws {
        await stubHappyPath()
        let record = try await seed()
        let service = makeService()
        let backupBefore = try await backupRow()

        try await replace(service, record: record, localIdentifier: nil)

        let links = try await linkRows()
        XCTAssertEqual(links, [[renditionSha, "L1", "new"]])
        let backupAfter = try await backupRow()
        XCTAssertEqual(backupAfter, backupBefore)
    }
}
