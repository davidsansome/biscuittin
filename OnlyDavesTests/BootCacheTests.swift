import XCTest
@testable import OnlyDaves

/// Boot-cache format fidelity and failure handling (DESIGN.md D19, §16).
///
/// The launch path trusts this file blindly, so every malformed input must degrade to nil
/// rather than crash or produce a partial index.
final class BootCacheTests: XCTestCase {

    private func stub(_ id: String, _ offset: Double, kind: MediaKind = .image) -> AssetStub {
        AssetStub(id: AssetID(raw: id),
                  captureDate: Date(timeIntervalSinceReferenceDate: 700_000_000 - offset),
                  hasLocal: offset.truncatingRemainder(dividingBy: 2) == 0,
                  hasRemote: offset.truncatingRemainder(dividingBy: 3) == 0,
                  kind: kind,
                  durationSeconds: kind == .video ? 42.5 : 0,
                  pixelWidth: 4032,
                  pixelHeight: 3024)
    }

    func testRoundTripPreservesEveryField() {
        let original = [
            stub("L:local-1", 0),
            stub("R:remote-2", 1, kind: .video),
            stub("L:live-3", 2, kind: .livePhoto)
        ]
        let data = BootCache.encode(stubs: original, grouping: .week)
        let decoded = BootCache.decode(data)

        XCTAssertEqual(decoded?.grouping, .week)
        XCTAssertEqual(decoded?.stubs.count, original.count)

        for (lhs, rhs) in zip(original, decoded?.stubs ?? []) {
            XCTAssertEqual(lhs.id, rhs.id)
            XCTAssertEqual(lhs.captureDate.timeIntervalSinceReferenceDate,
                           rhs.captureDate.timeIntervalSinceReferenceDate, accuracy: 0.0001)
            XCTAssertEqual(lhs.hasLocal, rhs.hasLocal)
            XCTAssertEqual(lhs.hasRemote, rhs.hasRemote)
            XCTAssertEqual(lhs.kind, rhs.kind)
            XCTAssertEqual(lhs.durationSeconds, rhs.durationSeconds, accuracy: 0.001)
            XCTAssertEqual(lhs.pixelWidth, rhs.pixelWidth)
            XCTAssertEqual(lhs.pixelHeight, rhs.pixelHeight)
        }
    }

    func testRoundTripPreservesOrder() {
        let original = (0..<500).map { stub("asset-\($0)", Double($0)) }
        let decoded = BootCache.decode(BootCache.encode(stubs: original, grouping: .day))
        XCTAssertEqual(decoded?.stubs.map(\.id.raw), original.map(\.id.raw))
    }

    func testEachGroupingSurvivesRoundTrip() {
        for grouping in Grouping.allCases {
            let data = BootCache.encode(stubs: [stub("a", 0)], grouping: grouping)
            XCTAssertEqual(BootCache.decode(data)?.grouping, grouping, "grouping \(grouping) lost")
        }
    }

    func testUnicodeIdentifiersSurviveRoundTrip() {
        let original = [stub("L:café-📷-识别", 0)]
        let decoded = BootCache.decode(BootCache.encode(stubs: original, grouping: .day))
        XCTAssertEqual(decoded?.stubs.first?.id.raw, "L:café-📷-识别")
    }

    func testEmptyIndexRoundTrips() {
        let decoded = BootCache.decode(BootCache.encode(stubs: [], grouping: .month))
        XCTAssertEqual(decoded?.stubs.count, 0)
        XCTAssertEqual(decoded?.grouping, .month)
    }

    // MARK: - Failure handling

    func testTruncatedDataDecodesToNil() {
        let data = BootCache.encode(stubs: (0..<20).map { stub("a-\($0)", Double($0)) },
                                    grouping: .day)
        // Cut mid-record: the decoder must reject rather than return a partial index.
        XCTAssertNil(BootCache.decode(data.prefix(data.count / 2)))
    }

    func testEmptyDataDecodesToNil() {
        XCTAssertNil(BootCache.decode(Data()))
    }

    func testGarbageDecodesToNil() {
        XCTAssertNil(BootCache.decode(Data(repeating: 0xAB, count: 512)))
    }

    func testWrongMagicDecodesToNil() {
        var data = BootCache.encode(stubs: [stub("a", 0)], grouping: .day)
        data.replaceSubrange(0..<4, with: [0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertNil(BootCache.decode(data))
    }

    func testFutureVersionDecodesToNil() {
        var data = BootCache.encode(stubs: [stub("a", 0)], grouping: .day)
        // Bump the version field; a newer on-disk format must be ignored, not misread.
        data.replaceSubrange(4..<8, with: [0x63, 0x00, 0x00, 0x00])
        XCTAssertNil(BootCache.decode(data))
    }

    func testInvalidGroupingDecodesToNil() {
        var data = BootCache.encode(stubs: [stub("a", 0)], grouping: .day)
        data.replaceSubrange(8..<9, with: [0x7F])
        XCTAssertNil(BootCache.decode(data))
    }

    func testOverstatedCountDecodesToNil() {
        var data = BootCache.encode(stubs: [stub("a", 0)], grouping: .day)
        // Claim 9999 records while carrying one: must not read past the buffer.
        data.replaceSubrange(12..<16, with: [0x0F, 0x27, 0x00, 0x00])
        XCTAssertNil(BootCache.decode(data))
    }

    // MARK: - Launch-path budget

    func testLargeIndexRoundTripStaysWithinLaunchBudget() throws {
        // 200k stubs is the size D6 sizes the in-memory index for; decoding it is on the
        // critical path to the first frame (P1), so it has to stay well inside the budget.
        let stubs = (0..<200_000).map {
            stub("L:\(UUID().uuidString)/L0/001-\($0)", Double($0))
        }
        let data = BootCache.encode(stubs: stubs, grouping: .day)

        let start = CFAbsoluteTimeGetCurrent()
        let decoded = BootCache.decode(data)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertEqual(decoded?.stubs.count, 200_000)
        XCTAssertLessThan(elapsed, 1.0, "200k-stub decode took \(elapsed)s; P1 budget is 300ms total")
    }
}
