import UIKit
import XCTest
@testable import BiscuitTin

/// The grid's incremental snapshot path: a patched snapshot must equal the one a full build of
/// the same timeline produces, and anything it cannot express must fall back to a full build.
final class GridSnapshotPatchTests: XCTestCase {

    private typealias Snapshot = NSDiffableDataSourceSnapshot<String, AssetID>

    private func stub(_ id: String) -> AssetStub {
        AssetStub(id: AssetID(raw: id),
                  captureDate: Date(timeIntervalSinceReferenceDate: 800_000_000),
                  hasLocal: true,
                  hasRemote: false,
                  kind: .image,
                  durationSeconds: 0,
                  pixelWidth: 4032,
                  pixelHeight: 3024,
                  latitude: .nan,
                  longitude: .nan)
    }

    /// `[("day1", ["a", "b"]), ...]` → a timeline snapshot with those buckets, in that order.
    private func timeline(_ buckets: [(String, [String])]) -> TimelineSnapshot {
        let built = buckets.map { id, items in
            TimelineSnapshot.Bucket(id: id, title: id, items: items.map(stub))
        }
        return TimelineSnapshot(grouping: .day, buckets: built,
                                totalCount: built.reduce(0) { $0 + $1.items.count },
                                provenance: .live)
    }

    private func assertPatches(from old: [(String, [String])], to new: [(String, [String])],
                               changed: Bool = true,
                               file: StaticString = #filePath, line: UInt = #line) {
        let original = GridViewController.fullSnapshot(of: timeline(old))
        let target = timeline(new)
        guard let result = GridViewController.patch(original, to: target) else {
            return XCTFail("expected a patch, got the full-build fallback", file: file, line: line)
        }
        let expected = GridViewController.fullSnapshot(of: target)
        XCTAssertEqual(result.snapshot.sectionIdentifiers, expected.sectionIdentifiers,
                       file: file, line: line)
        for section in expected.sectionIdentifiers {
            XCTAssertEqual(result.snapshot.itemIdentifiers(inSection: section),
                           expected.itemIdentifiers(inSection: section),
                           "section \(section)", file: file, line: line)
        }
        XCTAssertEqual(result.changed, changed, file: file, line: line)
    }

    private let base: [(String, [String])] = [("d3", ["a", "b", "c"]), ("d2", ["d"]), ("d1", ["e", "f"])]

    func testUnchangedTimelineIsReportedUnchanged() {
        assertPatches(from: base, to: base, changed: false)
    }

    func testDeletingOneItem() {
        assertPatches(from: base, to: [("d3", ["a", "c"]), ("d2", ["d"]), ("d1", ["e", "f"])])
    }

    func testDeletingTheLastItemOfADayRemovesTheSection() {
        assertPatches(from: base, to: [("d3", ["a", "b", "c"]), ("d1", ["e", "f"])])
    }

    func testInsertingIntoAnExistingDay() {
        assertPatches(from: base, to: [("d3", ["new", "a", "b", "c"]), ("d2", ["d"]), ("d1", ["e", "x", "f"])])
    }

    func testInsertingANewDayAtTheTop() {
        assertPatches(from: base, to: [("d4", ["new"])] + base)
    }

    func testInsertingANewDayInTheMiddle() {
        assertPatches(from: base, to: [("d3", ["a", "b", "c"]), ("d2.5", ["x", "y"]), ("d2", ["d"]), ("d1", ["e", "f"])])
    }

    func testReplacingOneDayWithAnother() {
        assertPatches(from: base, to: [("d3", ["a", "b", "c"]), ("d1.5", ["x"]), ("d1", ["e", "f"])])
    }

    func testItemMovingBetweenDaysFallsBackToAFullBuild() {
        let original = GridViewController.fullSnapshot(of: timeline(base))
        let moved = timeline([("d3", ["a", "c"]), ("d2", ["d", "b"]), ("d1", ["e", "f"])])
        XCTAssertNil(GridViewController.patch(original, to: moved))
    }

    func testReorderedSectionsFallBackToAFullBuild() {
        let original = GridViewController.fullSnapshot(of: timeline(base))
        let reordered = timeline([("d2", ["d"]), ("d3", ["a", "b", "c"]), ("d1", ["e", "f"])])
        XCTAssertNil(GridViewController.patch(original, to: reordered))
    }

    func testBulkChangesFallBackToAFullBuild() {
        let many = (0...GridViewController.maxPatchedChanges).map { "n\($0)" }
        let original = GridViewController.fullSnapshot(of: timeline(base))
        XCTAssertNil(GridViewController.patch(original, to: timeline(base + [("d0", many)])))
    }

    func testEmptySnapshotFallsBackToAFullBuild() {
        XCTAssertNil(GridViewController.patch(Snapshot(), to: timeline(base)))
    }

    // MARK: - First-paint prefix

    func testPrefixTruncatesTheLastKeptBucket() {
        let prefix = timeline(base).prefix(maxItems: 4)
        XCTAssertEqual(prefix.buckets.map(\.id), ["d3", "d2"])
        XCTAssertEqual(prefix.buckets.map { $0.items.map(\.id.raw) }, [["a", "b", "c"], ["d"]])
        XCTAssertEqual(prefix.totalCount, 4)

        let cut = timeline(base).prefix(maxItems: 2)
        XCTAssertEqual(cut.buckets.map { $0.items.map(\.id.raw) }, [["a", "b"]])
    }

    func testPrefixOfASmallTimelineIsTheTimeline() {
        let full = timeline(base)
        XCTAssertEqual(full.prefix(maxItems: 100).buckets, full.buckets)
    }

    /// The grid resolves index paths against its prefix while the viewer and search use the
    /// full timeline; the two must agree on every position the prefix has.
    func testPrefixIndexPathsResolveToTheSameItemsAsTheFullTimeline() {
        let full = timeline(base)
        let prefix = full.prefix(maxItems: 5)
        for (section, bucket) in prefix.buckets.enumerated() {
            for item in bucket.items.indices {
                let indexPath = IndexPath(item: item, section: section)
                XCTAssertEqual(prefix.stub(at: indexPath), full.stub(at: indexPath))
                XCTAssertEqual(prefix.flatIndex(of: indexPath), full.flatIndex(of: indexPath))
            }
        }
    }

    /// A delete while the full snapshot is still building shifts one item into the prefix.
    func testPrefixAfterADeletePatchesInPlace() {
        let before = timeline(base).prefix(maxItems: 4)
        let after = timeline([("d3", ["a", "c"]), ("d2", ["d"]), ("d1", ["e", "f"])]).prefix(maxItems: 4)
        let result = GridViewController.patch(GridViewController.fullSnapshot(of: before), to: after)
        XCTAssertEqual(result?.snapshot.itemIdentifiers.map(\.raw), ["a", "c", "d", "e"])
    }
}
