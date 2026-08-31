import Foundation

/// Drives one search session for the grid: debounce, cancellation, and shaping ranked ids into
/// a `TimelineSnapshot` the existing grid can render unchanged (DESIGN.md §19.5, §19.6).
///
/// Kept out of `GridViewController` so the query lifecycle is readable on its own — the subtle
/// part is not the search but the ordering guarantees around it (P8): every keystroke cancels
/// the in-flight query rather than merely discarding its result, and a late result from a
/// superseded query must never overwrite a newer one.
@MainActor
final class SearchSessionController {

    /// Delivered on the main actor. `nil` means "not searching" — restore the timeline.
    var onResults: ((TimelineSnapshot?) -> Void)?
    /// Resolves a ranked id to the stub the grid should draw. The live timeline owns this, so a
    /// result whose asset vanished between ranking and display simply drops out.
    var stubProvider: ((AssetID) -> AssetStub?)?

    private let engine: SearchEngine
    private var queryTask: Task<Void, Never>?
    private var currentQuery = ""

    /// §14 P8. Long enough that ordinary typing does not queue a query per character, short
    /// enough to feel live.
    private static let debounce: Duration = .milliseconds(250)

    init(engine: SearchEngine) {
        self.engine = engine
    }

    var isSearching: Bool { !currentQuery.isEmpty }

    /// Loads the tokenizer and warms the text encoder so the first keystroke doesn't pay for it.
    func begin() {
        Task { await engine.prepare() }
    }

    /// Releases the tokenizer tables and the text encoder's ~85 MB of weights (P8).
    func end() {
        queryTask?.cancel()
        queryTask = nil
        currentQuery = ""
        onResults?(nil)
        Task { await engine.teardown() }
    }

    func update(query raw: String) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != currentQuery else { return }
        currentQuery = query

        queryTask?.cancel()

        guard !query.isEmpty else {
            // Clearing the field restores the timeline immediately — no debounce, nothing to wait
            // for, and no stale results left on screen.
            onResults?(nil)
            return
        }

        queryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }

            do {
                let results = try await self.engine.search(query)
                guard !Task.isCancelled else { return }
                // The user may have typed on while this ran; a superseded query must not
                // overwrite the newer one's results.
                guard self.currentQuery == query else { return }
                self.onResults?(self.snapshot(for: results))
            } catch is CancellationError {
                return
            } catch {
                Log.search.error("Search failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// One bucket in rank order. Reusing `TimelineSnapshot` is what lets results share the grid's
    /// cell, prefetch, selection and viewer paths without a parallel implementation.
    private func snapshot(for results: SearchEngine.Results) -> TimelineSnapshot {
        let stubs = results.ranked.compactMap { stubProvider?($0.id) }
        guard !stubs.isEmpty else {
            return TimelineSnapshot(grouping: .day, buckets: [], totalCount: 0, provenance: .live)
        }
        // A fixed bucket id: a new query replaces the section wholesale rather than diffing
        // against the previous query's ranking, which is meaningless as an animation.
        let bucket = TimelineSnapshot.Bucket(id: "search-results",
                                             title: "\(stubs.count) result\(stubs.count == 1 ? "" : "s")",
                                             items: stubs)
        return TimelineSnapshot(grouping: .day,
                                buckets: [bucket],
                                totalCount: stubs.count,
                                provenance: .live)
    }
}
