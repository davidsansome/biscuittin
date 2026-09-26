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
    private var remoteRefreshTask: Task<Void, Never>?
    private var remoteRefreshRequested = false
    private static let remoteRefreshDebounce: Double = 0.25

    /// The server half of the timeline, kept so a server change is applied to the timeline
    /// directly instead of rebuilding it. Reading all 70k rows back takes 500–650 ms on an
    /// iPhone 13; one row, under a millisecond. Nil until first loaded, and again after a change
    /// that could not be described by id.
    private var remoteState: RemoteMergeState?
    /// Server assets whose cached rows and links may be out of date.
    private var staleRemoteIDs = Set<String>()
    /// Set by a link change that did not say which links; every link is re-read (~30 ms).
    private var remoteLinksStale = false
    /// Bumped by `.all`, so a read that started before it does not store what it read.
    private var remoteGeneration = 0
    /// The most recent remote read. Each waits for the one before, so reads of the same rows
    /// cannot land out of order.
    private var remoteSyncTail: Task<Bool, Never>?
    /// Above this many stale ids, re-reading everything costs less than looking each one up.
    private static let maxRemoteDelta = 2_000
    /// Above this many changed assets, the timeline is rebuilt rather than patched: each patched
    /// asset shifts the index array, so patching grows with the change times the library, while
    /// a rebuild (~300 ms at 70k on an iPhone 13) does not grow with the change.
    private static let maxPatchedRemoteChanges = 200

    // MARK: - Index state

    /// The whole timeline, newest first. Also the viewer's flattened paging order.
    private var index = TimelineIndex()
    private var grouping: Grouping
    private var provenance: TimelineSnapshot.Provenance = .bootCache
    private var fetchResult: PHFetchResult<PHAsset>?
    /// Taken just before the enumeration behind `fetchResult`, and saved with the boot cache.
    private var indexChangeToken: PHPersistentChangeToken?
    /// The token the boot-cache index was saved with, until launch has replayed from it.
    private var bootCacheChangeToken: PHPersistentChangeToken?
    private var isLive = false

    private var emitPending = false
    /// Ids whose contents changed since the last emitted snapshot (see `reconfiguredIDs`).
    private var pendingReconfiguredIDs = Set<AssetID>()
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
        bootCacheChangeToken = payload.changeToken.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: $0)
        }
        Log.perf.info("Boot cache painted \(payload.stubs.count) items")
        emitNow()
    }

    /// Connects the Immich metadata cache. Safe to call before or after `startLive()`.
    func attach(remoteLibrary: RemoteLibraryService) {
        guard self.remoteLibrary == nil else { return }
        self.remoteLibrary = remoteLibrary

        remoteObservationTask = Task { [weak self] in
            for await change in remoteLibrary.changes {
                await self?.noteRemoteChange(change)
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

        // Observing starts before the rebuild's enumeration so nothing that happens during it
        // is missed. A change handled before `fetchResult` exists is dropped, but the
        // enumeration that follows already includes it.
        localLibrary.startObserving()
        startObservingChanges()
        applyLocalChangesSinceBootCache()
        await rebuildIndex()
    }

    /// Brings the boot-cache index up to date with local changes made while the app was not
    /// running, so a new photo appears straight away. The full rebuild that follows reads every
    /// cached server row before it can publish — seconds, on a large server library — and
    /// still reconciles anything this cannot express.
    private func applyLocalChangesSinceBootCache() {
        guard let token = bootCacheChangeToken else { return }
        bootCacheChangeToken = nil
        guard provenance == .bootCache, let delta = localLibrary.delta(since: token) else { return }

        let upsertedIDs = Set(delta.upserted.map { AssetID.local($0.localIdentifier) })
        let removedIDs = Set(delta.removedIdentifiers.map { AssetID.local($0) })
        var present = Set<AssetID>()
        var linked = Set<AssetID>()
        for stub in index.stubs where upsertedIDs.contains(stub.id) || removedIDs.contains(stub.id) {
            present.insert(stub.id)
            if stub.hasRemote { linked.insert(stub.id) }
        }

        let stubs = delta.upserted.map { asset -> AssetStub in
            let stub = AssetStub(asset)
            return linked.contains(stub.id) ? stub.withFacets(hasLocal: true, hasRemote: true) : stub
        }
        // A removed photo with a server copy must turn into that copy, whose id only the rebuild
        // knows. Removing it here would make it vanish and then reappear.
        let removable = removedIDs.filter { present.contains($0) && !linked.contains($0) }

        Log.timeline.info("Boot cache catch-up: \(stubs.count) upserted, \(removable.count) removed")
        guard !stubs.isEmpty || !removable.isEmpty else { return }
        index.remove(Array(removable))
        index.update(stubs)
        pendingReconfiguredIDs.formUnion(stubs.map(\.id).filter(present.contains))
        emitNow()
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
        // This rebuild subsumes anything the coalescer was still holding.
        remoteRefreshRequested = false
        // Links are cheap to re-read, and a reconciliation should not trust a missed signal.
        remoteLinksStale = true
        await rebuildIndex()
    }

    private func noteRemoteChange(_ change: RemoteChange) {
        switch change {
        case .assets(let ids):
            staleRemoteIDs.formUnion(ids)
        case .links:
            remoteLinksStale = true
        case .all:
            remoteState = nil
            staleRemoteIDs.removeAll()
            remoteLinksStale = false
            remoteGeneration += 1
        }
        scheduleRemoteRefresh()
    }

    /// Coalesces a burst of remote-change notifications into a single pass.
    ///
    /// Most passes patch the timeline directly (`applyRemoteChanges`), but a large change still
    /// takes a rebuild, which re-enumerates the photo library, and a sync can report several
    /// batches in quick succession. Rebuilding per batch once multiplied one sign-in into three
    /// complete rebuilds that all produced an identical index.
    ///
    /// A single drain task owns the work: requests set a flag, and the drain sleeps once to let
    /// a burst accumulate before paying for one pass. Changes that arrive *during* a pass
    /// re-arm the flag and get their own, so a long multi-batch sync still updates
    /// progressively rather than showing nothing until the end.
    private func scheduleRemoteRefresh() {
        remoteRefreshRequested = true
        guard remoteRefreshTask == nil else { return }
        remoteRefreshTask = Task { [weak self] in
            await self?.drainRemoteRefreshes()
        }
    }

    private func drainRemoteRefreshes() async {
        defer { remoteRefreshTask = nil }
        while remoteRefreshRequested {
            try? await Task.sleep(nanoseconds: UInt64(Self.remoteRefreshDebounce * 1_000_000_000))
            // `refresh()` may have rebuilt in the meantime, which makes this pass redundant.
            guard remoteRefreshRequested else { return }
            remoteRefreshRequested = false
            if await !syncRemoteState(patchingTimeline: true) {
                await rebuildIndex()
            }
        }
    }

    private func rebuildIndex() async {
        // Brought up to date first, so the merge below is one synchronous pass over it.
        await syncRemoteState(patchingTimeline: false)
        // Taken after the suspension: another rebuild can run on this actor while it waits.
        let remote = remoteState?.mergeData ?? RemoteMergeData()
        let previousIndex = index
        let previousProvenance = provenance

        Signposts.interval(Signposts.indexBuild) {
            var localStubs = [AssetStub]()
            if localLibrary.hasAnyAccess {
                indexChangeToken = localLibrary.currentChangeToken
                let result = localLibrary.fetchAllAssets()
                fetchResult = result
                localStubs.reserveCapacity(result.count)
                result.enumerateObjects { asset, _, _ in
                    localStubs.append(AssetStub(asset))
                }
            } else {
                fetchResult = nil
                indexChangeToken = nil
            }
            index = remote.merged(withLocal: localStubs)
            provenance = .live
        }

        Log.timeline.info("Live index built: \(self.index.count) items")

        // Most rebuilds are reconciliation that finds nothing new: a delete already spliced in,
        // a sync page with no visible change. Every emission costs the grid main-thread work
        // proportional to the library, so an identical index is not re-published.
        guard index != previousIndex || provenance != previousProvenance
                || !pendingReconfiguredIDs.isEmpty else { return }

        emitNow()
        scheduleBootCacheSave()
    }

    // MARK: - Remote changes

    /// Brings `remoteState` up to date with what the remote library has reported, re-reading
    /// only what changed. With `patchingTimeline`, also applies the change to the timeline, and
    /// returns false when that needs a rebuild instead.
    @discardableResult
    private func syncRemoteState(patchingTimeline: Bool) async -> Bool {
        let previous = remoteSyncTail
        let sync = Task {
            _ = await previous?.value
            return await self.performRemoteSync(patchingTimeline: patchingTimeline)
        }
        remoteSyncTail = sync
        return await sync.value
    }

    private func performRemoteSync(patchingTimeline: Bool) async -> Bool {
        guard let remoteLibrary else { return true }
        let generation = remoteGeneration
        let ids = staleRemoteIDs
        let linksStale = remoteLinksStale
        staleRemoteIDs.removeAll()
        remoteLinksStale = false

        do {
            guard remoteState != nil, ids.count <= Self.maxRemoteDelta else {
                let stubs = try await remoteLibrary.remoteStubs()
                let links = try await remoteLibrary.links()
                guard generation == remoteGeneration else { return false }
                remoteState = RemoteMergeState(stubs: stubs, links: links)
                // A timeline built before this read needs rebuilding from it; one not yet built
                // will be.
                return !isLive
            }
            guard !ids.isEmpty || linksStale else { return true }

            let rows = try await remoteLibrary.remoteStubs(ids: ids)
            let links = linksStale
                ? try await remoteLibrary.links()
                : try await remoteLibrary.links(immichIDs: ids)
            guard generation == remoteGeneration, var state = remoteState else { return false }

            var linkIDs = ids
            if linksStale {
                for (immichID, localIdentifier) in links
                where state.localIdentifierByImmichID[immichID] != localIdentifier {
                    linkIDs.insert(immichID)
                }
                for immichID in state.localIdentifierByImmichID.keys where links[immichID] == nil {
                    linkIDs.insert(immichID)
                }
            }
            // Released while mutating, so the 70k-entry state is not copied on write.
            remoteState = nil
            let transition = state.update(stubsFor: ids, stubs: rows, linksFor: linkIDs, links: links)
            remoteState = state

            guard patchingTimeline, isLive else { return true }
            guard provenance == .live,
                  transition.immichIDs.count <= Self.maxPatchedRemoteChanges else { return false }
            let dates = localCaptureDates(for: transition.localIdentifiers)
            if state.patch(&index, for: transition, localCaptureDates: dates) {
                scheduleEmit()
                scheduleBootCacheSave()
            }
            return true
        } catch {
            // A failed read must never take the timeline down with it: keep what is cached, and
            // try these ids again on the next pass.
            staleRemoteIDs.formUnion(ids)
            if linksStale { remoteLinksStale = true }
            Log.timeline.error("Remote merge data unavailable: \(error.localizedDescription, privacy: .public)")
            return true
        }
    }

    /// The dates these local assets' stubs are indexed under, for the ones PhotoKit still has.
    private func localCaptureDates(for localIdentifiers: Set<String>) -> [String: Date] {
        guard !localIdentifiers.isEmpty, localLibrary.hasAnyAccess else { return [:] }
        var dates = [String: Date]()
        for asset in localLibrary.assets(for: Array(localIdentifiers)) {
            dates[asset.localIdentifier] = AssetStub(asset).captureDate
        }
        return dates
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
            // Identity is unchanged, so the grid's diff would otherwise be a no-op and the
            // tile would keep showing the pre-edit thumbnail.
            pendingReconfiguredIDs.formUnion(stubs.map(\.id))
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
        pendingReconfiguredIDs.removeAll()
    }

    private func makeSnapshot() -> TimelineSnapshot {
        let bucketer = TimelineBucketer()
        let buckets = bucketer.buckets(from: index.stubs, grouping: grouping)
        return TimelineSnapshot(grouping: grouping,
                                buckets: buckets,
                                totalCount: index.count,
                                provenance: provenance,
                                reconfiguredIDs: Array(pendingReconfiguredIDs))
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
        // Replaying from this token next launch also repeats changes already applied here
        // incrementally, which is harmless: inserts and updates are upserts, removals of absent
        // ids no-ops.
        let token = indexChangeToken.flatMap {
            try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
        }
        bootCache.save(stubs: index.stubs, grouping: grouping, changeToken: token)
    }
}
