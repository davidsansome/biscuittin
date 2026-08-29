import Foundation
import GRDB
import Accelerate

/// Persists and scans CLIP embeddings (DESIGN.md D23, §19.3).
///
/// Vectors are stored as **512 × fp16** blobs — 1 KB per asset, so 100k assets is ~100 MB on
/// disk and ~50 MB in the scan cache. fp16 costs about three decimal digits of precision per
/// component, which is far below the gap between a relevant and an irrelevant result; the
/// halved memory is what keeps a full-library scan cheap.
///
/// Queries are a **brute-force scan**, deliberately (D23): at 100k assets a full pass is ~50M
/// multiply-adds, single-digit milliseconds through Accelerate, and it stays exactly correct as
/// the library mutates. An ANN index would add build and invalidation complexity that nothing
/// below roughly a million vectors needs.
actor EmbeddingStore {

    /// Bumping this invalidates every stored vector (D22) — they are only comparable within one
    /// model. The indexer re-embeds mismatched rows; it does not compare across versions.
    static let modelVersion = "mobileclip-s0-v1"

    static let dimensions = 512

    private let database: AppDatabase

    /// Chunked scan cache. Loading 100k vectors from SQLite on every keystroke would dominate
    /// the query budget (P8), so decoded chunks are held until the cap is hit.
    private var cachedChunks: [Chunk] = []
    private var cacheIsComplete = false
    private var cachedBytes = 0
    private static let cacheByteCap = 32 * 1024 * 1024
    private static let chunkSize = 4096

    /// Row-major `count × dimensions` fp32, ready for `vDSP`. Ids are parallel to the rows.
    private struct Chunk {
        var ids: [AssetID]
        var values: [Float]
        var count: Int { ids.count }
    }

    init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - Writing

    func store(_ embeddings: [(id: AssetID, vector: [Float])]) async throws {
        guard !embeddings.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        let version = Self.modelVersion

        let writer = try database.writer()
        try await writer.write { db in
            for (id, vector) in embeddings {
                try db.execute(sql: """
                    INSERT INTO clip_embedding (asset_id, model_version, vector, indexed_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(asset_id) DO UPDATE SET
                        model_version = excluded.model_version,
                        vector = excluded.vector,
                        indexed_at = excluded.indexed_at
                    """,
                    arguments: [id.raw, version, Self.encode(vector), now])
            }
        }
        invalidateCache()
    }

    /// Drops rows for assets that no longer exist. The id set is the timeline's, so this is what
    /// keeps the store from accumulating vectors for deleted photos.
    func prune(keeping liveIDs: Set<AssetID>) async throws {
        let writer = try database.writer()
        let stale: [String] = try await writer.read { db in
            try String.fetchAll(db, sql: "SELECT asset_id FROM clip_embedding")
        }
        let doomed = stale.filter { !liveIDs.contains(AssetID(raw: $0)) }
        guard !doomed.isEmpty else { return }

        try await writer.write { db in
            // Chunked: SQLite's variable limit is finite and a big library can orphan a lot at
            // once (a bulk delete, or Free Up Space flipping ids from local to remote).
            for batch in stride(from: 0, to: doomed.count, by: 500).map({
                Array(doomed[$0..<min($0 + 500, doomed.count)])
            }) {
                let placeholders = databaseQuestionMarks(count: batch.count)
                try db.execute(sql: "DELETE FROM clip_embedding WHERE asset_id IN (\(placeholders))",
                               arguments: StatementArguments(batch))
            }
        }
        invalidateCache()
        Log.search.info("Pruned \(doomed.count) embeddings for deleted assets")
    }

    /// Ids that still need embedding: everything in `candidates` with no row, plus anything
    /// stored under a different model version.
    func idsNeedingEmbedding(from candidates: [AssetID]) async throws -> [AssetID] {
        guard !candidates.isEmpty else { return [] }
        let writer = try database.writer()
        let current = Self.modelVersion
        let embedded: Set<String> = try await writer.read { db in
            try Set(String.fetchAll(db, sql: "SELECT asset_id FROM clip_embedding WHERE model_version = ?",
                                    arguments: [current]))
        }
        return candidates.filter { !embedded.contains($0.raw) }
    }

    func count() async throws -> Int {
        let writer = try database.writer()
        let version = Self.modelVersion
        return try await writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clip_embedding WHERE model_version = ?",
                             arguments: [version]) ?? 0
        }
    }

    // MARK: - Querying

    /// Top-`limit` ids by cosine similarity, best first.
    ///
    /// Both sides are unit-normalised, so a dot product *is* the cosine and the whole scan
    /// reduces to one `vDSP_mmul` per chunk. No score threshold is applied (D23): CLIP's
    /// absolute similarities shift with the query's phrasing, so a fixed cutoff would silently
    /// empty some searches and flood others. Ranking is the contract; callers decide how deep
    /// to read.
    func search(vector query: [Float], limit: Int) async throws -> [(id: AssetID, score: Float)] {
        guard query.count == Self.dimensions else { return [] }
        let chunks = try await loadChunks()
        guard !chunks.isEmpty else { return [] }

        let normalizedQuery = Self.normalized(query)
        var heap = TopK(limit: limit)

        for chunk in chunks {
            var scores = [Float](repeating: 0, count: chunk.count)
            // (count × dim) · (dim × 1) — one matrix-vector product per chunk.
            normalizedQuery.withUnsafeBufferPointer { q in
                chunk.values.withUnsafeBufferPointer { m in
                    vDSP_mmul(m.baseAddress!, 1, q.baseAddress!, 1, &scores, 1,
                              vDSP_Length(chunk.count), 1, vDSP_Length(Self.dimensions))
                }
            }
            for (index, score) in scores.enumerated() {
                heap.offer(id: chunk.ids[index], score: score)
            }
        }
        return heap.sorted()
    }

    // MARK: - Chunk loading

    private func loadChunks() async throws -> [Chunk] {
        if cacheIsComplete { return cachedChunks }

        let writer = try database.writer()
        let version = Self.modelVersion
        let rows: [(String, Data)] = try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT asset_id, vector FROM clip_embedding WHERE model_version = ?
                """, arguments: [version])
                .map { ($0["asset_id"], $0["vector"]) }
        }

        var chunks = [Chunk]()
        var ids = [AssetID]()
        var values = [Float]()
        values.reserveCapacity(Self.chunkSize * Self.dimensions)

        func flush() {
            guard !ids.isEmpty else { return }
            chunks.append(Chunk(ids: ids, values: values))
            ids.removeAll(keepingCapacity: true)
            values.removeAll(keepingCapacity: true)
        }

        for (raw, blob) in rows {
            guard let decoded = Self.decode(blob) else { continue }
            ids.append(AssetID(raw: raw))
            values.append(contentsOf: decoded)
            if ids.count == Self.chunkSize { flush() }
        }
        flush()

        let bytes = chunks.reduce(0) { $0 + $1.values.count * MemoryLayout<Float>.size }
        if bytes <= Self.cacheByteCap {
            cachedChunks = chunks
            cachedBytes = bytes
            cacheIsComplete = true
        } else {
            // Past the cap the store stays authoritative and each query re-reads. Caching a
            // partial set would rank the cached assets against a stale view of the rest.
            invalidateCache()
        }
        return chunks
    }

    private func invalidateCache() {
        cachedChunks = []
        cachedBytes = 0
        cacheIsComplete = false
    }

    /// Frees the scan cache under memory pressure; the next query re-reads from SQLite.
    func releaseCache() { invalidateCache() }

    var cacheFootprintBytes: Int { cachedBytes }

    // MARK: - fp16 encoding

    static func encode(_ vector: [Float]) -> Data {
        let unit = normalized(vector)
        var halves = [UInt16](repeating: 0, count: unit.count)
        var source = unit
        source.withUnsafeMutableBufferPointer { src in
            halves.withUnsafeMutableBufferPointer { dst in
                var sourceBuffer = vImage_Buffer(data: src.baseAddress!, height: 1,
                                                 width: vImagePixelCount(src.count),
                                                 rowBytes: src.count * MemoryLayout<Float>.size)
                var destBuffer = vImage_Buffer(data: dst.baseAddress!, height: 1,
                                               width: vImagePixelCount(dst.count),
                                               rowBytes: dst.count * MemoryLayout<UInt16>.size)
                vImageConvert_PlanarFtoPlanar16F(&sourceBuffer, &destBuffer, 0)
            }
        }
        return halves.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [Float]? {
        let expected = dimensions * MemoryLayout<UInt16>.size
        guard data.count == expected else { return nil }

        var halves = [UInt16](repeating: 0, count: dimensions)
        _ = halves.withUnsafeMutableBytes { data.copyBytes(to: $0) }

        var floats = [Float](repeating: 0, count: dimensions)
        halves.withUnsafeMutableBufferPointer { src in
            floats.withUnsafeMutableBufferPointer { dst in
                var sourceBuffer = vImage_Buffer(data: src.baseAddress!, height: 1,
                                                 width: vImagePixelCount(src.count),
                                                 rowBytes: src.count * MemoryLayout<UInt16>.size)
                var destBuffer = vImage_Buffer(data: dst.baseAddress!, height: 1,
                                               width: vImagePixelCount(dst.count),
                                               rowBytes: dst.count * MemoryLayout<Float>.size)
                vImageConvert_Planar16FtoPlanarF(&sourceBuffer, &destBuffer, 0)
            }
        }
        return floats
    }

    /// Unit-normalises so that a later dot product is exactly the cosine similarity. Applied at
    /// write time, so the scan never pays for it.
    static func normalized(_ vector: [Float]) -> [Float] {
        var sumSquares: Float = 0
        vDSP_svesq(vector, 1, &sumSquares, vDSP_Length(vector.count))
        let norm = sqrt(sumSquares)
        guard norm > 0 else { return vector }
        var divisor = norm
        var out = [Float](repeating: 0, count: vector.count)
        vDSP_vsdiv(vector, 1, &divisor, &out, 1, vDSP_Length(vector.count))
        return out
    }
}

/// Bounded best-of collector. Keeps the scan O(n) in comparisons rather than sorting every
/// asset in the library to return 200 of them.
private struct TopK {
    private let limit: Int
    private var entries: [(id: AssetID, score: Float)] = []
    private var threshold: Float = -.greatestFiniteMagnitude

    init(limit: Int) {
        self.limit = max(1, limit)
        entries.reserveCapacity(self.limit * 2)
    }

    mutating func offer(id: AssetID, score: Float) {
        guard entries.count < limit || score > threshold else { return }
        entries.append((id, score))
        // Amortised: compact only once the buffer has grown to twice the limit, so the common
        // path is a bare append.
        if entries.count >= limit * 2 { compact() }
    }

    private mutating func compact() {
        entries.sort { $0.score > $1.score }
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        threshold = entries.last?.score ?? -.greatestFiniteMagnitude
    }

    mutating func sorted() -> [(id: AssetID, score: Float)] {
        compact()
        return entries
    }
}
