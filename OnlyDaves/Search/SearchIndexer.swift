import Foundation
import Photos
import UIKit

/// Keeps the embedding store in step with the timeline (DESIGN.md §19.4).
///
/// Each pass diffs the timeline's current id set against the store: ids with no row get embedded,
/// rows whose asset is gone get pruned. **The table is its own checkpoint** — there is no
/// separate progress cursor to corrupt, so an interrupted pass simply resumes, and a crash
/// mid-batch costs at most one batch of work.
///
/// This is the lowest-priority work in the app (P6/P8): `.utility` QoS, a yield between batches,
/// and a hard pause while the user is scrolling. It must never cost a grid frame.
actor SearchIndexer {

    /// Enough to amortise the per-call CoreML overhead without holding many decoded images.
    private static let batchSize = 32
    /// Matches the encoder's native input, so PhotoKit does the downsampling once (§19.4).
    private static let sourceSide: CGFloat = 256

    private let store: EmbeddingStore
    private let encoder: CLIPEncoder
    private let timelineStore: TimelineStore
    private let resolver: PHAssetResolver
    private let remoteImages: RemoteImageFetching

    private var isRunning = false
    private var isPaused = false
    /// Set when a pass is asked to run while one is already going, so the new work is picked up
    /// rather than dropped.
    private var needsAnotherPass = false

    private let imageManager = PHImageManager.default()

    init(store: EmbeddingStore,
         encoder: CLIPEncoder,
         timelineStore: TimelineStore,
         resolver: PHAssetResolver,
         remoteImages: RemoteImageFetching) {
        self.store = store
        self.encoder = encoder
        self.timelineStore = timelineStore
        self.resolver = resolver
        self.remoteImages = remoteImages
    }

    /// The grid calls this as scrolling starts and stops (P6). Indexing yields rather than
    /// competing with the thing the user is actually looking at.
    func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    // MARK: - Passes

    /// Runs an indexing pass. Safe to call often — concurrent calls coalesce into one more pass.
    func run() async {
        guard encoder.isAvailable else { return }
        guard !isRunning else {
            needsAnotherPass = true
            return
        }
        isRunning = true
        defer {
            isRunning = false
            encoder.releaseImageEncoder()   // P8: weights resident only while a batch runs
        }

        repeat {
            needsAnotherPass = false
            do {
                try await performPass()
            } catch is CancellationError {
                return
            } catch {
                Log.search.error("Indexing pass failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        } while needsAnotherPass
    }

    private func performPass() async throws {
        let snapshot = await timelineStore.currentSnapshot()
        let stubs = snapshot.flattened()
        guard !stubs.isEmpty else { return }

        try await store.prune(keeping: Set(stubs.map(\.id)))

        let pending = try await store.idsNeedingEmbedding(from: stubs.map(\.id))
        guard !pending.isEmpty else { return }

        let byID = Dictionary(stubs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let started = CFAbsoluteTimeGetCurrent()
        var embedded = 0
        var skipped = 0

        for batchStart in stride(from: 0, to: pending.count, by: Self.batchSize) {
            try Task.checkCancellation()
            await waitWhilePaused()

            let batch = pending[batchStart..<min(batchStart + Self.batchSize, pending.count)]
            var images = [CGImage]()
            var ids = [AssetID]()

            for id in batch {
                guard let stub = byID[id] else { continue }
                if let image = await sourceImage(for: stub) {
                    images.append(image)
                    ids.append(id)
                } else {
                    // No pixels available (offline remote, or an iCloud original we declined to
                    // download). The id-diff retries it next pass at no extra bookkeeping.
                    skipped += 1
                }
            }
            guard !images.isEmpty else { continue }

            let vectors = try encoder.encode(images: images)
            try await store.store(Array(zip(ids, vectors)).map { (id: $0.0, vector: $0.1) })
            embedded += vectors.count

            // Let the main thread — and anything else at higher QoS — run between batches.
            await Task.yield()
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - started
        Log.search.info("""
            Indexed \(embedded) assets in \(String(format: "%.1f", elapsed))s \
            (\(skipped) skipped, \(pending.count) pending at start)
            """)
    }

    private func waitWhilePaused() async {
        while isPaused {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: - Pixel sources

    private func sourceImage(for stub: AssetStub) async -> CGImage? {
        if let localIdentifier = stub.id.localIdentifier, stub.hasLocal {
            return localImage(localIdentifier: localIdentifier)
        }
        guard let immichID = stub.id.immichID else { return nil }

        // Prefer the thumbnail the grid already cached; only reach for the network when the
        // asset has never been displayed.
        if let cached = remoteImages.cachedImage(immichID: immichID, variant: thumbVariant) {
            return cached.cgImage
        }
        return try? await remoteImages.image(immichID: immichID, variant: thumbVariant).cgImage
    }

    private var thumbVariant: ImageVariant {
        .gridThumb(pointSize: CGSize(width: Self.sourceSide, height: Self.sourceSide), scale: 1)
    }

    /// Synchronous by design: this runs on the actor's background executor, and the batch loop
    /// wants images in hand before it calls CoreML. `isSynchronous` is only unsafe on the main
    /// thread, which this never is.
    private func localImage(localIdentifier: String) -> CGImage? {
        guard let asset = resolver.resolve(localIdentifier) else { return nil }

        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        // iCloud originals are not worth a download here; the asset is retried on a later pass
        // once the user has viewed it and PhotoKit holds a local rendition.
        options.isNetworkAccessAllowed = false

        var result: CGImage?
        imageManager.requestImage(for: asset,
                                  targetSize: CGSize(width: Self.sourceSide, height: Self.sourceSide),
                                  contentMode: .aspectFill,
                                  options: options) { image, _ in
            result = image?.cgImage
        }
        return result
    }
}
