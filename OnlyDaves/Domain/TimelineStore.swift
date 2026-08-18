import Foundation
import Photos

/// Owns the merged, date-sorted timeline index and publishes immutable snapshots to the UI
/// (DESIGN.md §9).
///
/// Two performance obligations shape this type:
///  * **D19** — `loadBootSnapshot()` paints the grid from a flat file before PhotoKit or
///    SQLite are touched; the live index arrives afterwards and reconciles by diffing.
///  * **D20** — library and sync mutations go through `applyChange`, which splices the
///    sorted index in place. `refresh()` exists only as the reconciliation fallback.
actor TimelineStore {

    // MARK: - Published state

    nonisolated let snapshots: AsyncStream<TimelineSnapshot>
    private let continuation: AsyncStream<TimelineSnapshot>.Continuation

    // MARK: - Dependencies

    private let localLibrary: LocalLibraryService
    private let bootCache: BootCache
    private let settings: AppSettings

    // MARK: - Index state

    /// The whole timeline, newest first. Also the viewer's flattened paging order.
    private var index = TimelineIndex()
    private var grouping: Grouping
    private var provenance: TimelineSnapshot.Provenance = .bootCache
    private var fetchResult: PHFetchResult<PHAsset>?
    private var isLive = false

    private var emitPending = false
    private var bootCacheSaveTask: Task<Void, Never>?
    private var observationTask: Task<Void, Never>?

    init(localLibrary: LocalLibraryService, bootCache: BootCache, settings: AppSettings) {
        self.localLibrary = localLibrary
        self.bootCache = bootCache
        self.settings = settings
        self.grouping = settings.grouping

        // Only the newest snapshot matters; older ones are pure waste for a diffing UI.
        let (stream, continuation) = AsyncStream<TimelineSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        self.snapshots = stream
        self.continuation = continuation
    }

    deinit {
        // Only non-isolated state is safe to touch here; the tasks hold weak self and end
        // on their own once the actor goes away.
        continuation.finish()
    }

    // MARK: - Launch path (D19)

    /// Paints the grid from the persisted index. Touches nothing but one file read.
    func loadBootSnapshot() {
        guard index.isEmpty, !isLive else { return }
        guard let payload = bootCache.load(), !payload.stubs.isEmpty else {
            // Nothing cached: publish an empty snapshot so the grid can show its empty state
            // instead of waiting on PhotoKit.
            emitNow()
            return
        }
        index.replaceAll(payload.stubs)
        grouping = settings.grouping
        provenance = .bootCache
        Log.perf.info("Boot cache painted \(payload.stubs.count) items")
        emitNow()
    }

    /// Builds the real index from PhotoKit and starts observing changes. Called by
    /// `StartupSequencer` only after the first frame is on screen.
    func startLive() {
        guard !isLive else { return }
        isLive = true

        guard localLibrary.hasAnyAccess else {
            // Without access there is nothing to enumerate; publish an authoritative empty
            // index so a stale boot cache does not keep showing photos we can no longer read.
            index.replaceAll([])
            provenance = .live
            emitNow()
            return
        }

        rebuildIndex()
        localLibrary.startObserving()
        startObservingChanges()
    }

    private func startObservingChanges() {
        guard observationTask == nil else { return }
        observationTask = Task { [weak self] in
            guard let self else { return }
            for await change in self.localLibrary.changes {
                await self.handleLibraryChange(change)
            }
        }
    }

    // MARK: - Index construction

    /// Full re-enumeration. Reconciliation fallback only (D20) — the change path uses
    /// `applyChange`.
    func refresh() {
        guard localLibrary.hasAnyAccess else {
            index.replaceAll([])
            provenance = .live
            emitNow()
            return
        }
        rebuildIndex()
    }

    private func rebuildIndex() {
        Signposts.interval(Signposts.indexBuild) {
            let result = localLibrary.fetchAllAssets()
            fetchResult = result

            var stubs = [AssetStub]()
            stubs.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in
                stubs.append(AssetStub(asset))
            }

            // PhotoKit sorts by creationDate, but assets with no creation date fall back to
            // `.distantPast` and can land out of order; `replaceAll` sorts only if needed.
            // M5 merges checksum-linked remote assets into this array before publishing.
            index.replaceAll(stubs)
            provenance = .live
        }
        Log.timeline.info("Live index built: \(self.index.count) items")
        emitNow()
        scheduleBootCacheSave()
    }

    // MARK: - Incremental changes (D20)

    private func handleLibraryChange(_ change: PHChange) {
        guard let previous = fetchResult,
              let details = change.changeDetails(for: previous) else { return }

        fetchResult = details.fetchResultAfterChanges

        guard details.hasIncrementalChanges else {
            // PhotoKit could not describe the delta; fall back to a rebuild.
            rebuildIndex()
            return
        }

        if let removed = details.removedObjects as [PHAsset]?, !removed.isEmpty {
            applyChange(.remove(removed.map { AssetID.local($0.localIdentifier) }))
        }
        if let inserted = details.insertedObjects as [PHAsset]?, !inserted.isEmpty {
            applyChange(.insert(inserted.map { AssetStub($0) }))
        }
        if let changed = details.changedObjects as [PHAsset]?, !changed.isEmpty {
            applyChange(.update(changed.map { AssetStub($0) }))
        }
    }

    /// Splices a mutation into the sorted index without rebuilding it.
    func applyChange(_ change: TimelineChange) {
        guard !change.isEmpty else { return }

        switch change {
        case .insert(let stubs):
            index.insert(stubs)
        case .remove(let ids):
            guard index.remove(ids) else { return }
        case .update(let stubs):
            index.update(stubs)
        }

        scheduleEmit()
        scheduleBootCacheSave()
    }

    // MARK: - Grouping

    func setGrouping(_ newValue: Grouping) {
        guard newValue != grouping else { return }
        grouping = newValue
        settings.grouping = newValue
        emitNow()            // pure re-bucket, no I/O
        scheduleBootCacheSave()
    }

    func currentGrouping() -> Grouping { grouping }

    // MARK: - Lookups

    func asset(for id: AssetID) -> Asset? {
        guard let stub = index.stub(for: id) else { return nil }
        var facets = [AssetFacet]()
        if let localIdentifier = id.localIdentifier, stub.hasLocal {
            facets.append(.local(phLocalIdentifier: localIdentifier))
        }
        if let immichID = id.immichID, stub.hasRemote {
            facets.append(.remote(immichID: immichID))
        }
        // M5: resolve the second facet through `facet_links` for checksum-linked assets.
        return Asset(id: id, facets: facets, stub: stub)
    }

    func neighbors(of id: AssetID) -> (prev: AssetID?, next: AssetID?) {
        index.neighbors(of: id)
    }

    func currentSnapshot() -> TimelineSnapshot { makeSnapshot() }

    var count: Int { index.count }

    // MARK: - Emission

    /// Coalesces bursts (PhotoKit and sync can fire several changes per frame) into one
    /// snapshot, without ever starving a pending emission.
    private func scheduleEmit() {
        guard !emitPending else { return }
        emitPending = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 16_000_000)
            await self?.flushEmit()
        }
    }

    private func flushEmit() {
        emitPending = false
        emitNow()
    }

    private func emitNow() {
        continuation.yield(makeSnapshot())
    }

    private func makeSnapshot() -> TimelineSnapshot {
        let bucketer = TimelineBucketer()
        let buckets = bucketer.buckets(from: index.stubs, grouping: grouping)
        return TimelineSnapshot(grouping: grouping,
                                buckets: buckets,
                                totalCount: index.count,
                                provenance: provenance)
    }

    // MARK: - Boot cache persistence

    private func scheduleBootCacheSave() {
        bootCacheSaveTask?.cancel()
        bootCacheSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.writeBootCache()
        }
    }

    /// Also called directly on scene background so a fresh index is never lost.
    func writeBootCache() {
        guard provenance == .live else { return }
        bootCache.save(stubs: index.stubs, grouping: grouping)
    }
}
