import XCTest
@testable import OnlyDaves

/// Ordering and incremental-mutation behaviour of the timeline index (DESIGN.md D20, §16).
final class TimelineIndexTests: XCTestCase {

    private func stub(_ id: String,
                      _ daysAgo: Double,
                      kind: MediaKind = .image,
                      hasLocal: Bool = true,
                      hasRemote: Bool = false) -> AssetStub {
        AssetStub(id: AssetID(raw: id),
                  captureDate: Date(timeIntervalSinceReferenceDate: 800_000_000 - daysAgo * 86_400),
                  hasLocal: hasLocal,
                  hasRemote: hasRemote,
                  kind: kind,
                  durationSeconds: kind == .video ? 12 : 0,
                  pixelWidth: 4032,
                  pixelHeight: 3024)
    }

    private func assertSortedNewestFirst(_ index: TimelineIndex,
                                         file: StaticString = #filePath,
                                         line: UInt = #line) {
        XCTAssertTrue(TimelineIndex.isSortedNewestFirst(index.stubs),
                      "index is not newest-first: \(index.stubs.map(\.captureDate))",
                      file: file, line: line)
    }

    // MARK: - Ordering

    func testReplaceAllSortsUnorderedInput() {
        var index = TimelineIndex()
        index.replaceAll([stub("b", 5), stub("a", 1), stub("c", 10)])
        XCTAssertEqual(index.stubs.map(\.id.raw), ["a", "b", "c"])
        assertSortedNewestFirst(index)
    }

    func testReplaceAllPreservesAlreadySortedInput() {
        var index = TimelineIndex()
        let input = [stub("a", 1), stub("b", 5), stub("c", 10)]
        index.replaceAll(input)
        XCTAssertEqual(index.stubs, input)
    }

    func testInsertPlacesItemsInDateOrder() {
        var index = TimelineIndex([stub("a", 1), stub("c", 10)])
        index.insert([stub("b", 5)])
        XCTAssertEqual(index.stubs.map(\.id.raw), ["a", "b", "c"])
        assertSortedNewestFirst(index)
    }

    func testInsertNewestItemGoesToFront() {
        // The "photo just taken" case — requirement that new photos appear at the top.
        var index = TimelineIndex([stub("a", 1), stub("b", 5)])
        index.insert([stub("fresh", 0)])
        XCTAssertEqual(index.stubs.first?.id.raw, "fresh")
    }

    func testInsertIgnoresDuplicates() {
        var index = TimelineIndex([stub("a", 1)])
        index.insert([stub("a", 1), stub("b", 2)])
        XCTAssertEqual(index.stubs.map(\.id.raw), ["a", "b"])
    }

    func testBulkInsertTakesMergePathAndStaysSorted() {
        // Over the 64-item threshold the implementation switches to a linear merge.
        var index = TimelineIndex((0..<200).map { stub("existing-\($0)", Double($0) * 2) })
        let incoming = (0..<200).map { stub("new-\($0)", Double($0) * 2 + 1) }
        index.insert(incoming)

        XCTAssertEqual(index.count, 400)
        assertSortedNewestFirst(index)
    }

    // MARK: - Removal and update

    func testRemoveDropsMatchingIDsAndReportsChange() {
        var index = TimelineIndex([stub("a", 1), stub("b", 2), stub("c", 3)])
        XCTAssertTrue(index.remove([AssetID(raw: "b")]))
        XCTAssertEqual(index.stubs.map(\.id.raw), ["a", "c"])
    }

    func testRemoveReportsNoChangeForUnknownID() {
        var index = TimelineIndex([stub("a", 1)])
        XCTAssertFalse(index.remove([AssetID(raw: "nope")]))
    }

    func testUpdateRepositionsWhenCaptureDateMoves() {
        var index = TimelineIndex([stub("a", 1), stub("b", 5), stub("c", 10)])
        // "b" is re-dated to be the oldest; it must move to the end, not stay put.
        index.update([stub("b", 20)])
        XCTAssertEqual(index.stubs.map(\.id.raw), ["a", "c", "b"])
        assertSortedNewestFirst(index)
    }

    func testUpdateReplacesFacetFlagsInPlace() {
        var index = TimelineIndex([stub("a", 1, hasLocal: true, hasRemote: false)])
        index.update([stub("a", 1, hasLocal: true, hasRemote: true)])
        XCTAssertEqual(index.count, 1)
        XCTAssertTrue(index.stub(for: AssetID(raw: "a"))?.hasRemote == true)
    }

    // MARK: - The D20 invariant

    func testIncrementalMutationsMatchFullRebuild() {
        // A sequence of incremental changes must leave exactly what a rebuild would produce.
        var incremental = TimelineIndex()
        incremental.replaceAll((0..<80).map { stub("seed-\($0)", Double($0)) })

        incremental.insert((0..<30).map { stub("burst-\($0)", Double($0) * 3 + 0.5) })
        incremental.remove((0..<20).map { AssetID(raw: "seed-\($0 * 2)") })
        incremental.update((0..<10).map { stub("burst-\($0)", Double($0) * 7 + 0.25) })
        incremental.insert([stub("late", 500)])

        // Independently compute the expected membership, then sort it wholesale.
        var expected = [String: AssetStub]()
        for i in 0..<80 { expected["seed-\(i)"] = stub("seed-\(i)", Double(i)) }
        for i in 0..<30 { expected["burst-\(i)"] = stub("burst-\(i)", Double(i) * 3 + 0.5) }
        for i in 0..<20 { expected.removeValue(forKey: "seed-\(i * 2)") }
        for i in 0..<10 { expected["burst-\(i)"] = stub("burst-\(i)", Double(i) * 7 + 0.25) }
        expected["late"] = stub("late", 500)

        var rebuilt = TimelineIndex()
        rebuilt.replaceAll(Array(expected.values))

        XCTAssertEqual(incremental.count, rebuilt.count)
        XCTAssertEqual(incremental.stubs.map(\.id.raw), rebuilt.stubs.map(\.id.raw))
        assertSortedNewestFirst(incremental)
    }

    // MARK: - Neighbours (viewer paging order)

    func testNeighborsFollowFlattenedOrder() {
        let index = TimelineIndex([stub("a", 1), stub("b", 2), stub("c", 3)])
        let middle = index.neighbors(of: AssetID(raw: "b"))
        XCTAssertEqual(middle.prev?.raw, "a")
        XCTAssertEqual(middle.next?.raw, "c")

        XCTAssertNil(index.neighbors(of: AssetID(raw: "a")).prev)
        XCTAssertNil(index.neighbors(of: AssetID(raw: "c")).next)
        XCTAssertNil(index.neighbors(of: AssetID(raw: "missing")).prev)
    }

    // MARK: - Identity

    func testAssetIDNamespacesLocalAndRemote() {
        let local = AssetID.local("ABC/L0/001")
        let remote = AssetID.remote("ABC/L0/001")
        XCTAssertNotEqual(local, remote, "identically-named facets must not collide")
        XCTAssertEqual(local.localIdentifier, "ABC/L0/001")
        XCTAssertNil(local.immichID)
        XCTAssertEqual(remote.immichID, "ABC/L0/001")
        XCTAssertNil(remote.localIdentifier)
    }
}

// MARK: - Merge visibility after Free Up Space (D18)

/// A server copy must be hidden behind its local twin only while that twin exists.
/// `facet_links` rows outlive the local file they name, so filtering on the link alone made
/// every photo vanish from the grid once Free Up Space deleted the local copies — the exact
/// opposite of that feature's purpose.
final class RemoteMergeVisibilityTests: XCTestCase {

    private func remoteStub(_ immichID: String) -> AssetStub {
        AssetStub(id: .remote(immichID),
                  captureDate: Date(timeIntervalSince1970: 1_700_000_000),
                  hasLocal: false, hasRemote: true, kind: .image,
                  durationSeconds: 0, pixelWidth: 100, pixelHeight: 100)
    }

    private func mergeData() -> RemoteMergeData {
        var data = RemoteMergeData()
        data.stubs = [remoteStub("r1"), remoteStub("r2"), remoteStub("r3")]
        // r1 and r2 are linked to local copies; r3 was never on this device.
        data.localIdentifierByImmichID = ["r1": "local-1", "r2": "local-2"]
        data.linkedLocalIdentifiers = ["local-1", "local-2"]
        return data
    }

    func testLinkedRemotesAreHiddenWhileTheirLocalCopyExists() {
        let visible = mergeData().remoteOnlyStubs(presentLocalIdentifiers: ["local-1", "local-2"])
        XCTAssertEqual(visible.map { $0.id.immichID }, ["r3"],
                       "only the never-local asset should stand on its own")
    }

    func testRemoteReappearsWhenItsLocalCopyIsDeleted() {
        // Free Up Space removed local-1; its server copy must come back as remote-only.
        let visible = mergeData().remoteOnlyStubs(presentLocalIdentifiers: ["local-2"])
        XCTAssertEqual(Set(visible.compactMap { $0.id.immichID }), ["r1", "r3"])
    }

    func testAllRemotesVisibleWhenEveryLocalCopyIsGone() {
        // The state right after Free Up Space runs over the whole library.
        let visible = mergeData().remoteOnlyStubs(presentLocalIdentifiers: [])
        XCTAssertEqual(visible.count, 3, "freeing space must not empty the timeline")
    }

    func testUnlinkedRemotesAreAlwaysVisible() {
        var data = RemoteMergeData()
        data.stubs = [remoteStub("r9")]
        XCTAssertEqual(data.remoteOnlyStubs(presentLocalIdentifiers: ["anything"]).count, 1)
    }
}
