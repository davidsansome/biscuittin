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
    /// Set after construction to avoid an initialisation cycle; nil until an Immich server is
    /// configured, which is the offline-only case the app must fully support (D12).
    private var remoteLibrary: RemoteLibraryService?
    private var remoteObservationTask: Task<Void, Never>?

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

    /// Connects the Immich metadata cache. Safe to call before or after `startLive()`.
    func attach(remoteLibrary: RemoteLibraryService) {
        guard self.remoteLibrary == nil else { return }
        self.remoteLibrary = remoteLibrary

        remoteObservationTask = Task { [weak self] in
            for await _ in remoteLibrary.changes {
                await self?.refresh()
            }
        }
        if isLive { Task { await refresh() } }
    }

    /// Builds the real index from PhotoKit and starts observing changes. Called by
    /// `StartupSequencer` only after the first frame is on screen.
    func startLive() async {
        guard !isLive else { return }
        isLive = true

        guard localLibrary.hasAnyAccess else {
            // Without local access the timeline is whatever the server gave us — which may be
            // nothing. Publish authoritatively so a stale boot cache stops showing photos we
            // can no longer read.
            await rebuildIndex()
            return
        }

        await rebuildIndex()
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
    func refresh() async {
        await rebuildIndex()
    }

    private func rebuildIndex() async {
        // Remote metadata is read first: it is a SQLite query on this actor, and doing it
        // before the PhotoKit enumeration keeps the merge a single pass.
        let remote = await loadRemoteMergeData()

        Signposts.interval(Signposts.indexBuild) {
            var localStubs = [AssetStub]()
            var presentLocalIdentifiers = Set<String>()

            if localLibrary.hasAnyAccess {
                let result = localLibrary.fetchAllAssets()
                fetchResult = result
                localStubs.reserveCapacity(result.count)
                result.enumerateObjects { asset, _, _ in
                    var stub = AssetStub(asset)
                    presentLocalIdentifiers.insert(asset.localIdentifier)
                    // An asset with a server copy is one asset with two facets, not two rows.
                    if remote.linkedLocalIdentifiers.contains(asset.localIdentifier) {
                        stub = stub.withFacets(hasLocal: true, hasRemote: true)
                    }
                    localStubs.append(stub)
                }
            } else {
                fetchResult = nil
            }

            // A server copy is hidden behind its local twin only while that twin actually
            // exists. Link rows outlive the local file they name — after Free Up Space removes
            // it (D18) the asset must reappear as remote-only, not disappear altogether.
            let remoteOnly = remote.remoteOnlyStubs(presentLocalIdentifiers: presentLocalIdentifiers)

            // PhotoKit sorts by creationDate, but assets with no creation date fall back to
            // `.distantPast` and can land out of order; `replaceAll` sorts only if needed.
            index.replaceAll(localStubs)
            if !remoteOnly.isEmpty {
                index.insert(remoteOnly)
            }
            provenance = .live
        }

        Log.timeline.info("Live index built: \(self.index.count) items")
        emitNow()
        scheduleBootCacheSave()
    }

    private func loadRemoteMergeData() async -> RemoteMergeData {
        guard let remoteLibrary else { return RemoteMergeData() }
        do {
            return try await remoteLibrary.mergeData()
        } catch {
            // A failed metadata read must never take the local timeline down with it.
            Log.timeline.error("Remote merge data unavailable: \(error.localizedDescription, privacy: .public)")
            return RemoteMergeData()
        }
    }

    // MARK: - Incremental changes (D20)

    private func handleLibraryChange(_ change: PHChange) {
        guard let previous = fetchResult,
              let details = change.changeDetails(for: previous) else { return }

        fetchResult = details.fetchResultAfterChanges

        guard details.hasIncrementalChanges else {
            // PhotoKit could not describe the delta; fall back to a rebuild.
            Task { await rebuildIndex() }
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
        return Asset(id: id, facets: facets, stub: stub)
    }

    /// Resolves the *other* facet for a linked asset, which requires a database lookup and so
    /// is kept off the hot path — callers ask only when they need to act on the server copy.
    func fullyResolvedAsset(for id: AssetID) async -> Asset? {
        guard let asset = asset(for: id) else { return nil }
        guard asset.stub.hasLocal, asset.stub.hasRemote, asset.immichID == nil,
              let localIdentifier = asset.localIdentifier,
              let remoteLibrary else { return asset }

        guard let immichID = try? await remoteLibrary.immichID(forLocalIdentifier: localIdentifier)
        else { return asset }

        return Asset(id: asset.id,
                     facets: asset.facets + [.remote(immichID: immichID)],
                     stub: asset.stub)
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
