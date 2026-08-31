import Foundation

/// Runs text queries against the embedding store (DESIGN.md §19.5).
///
/// Deliberately small: tokenize → text-encode → top-K scan → hand back ranked ids. Mapping those
/// ids to a timeline snapshot belongs to the caller, which already holds the live index — an
/// embedding row whose asset vanished mid-query simply drops out there rather than needing a
/// consistency protocol here.
actor SearchEngine {

    struct Results {
        let query: String
        /// Ranked best-first. Scores are cosine similarities in [-1, 1], exposed for diagnostics
        /// rather than display — CLIP's absolute values are not a meaningful confidence.
        let ranked: [(id: AssetID, score: Float)]
    }

    /// How deep a single search reads (D23). Enough to scroll through, cheap to rank.
    static let resultLimit = 200

    private let encoder: CLIPEncoder
    private let store: EmbeddingStore
    private var tokenizer: CLIPTokenizer?

    init(encoder: CLIPEncoder, store: EmbeddingStore) {
        self.encoder = encoder
        self.store = store
    }

    var isAvailable: Bool { encoder.isAvailable }

    /// Parses the ~1.7 MB vocabulary and warms the text encoder. Called when the search UI opens
    /// so the first keystroke does not pay for it (P8).
    func prepare() async {
        guard encoder.isAvailable else { return }
        do {
            if tokenizer == nil { tokenizer = try CLIPTokenizer.bundled() }
            // Encoding a throwaway string forces the model load and its first-run compilation
            // now, rather than inside the first real query's budget.
            _ = try encoder.encode(text: tokenizer!.encodePadded(""))
        } catch {
            Log.search.error("Search preparation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Releases both the tokenizer tables and the text encoder's weights (P8).
    func teardown() {
        tokenizer = nil
        encoder.releaseTextEncoder()
    }

    func search(_ query: String) async throws -> Results {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Results(query: query, ranked: []) }

        if tokenizer == nil { tokenizer = try CLIPTokenizer.bundled() }
        guard let tokenizer else { return Results(query: query, ranked: []) }

        // Each stage is a cancellation point: live search fires a query per keystroke and the
        // previous one must stop before the next starts (P8), not merely have its result ignored.
        try Task.checkCancellation()
        let tokens = tokenizer.encodePadded(trimmed)

        try Task.checkCancellation()
        let vector = try encoder.encode(text: tokens)

        try Task.checkCancellation()
        let ranked = try await store.search(vector: vector, limit: Self.resultLimit)

        return Results(query: query, ranked: ranked)
    }
}
