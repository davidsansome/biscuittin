import XCTest
import GRDB
@testable import BiscuitTin

/// Partner sharing (§22): the partner lines of a `sync/stream` batch, how they land in the
/// partner tables, and the ack bookkeeping that partner backfills depend on.
///
/// Line shapes follow the v3.2.4 server's `sync.service.ts` and OpenAPI spec: payloads are the
/// same DTOs as the user's own lines (`SyncAssetV2`, `SyncAssetExifV1`), backfill lines carry a
/// three-part ack, and a `SyncAckV1` line closes each partner's backfill.
final class PartnerSharingTests: XCTestCase {

    private var databaseURL: URL!
    private var database: AppDatabase!

    private let me = "0199a000-0000-7000-8000-000000000001"
    private let alice = "0199a000-0000-7000-8000-00000000000a"
    private let bob = "0199a000-0000-7000-8000-00000000000b"

    override func setUpWithError() throws {
        databaseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("partners-\(UUID().uuidString).sqlite")
        database = AppDatabase(fileURL: databaseURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: databaseURL)
        try super.tearDownWithError()
    }

    // MARK: - Line builders

    private func line(_ type: String, _ data: String, ack: String? = nil) -> (String, Data) {
        (type, Data(#"{"type":"\#(type)","data":\#(data),"ack":"\#(ack ?? "\(type)|x")"}"#.utf8))
    }

    private func user(_ type: String = "UserV1", id: String, name: String, email: String) -> (String, Data) {
        line(type, """
            {"id":"\(id)","name":"\(name)","email":"\(email)","avatarColor":null,"deletedAt":null,
             "hasProfileImage":false,"profileChangedAt":"2026-01-01T00:00:00.000Z"}
            """)
    }

    private func share(by: String, with: String, inTimeline: Bool = false) -> (String, Data) {
        line("PartnerV1", #"{"sharedById":"\#(by)","sharedWithId":"\#(with)","inTimeline":\#(inTimeline)}"#)
    }

    private func asset(_ type: String = "PartnerAssetV2", id: String, owner: String,
                       date: String = "2026-08-25T18:16:42.153Z",
                       visibility: String = "timeline", deletedAt: String? = nil) -> (String, Data) {
        let deleted = deletedAt.map { "\"\($0)\"" } ?? "null"
        return line(type, """
            {"id":"\(id)","ownerId":"\(owner)","originalFileName":"\(id).HEIC","thumbhash":null,
             "checksum":"41ipRRJcK31MhPDdCW6B8j/1JJo=","fileCreatedAt":"\(date)",
             "fileModifiedAt":"\(date)","createdAt":"\(date)","localDateTime":"\(date)",
             "duration":null,"type":"IMAGE","deletedAt":\(deleted),"isFavorite":false,
             "visibility":"\(visibility)","livePhotoVideoId":null,"stackId":null,"libraryId":null,
             "width":4032,"height":3024,"isEdited":false}
            """)
    }

    private func exif(_ type: String = "PartnerAssetExifV1", assetID: String) -> (String, Data) {
        line(type, """
            {"assetId":"\(assetID)","description":null,"exifImageWidth":4032,"exifImageHeight":3024,
             "fileSizeInByte":1234,"orientation":"1","dateTimeOriginal":null,"modifyDate":null,
             "timeZone":null,"latitude":48.85,"longitude":2.29,"projectionType":null,"city":"Paris",
             "state":null,"country":"France","make":"Immich","model":"Cam","lensModel":null,
             "fNumber":1.8,"focalLength":24,"iso":100,"exposureTime":"1/125",
             "profileDescription":null,"rating":null,"fps":null}
            """)
    }

    private func apply(_ lines: [(String, Data)]) throws {
        var batch = PartnerSyncBatch()
        for (type, data) in lines {
            XCTAssertTrue(batch.add(type: type, line: data), "\(type) should be a partner line")
        }
        try database.writer().write { db in try PartnerStore.apply(batch, in: db) }
    }

    private func partners() throws -> [Partner] {
        try database.writer().read { db in try PartnerStore.partners(in: db) }
    }

    private func stubs(of owner: String) throws -> [AssetStub] {
        try database.writer().read { db in try PartnerStore.stubs(ownerID: owner, in: db) }
    }

    // MARK: - Requests and acks

    /// Plural request names, as for the user's own types; `PartnerAssetsV1` is rejected by the
    /// server outright ("deprecated, use PartnerAssetsV2").
    func testPartnerRequestTypeRawValues() {
        XCTAssertEqual(Immich.SyncRequestType.authUsers.rawValue, "AuthUsersV1")
        XCTAssertEqual(Immich.SyncRequestType.users.rawValue, "UsersV1")
        XCTAssertEqual(Immich.SyncRequestType.partners.rawValue, "PartnersV1")
        XCTAssertEqual(Immich.SyncRequestType.partnerAssets.rawValue, "PartnerAssetsV2")
        XCTAssertEqual(Immich.SyncRequestType.partnerAssetExifs.rawValue, "PartnerAssetExifsV1")
    }

    /// The `SyncAckV1` line closing a backfill acks under the backfill's checkpoint. Keyed by
    /// line type, the mid-backfill position would be sent too and could win.
    func testBackfillCompletionSupersedesBackfillPosition() {
        var acks = Immich.SyncAcks()
        acks.record("PartnerV1|u1")
        acks.record("PartnerAssetBackfillV2|create-1|u5")
        acks.record("PartnerAssetBackfillV2|create-1|complete")
        acks.record("PartnerAssetV2|u9")

        XCTAssertEqual(Set(acks.all), ["PartnerV1|u1", "PartnerAssetBackfillV2|create-1|complete",
                                       "PartnerAssetV2|u9"])
    }

    func testOwnLibraryLinesAreNotPartnerLines() {
        var batch = PartnerSyncBatch()
        XCTAssertFalse(batch.add(type: "AssetV2", line: asset(id: "a", owner: me).1))
        XCTAssertFalse(batch.add(type: "SyncAckV1", line: Data(#"{"type":"SyncAckV1","data":{},"ack":"x|y|complete"}"#.utf8)))
        XCTAssertTrue(batch.isEmpty)
    }

    // MARK: - Shares

    /// The stream reports shares in both directions; only those *with* the user have a library
    /// to browse.
    func testOnlySharesWithTheUserAreKept() throws {
        try apply([user("AuthUserV1", id: me, name: "Me", email: "me@example.com"),
                   user(id: alice, name: "Alice", email: "alice@example.com"),
                   user(id: bob, name: "Bob", email: "bob@example.com"),
                   share(by: alice, with: me),
                   share(by: me, with: bob)])

        XCTAssertEqual(try partners(), [Partner(id: alice, name: "Alice")])
    }

    /// `AuthUserV1` is acked and never sent again, so a share arriving in a later sync still
    /// has to know who the user is.
    func testUserIDIsRememberedAcrossBatches() throws {
        try apply([user("AuthUserV1", id: me, name: "Me", email: "me@example.com"),
                   user(id: bob, name: "Bob", email: "bob@example.com")])
        try apply([share(by: bob, with: me)])

        XCTAssertEqual(try partners(), [Partner(id: bob, name: "Bob")])
    }

    func testPartnersAreSortedByName() throws {
        try apply([user("AuthUserV1", id: me, name: "Me", email: "me@example.com"),
                   user(id: alice, name: "Zoë", email: "z@example.com"),
                   user(id: bob, name: "bob", email: "bob@example.com"),
                   share(by: alice, with: me), share(by: bob, with: me)])

        XCTAssertEqual(try partners().map(\.name), ["bob", "Zoë"])
    }

    func testRemovingAShareDropsThePartnersLibrary() throws {
        try apply([user("AuthUserV1", id: me, name: "Me", email: "me@example.com"),
                   share(by: alice, with: me),
                   asset(id: "p1", owner: alice)])
        XCTAssertEqual(try stubs(of: alice).count, 1)

        try apply([line("PartnerDeleteV1", #"{"sharedById":"\#(alice)","sharedWithId":"\#(me)"}"#)])

        XCTAssertEqual(try partners(), [])
        XCTAssertEqual(try stubs(of: alice), [], "no per-asset deletes come when a share ends")
    }

    // MARK: - Assets

    /// Backfill and live lines land the same way, newest first, and never in `remote_assets` —
    /// the user's own timeline must not show a partner's photos.
    func testPartnerAssetsAreStoredApartFromTheUsersOwn() throws {
        try apply([user("AuthUserV1", id: me, name: "Me", email: "me@example.com"),
                   share(by: alice, with: me),
                   asset("PartnerAssetBackfillV2", id: "older", owner: alice, date: "2026-01-01T10:00:00.000Z"),
                   asset(id: "newer", owner: alice, date: "2026-08-01T10:00:00.000Z"),
                   exif("PartnerAssetExifBackfillV1", assetID: "older")])

        let stubs = try stubs(of: alice)
        XCTAssertEqual(stubs.map(\.id), [.remote("newer"), .remote("older")])
        XCTAssertTrue(stubs.allSatisfy { $0.isRemoteOnly })
        XCTAssertEqual(stubs[1].latitude, 48.85, accuracy: 0.001)
        XCTAssertTrue(stubs[0].latitude.isNaN)

        let own = try database.writer().read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM remote_assets") ?? -1
        }
        XCTAssertEqual(own, 0)
    }

    /// The server sends a partner's assets before their EXIF, and a later batch may carry EXIF
    /// alone; it merges onto the cached row without losing the asset fields.
    func testExifInALaterBatchMergesOntoTheCachedAsset() throws {
        try apply([asset(id: "p1", owner: alice)])
        try apply([exif(assetID: "p1")])

        let stub = try XCTUnwrap(try stubs(of: alice).first)
        XCTAssertEqual(stub.latitude, 48.85, accuracy: 0.001)
        XCTAssertEqual(stub.pixelWidth, 4032)
    }

    func testTrashedArchivedAndDeletedAssetsAreHidden() throws {
        try apply([asset(id: "keep", owner: alice),
                   asset(id: "trashed", owner: alice, deletedAt: "2026-09-01T00:00:00.000Z"),
                   asset(id: "archived", owner: alice, visibility: "archive"),
                   asset(id: "gone", owner: alice)])
        try apply([line("PartnerAssetDeleteV1", #"{"assetId":"gone"}"#)])

        XCTAssertEqual(try stubs(of: alice).map(\.id), [.remote("keep")])
    }

    func testANameNotYetSyncedFallsBackToTheEmailThenAPlaceholder() throws {
        try apply([user("AuthUserV1", id: me, name: "Me", email: "me@example.com"),
                   line("UserV1", #"{"id":"\#(alice)","name":"","email":"alice@example.com"}"#),
                   share(by: alice, with: me),
                   share(by: bob, with: me)])

        XCTAssertEqual(Set(try partners().map(\.name)), ["alice@example.com", "Partner"])
    }

    func testWipeClearsEveryPartnerTable() throws {
        try apply([user("AuthUserV1", id: me, name: "Me", email: "me@example.com"),
                   user(id: alice, name: "Alice", email: "alice@example.com"),
                   share(by: alice, with: me),
                   asset(id: "p1", owner: alice)])

        try database.writer().write { db in try PartnerStore.wipe(db) }

        XCTAssertEqual(try partners(), [])
        XCTAssertEqual(try stubs(of: alice), [])
    }

    // MARK: - Timeline

    func testSnapshotGroupsAPartnersLibraryLikeTheHomeGrid() throws {
        try apply([asset(id: "a", owner: alice, date: "2026-08-01T10:00:00.000Z"),
                   asset(id: "b", owner: alice, date: "2026-08-01T09:00:00.000Z"),
                   asset(id: "c", owner: alice, date: "2026-03-01T10:00:00.000Z")])

        let snapshot = PartnerLibrary.makeSnapshot(try stubs(of: alice), grouping: .month)

        XCTAssertEqual(snapshot.totalCount, 3)
        XCTAssertEqual(snapshot.buckets.map { $0.items.map(\.id) },
                       [[.remote("a"), .remote("b")], [.remote("c")]])
    }
}
