import XCTest
import GRDB
@testable import OnlyDaves

/// Covers the parts of the search store that fail *quietly*: an fp16 round trip that loses too
/// much precision, or a scan that ranks correctly on one chunk and wrongly across several. Both
/// would still return plausible-looking results, so neither shows up as a crash or an error.
final class EmbeddingStoreTests: XCTestCase {

    private var databaseURL: URL!
    private var store: EmbeddingStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        databaseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("embed-\(UUID().uuidString).sqlite")
        store = EmbeddingStore(database: AppDatabase(fileURL: databaseURL))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: databaseURL)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// A deterministic pseudo-random unit vector, so failures reproduce.
    private func vector(seed: UInt64) -> [Float] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        return (0..<EmbeddingStore.dimensions).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded: state >> 33)) / Float(Int32.max)
        }
    }

    private func id(_ n: Int) -> AssetID { .local("asset-\(n)") }

    // MARK: - fp16 encoding

    func testEncodeDecodeRoundTripPreservesDirection() throws {
        let original = EmbeddingStore.normalized(vector(seed: 1))
        let decoded = try XCTUnwrap(EmbeddingStore.decode(EmbeddingStore.encode(original)))

        XCTAssertEqual(decoded.count, EmbeddingStore.dimensions)
        // What matters is not per-component precision but that the *direction* survives, since
        // every downstream comparison is a cosine.
        let cosine = zip(original, decoded).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        XCTAssertGreaterThan(cosine, 0.9999,
                             "fp16 storage should cost far less than the gap between results")
    }

    func testEncodeNormalizesSoStoredVectorsAreUnitLength() throws {
        // Scaling the input must not change the stored vector: normalisation happens at write
        // time precisely so the scan can treat a dot product as a cosine.
        let base = vector(seed: 2)
        let scaled = base.map { $0 * 17.5 }

        let a = try XCTUnwrap(EmbeddingStore.decode(EmbeddingStore.encode(base)))
        let b = try XCTUnwrap(EmbeddingStore.decode(EmbeddingStore.encode(scaled)))

        let magnitude = sqrt(a.reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(magnitude, 1.0, accuracy: 0.001)
        for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: 0.001) }
    }

    func testDecodeRejectsWrongSizedBlob() {
        XCTAssertNil(EmbeddingStore.decode(Data([1, 2, 3])))
        XCTAssertNil(EmbeddingStore.decode(Data()))
    }

    // MARK: - Store and search

    func testSearchRanksTheMatchingVectorFirst() async throws {
        let target = vector(seed: 42)
        var rows: [(id: AssetID, vector: [Float])] = [(id(0), target)]
        for n in 1..<20 { rows.append((id(n), vector(seed: UInt64(n) &+ 1000))) }
        try await store.store(rows)

        let results = try await store.search(vector: target, limit: 5)
        XCTAssertEqual(results.first?.id, id(0))
        XCTAssertGreaterThan(try XCTUnwrap(results.first?.score), 0.99)
    }

    func testSearchHonoursTheLimit() async throws {
        try await store.store((0..<50).map { (id($0), vector(seed: UInt64($0))) })
        let results = try await store.search(vector: vector(seed: 7), limit: 10)
        XCTAssertEqual(results.count, 10)
    }

    func testResultsAreOrderedByDescendingScore() async throws {
        try await store.store((0..<40).map { (id($0), vector(seed: UInt64($0))) })
        let results = try await store.search(vector: vector(seed: 3), limit: 20)
        let scores = results.map(\.score)
        XCTAssertEqual(scores, scores.sorted(by: >), "results must be ranked best-first")
    }

    /// The scan processes 4096 vectors at a time and merges through a bounded top-K collector.
    /// A library that spans several chunks is where an off-by-one in that merge shows up — and
    /// it would look like slightly-wrong ranking, not a failure.
    func testRankingIsCorrectAcrossMultipleChunks() async throws {
        let target = vector(seed: 99)
        var rows: [(id: AssetID, vector: [Float])] = []
        for n in 0..<9000 { rows.append((id(n), vector(seed: UInt64(n) &+ 5000))) }
        // Place the match deliberately in the final chunk.
        rows.append((id(999_999), target))
        try await store.store(rows)

        let results = try await store.search(vector: target, limit: 3)
        XCTAssertEqual(results.first?.id, id(999_999),
                       "a match in the last chunk must still rank first")
    }

    func testEmptyStoreReturnsNoResults() async throws {
        let results = try await store.search(vector: vector(seed: 1), limit: 10)
        XCTAssertTrue(results.isEmpty)
    }

    func testWrongDimensionQueryReturnsNothingRatherThanCrashing() async throws {
        try await store.store([(id(0), vector(seed: 1))])
        let results = try await store.search(vector: [1, 2, 3], limit: 10)
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Bookkeeping

    func testStoreUpsertsRatherThanDuplicating() async throws {
        try await store.store([(id(0), vector(seed: 1))])
        try await store.store([(id(0), vector(seed: 2))])

        let count = try await store.count()
        XCTAssertEqual(count, 1)

        // The second write must win — a rotated photo re-embeds and the stale vector must go.
        let results = try await store.search(vector: vector(seed: 2), limit: 1)
        XCTAssertGreaterThan(try XCTUnwrap(results.first?.score), 0.99)
    }

    func testIdsNeedingEmbeddingSkipsWhatIsAlreadyStored() async throws {
        try await store.store([(id(0), vector(seed: 1)), (id(1), vector(seed: 2))])
        let pending = try await store.idsNeedingEmbedding(from: [id(0), id(1), id(2), id(3)])
        XCTAssertEqual(Set(pending), [id(2), id(3)])
    }

    func testPruneDropsVanishedAssetsAndKeepsTheRest() async throws {
        try await store.store((0..<5).map { (id($0), vector(seed: UInt64($0))) })
        try await store.prune(keeping: [id(1), id(3)])

        let count = try await store.count()
        XCTAssertEqual(count, 2)
        let pending = try await store.idsNeedingEmbedding(from: (0..<5).map { id($0) })
        XCTAssertEqual(Set(pending), [id(0), id(2), id(4)])
    }

    /// Pruning deletes in batches of 500 to stay under SQLite's variable limit; a bulk delete
    /// or Free Up Space can orphan far more than that at once.
    func testPruneHandlesMoreOrphansThanOneBatch() async throws {
        try await store.store((0..<1200).map { (id($0), vector(seed: UInt64($0))) })
        try await store.prune(keeping: [id(7)])

        let count = try await store.count()
        XCTAssertEqual(count, 1)
    }
}
