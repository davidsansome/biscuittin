import XCTest
import CoreLocation
import UIKit
@testable import BiscuitTin

/// Regression tests for App, Domain, and Local code-review fixes.
final class DomainReviewFixesTests: XCTestCase {

    // MARK: - ShareService unique staging directories

    func testStageShareFileAvoidsFilenameCollisions() throws {
        let fm = FileManager.default
        let src1 = fm.temporaryDirectory.appendingPathComponent("exp-\(UUID().uuidString).jpg")
        let src2 = fm.temporaryDirectory.appendingPathComponent("exp-\(UUID().uuidString).jpg")
        try Data("first-image".utf8).write(to: src1)
        try Data("second-image".utf8).write(to: src2)

        let staged1 = try ShareService.stageShareFile(from: src1, filename: "IMG_0001.JPG")
        let staged2 = try ShareService.stageShareFile(from: src2, filename: "IMG_0001.JPG")
        defer {
            try? fm.removeItem(at: staged1.directory)
            try? fm.removeItem(at: staged2.directory)
        }

        XCTAssertNotEqual(staged1.fileURL, staged2.fileURL)
        XCTAssertEqual(staged1.fileURL.lastPathComponent, "IMG_0001.JPG")
        XCTAssertEqual(staged2.fileURL.lastPathComponent, "IMG_0001.JPG")
        XCTAssertEqual(try Data(contentsOf: staged1.fileURL), Data("first-image".utf8))
        XCTAssertEqual(try Data(contentsOf: staged2.fileURL), Data("second-image".utf8))
    }

    // MARK: - LocalLibraryService chronological persistent change folding

    func testFoldPersistentChangesHandlesDeleteThenRestore() {
        let folded = LocalLibraryService.foldPersistentChanges([
            (inserted: [], updated: [], deleted: ["A", "B"]),
            (inserted: ["A"], updated: [], deleted: [])
        ])
        XCTAssertEqual(folded.touched, ["A"])
        XCTAssertEqual(folded.deleted, ["B"])
    }

    func testFoldPersistentChangesHandlesUpdateThenDelete() {
        let folded = LocalLibraryService.foldPersistentChanges([
            (inserted: ["A"], updated: ["B"], deleted: []),
            (inserted: [], updated: [], deleted: ["A", "B"])
        ])
        XCTAssertTrue(folded.touched.isEmpty)
        XCTAssertEqual(folded.deleted, ["A", "B"])
    }

    // MARK: - AssetMetadata stub coordinates & duration formatting

    func testAssetMetadataPreservesStubCoordinateAndFormatsDurationsSafely() {
        let stub = AssetStub(id: .remote("r1"),
                             captureDate: Date(timeIntervalSince1970: 1_700_000_000),
                             hasLocal: false,
                             hasRemote: true,
                             kind: .video,
                             durationSeconds: 75,
                             pixelWidth: 1920,
                             pixelHeight: 1080,
                             latitude: 37.7749,
                             longitude: -122.4194)
        let metadata = AssetMetadata(stub: stub)
        XCTAssertNotNil(metadata.coordinate)
        XCTAssertEqual(metadata.coordinate?.latitude ?? 0, 37.7749, accuracy: 0.001)
        XCTAssertEqual(metadata.coordinate?.longitude ?? 0, -122.4194, accuracy: 0.001)
        XCTAssertTrue(metadata.hasLocation)

        XCTAssertEqual(AssetMetadata.formattedDuration(75), "1:15")
        XCTAssertEqual(AssetMetadata.formattedDuration(.nan), "0:00")
        XCTAssertEqual(AssetMetadata.formattedDuration(-5), "0:00")
    }

    // MARK: - ImageLoader cancellation suppression

    @MainActor
    func testImageLoaderSuppressesCompletionAfterImmediateCancel() async {
        final class SlowRemoteFetcher: RemoteImageFetching, @unchecked Sendable {
            func cachedImage(immichID: String, variant: ImageVariant) -> UIImage? { nil }
            func image(immichID: String, variant: ImageVariant) async throws -> UIImage {
                try await Task.sleep(nanoseconds: 50_000_000)
                return UIImage()
            }
        }

        let loader = ImageLoader(resolver: PHAssetResolver())
        loader.attachRemoteFetcher(SlowRemoteFetcher())
        let stub = AssetStub(id: .remote("r1"),
                             captureDate: Date(),
                             hasLocal: false,
                             hasRemote: true,
                             kind: .image,
                             durationSeconds: 0,
                             pixelWidth: 100,
                             pixelHeight: 100,
                             latitude: .nan,
                             longitude: .nan)

        var delivered = false
        let token = loader.requestImage(for: stub, variant: .viewerPreview) { _, _ in
            delivered = true
        }
        loader.cancel(token)
        XCTAssertTrue(token.isCancelled)

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(delivered, "cancelled request must not invoke completion")
    }

    // MARK: - TimelineStore batch lookup & PhotoActionService failed remote delete

    func testTimelineStoreBatchAssetsLookup() async {
        let store = TimelineStore(localLibrary: LocalLibraryService(),
                                  bootCache: BootCache(fileURL: FileManager.default.temporaryDirectory
                                    .appendingPathComponent("test-bc-\(UUID().uuidString).bin")),
                                  settings: AppSettings())
        let s1 = AssetStub(id: .local("L1"), captureDate: Date(timeIntervalSince1970: 100),
                           hasLocal: true, hasRemote: false, kind: .image,
                           durationSeconds: 0, pixelWidth: 10, pixelHeight: 10,
                           latitude: .nan, longitude: .nan)
        let s2 = AssetStub(id: .remote("R1"), captureDate: Date(timeIntervalSince1970: 200),
                           hasLocal: false, hasRemote: true, kind: .image,
                           durationSeconds: 0, pixelWidth: 10, pixelHeight: 10,
                           latitude: .nan, longitude: .nan)
        await store.applyChange(.insert([s1, s2]))

        let found = await store.assets(for: [.local("L1"), .remote("R1"), .remote("missing")])
        XCTAssertEqual(Set(found.keys), [.local("L1"), .remote("R1")])
        XCTAssertEqual(found[.local("L1")]?.localIdentifier, "L1")
        XCTAssertEqual(found[.remote("R1")]?.immichID, "R1")
    }

    @MainActor
    func testFailedRemoteDeleteDoesNotRemoveSurvivingRemoteAssetFromTimeline() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("delete-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let database = AppDatabase(fileURL: tempDir.appendingPathComponent("test.sqlite"))
        let session = ImmichAuthSession(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        let resolver = PHAssetResolver()
        let exporter = LocalAssetExporter()
        let remoteLibrary = RemoteLibraryService(database: database,
                                                 session: session,
                                                 resolver: resolver,
                                                 exporter: exporter,
                                                 registry: .v1)
        let store = TimelineStore(localLibrary: LocalLibraryService(),
                                  bootCache: BootCache(fileURL: tempDir.appendingPathComponent("bc.bin")),
                                  settings: AppSettings())
        let loader = ImageLoader(resolver: resolver)
        let actions = PhotoActionService(timelineStore: store,
                                         resolver: resolver,
                                         editor: LocalAssetEditor(),
                                         registry: .v1,
                                         imageLoader: loader,
                                         remoteLibrary: remoteLibrary)

        let remoteOnlyStub = AssetStub(id: .remote("R-survive"),
                                       captureDate: Date(timeIntervalSince1970: 300),
                                       hasLocal: false, hasRemote: true, kind: .image,
                                       durationSeconds: 0, pixelWidth: 100, pixelHeight: 100,
                                       latitude: .nan, longitude: .nan)
        await store.applyChange(.insert([remoteOnlyStub]))

        // Session is not configured, so `remoteLibrary.deleteRemote` throws.
        let outcome = await actions.delete(ids: [.remote("R-survive")])

        XCTAssertTrue(outcome.succeeded.isEmpty)
        XCTAssertEqual(outcome.failures.map { $0.id }, [AssetID.remote("R-survive")])
        let stillThere = await store.asset(for: .remote("R-survive"))
        XCTAssertNotNil(stillThere, "failed remote delete must not remove the surviving remote asset from the timeline")
    }

    // MARK: - CancellableRequestBox

    func testCancellableRequestBoxCancelsImmediatelyWhenAlreadyCancelled() {
        let box = CancellableRequestBox<Int>()
        var cancelledIDs: [Int] = []
        box.cancel { cancelledIDs.append($0) }
        XCTAssertTrue(cancelledIDs.isEmpty)

        box.store(42) { cancelledIDs.append($0) }
        XCTAssertEqual(cancelledIDs, [42])
    }

    func testCancellableRequestBoxCancelsStoredIDOnce() {
        let box = CancellableRequestBox<Int>()
        var cancelledIDs: [Int] = []
        box.store(7) { cancelledIDs.append($0) }
        box.cancel { cancelledIDs.append($0) }
        box.cancel { cancelledIDs.append($0) }
        XCTAssertEqual(cancelledIDs, [7])
    }
}
