import UIKit

// MARK: - Snapshot plumbing

extension GridViewController {

    func subscribeToSnapshots(_ snapshots: AsyncStream<TimelineSnapshot>) {
        // Holds self weakly between snapshots: a partner's library is popped and must be freed,
        // which in turn cancels this task and ends the stream.
        snapshotTask = Task { [weak self] in
            for await snapshot in snapshots {
                guard let self else { return }
                self.apply(snapshot)
            }
        }
    }

    func apply(_ new: TimelineSnapshot) {
        let previous = patchTarget ?? fullTimeline
        hasReceivedSnapshot = true

        // §14 P1 is about photos being visible, not just a view existing. Measured from the
        // live timeline even mid-search: it is a launch metric, not a display one.
        if mode == .timeline {
            LaunchClock.reportFirstContent(
                itemCount: new.totalCount,
                provenance: new.provenance == .bootCache ? "boot-cache" : "live")
            timelineUpdates.send(new)
        }

        let isFirstPaint = previous.totalCount == 0
        let groupingChanged = new.grouping != previous.grouping
        let patchesInBackground = pendingFullTimeline == nil && searchResults == nil
            && new.totalCount > Self.backgroundBuildThreshold && !isFirstPaint && !groupingChanged
        if !patchesInBackground { dropPendingPatch() }

        if pendingFullTimeline != nil {
            pendingFullTimeline = new
            pendingFullTimelineGeneration += 1
            // A live prefix follows the timeline; a frozen grid waits for the build.
            if pendingPlaceholder == .prefix {
                let groupingChanged = new.grouping != timeline.grouping
                timeline = new.prefix(maxItems: Self.backgroundBuildThreshold)
                if searchResults == nil { applyDisplayedSnapshot(reloading: groupingChanged) }
            }
            defaultRightBarButtonItem?.menu = makeGroupingMenu()
            return
        }

        // While search results are on screen the timeline keeps updating underneath but must not
        // replace them. Leaving search re-applies whatever the timeline has become by then.
        guard searchResults == nil else {
            timeline = new
            timelineChangedDuringSearch = true
            defaultRightBarButtonItem?.menu = makeGroupingMenu()
            return
        }

        if new.totalCount <= Self.backgroundBuildThreshold {
            timeline = new
            applyDisplayedSnapshot(reloading: isFirstPaint || groupingChanged)
        } else if isFirstPaint {
            beginBackgroundBuild(of: new, placeholder: .prefix)
        } else if patchesInBackground {
            beginBackgroundPatch(to: new)
        } else {
            // Regrouping.
            beginBackgroundBuild(of: new, placeholder: .current)
        }
        defaultRightBarButtonItem?.menu = makeGroupingMenu()
    }

    func showTimelineAfterSearch() {
        let saved = timelineSnapshotBeforeSearch
        let changedDuringSearch = timelineChangedDuringSearch
        timelineSnapshotBeforeSearch = nil
        timelineChangedDuringSearch = false

        // A build still running keeps going; its placeholder just needs putting back.
        if let pending = pendingFullTimeline {
            timeline = pending.prefix(maxItems: Self.backgroundBuildThreshold)
            pendingPlaceholder = .prefix
            pendingAnchor = nil
            applyDisplayedSnapshot(reloading: true)
            return
        }

        if let saved {
            if !changedDuringSearch {
                // Fast path: timeline did not change during search, so restore directly.
                dataSource.applySnapshotUsingReloadData(saved)
                didApply(timeline)
                return
            }
            if timeline.totalCount <= Self.backgroundBuildThreshold {
                applyDisplayedSnapshot(reloading: true)
                return
            }
            beginBackgroundPatchAfterSearch(saved: saved, to: timeline)
            return
        }

        if timeline.totalCount > Self.backgroundBuildThreshold {
            beginBackgroundBuild(of: timeline, placeholder: .prefix)
        } else {
            applyDisplayedSnapshot(reloading: true)
        }
    }

    // MARK: - Background patches

    private func beginBackgroundPatchAfterSearch(saved: Snapshot, to target: TimelineSnapshot) {
        dropPendingPatch()
        patchTarget = target
        patchTargetVersion += 1
        let version = patchTargetVersion
        let generation = patchGeneration
        patchTask = Task.detached(priority: .userInitiated) { [weak self] in
            let patch = GridViewController.patch(saved, to: target)
            await self?.finishPatchAfterSearch(patch, target: target, version: version, generation: generation)
        }
    }

    private func finishPatchAfterSearch(_ patch: (snapshot: Snapshot, changed: Bool)?,
                                        target: TimelineSnapshot,
                                        version: Int,
                                        generation: Int) {
        patchTask = nil
        guard generation == patchGeneration, let latest = patchTarget else { return }

        guard let patch else {
            dropPendingPatch()
            beginBackgroundBuild(of: latest, placeholder: .prefix)
            return
        }
        timeline = target
        dataSource.applySnapshotUsingReloadData(patch.snapshot)
        didApply(target)
        if version == patchTargetVersion {
            patchTarget = nil
        } else {
            startPatch()
        }
    }

    private func beginBackgroundPatch(to target: TimelineSnapshot) {
        patchTarget = target
        patchTargetVersion += 1
        // A patch already running applies what it has, then chases this one.
        if patchTask == nil { startPatch() }
    }

    private func startPatch() {
        guard let target = patchTarget else { return }
        let base = dataSource.snapshot()
        let version = patchTargetVersion
        let generation = patchGeneration
        patchTask = Task.detached(priority: .userInitiated) { [weak self] in
            let patch = GridViewController.patch(base, to: target)
            await self?.finishPatch(patch, target: target, version: version, generation: generation)
        }
    }

    private func finishPatch(_ patch: (snapshot: Snapshot, changed: Bool)?, target: TimelineSnapshot,
                             version: Int, generation: Int) {
        patchTask = nil
        guard generation == patchGeneration, let latest = patchTarget else { return }

        guard let patch else {
            // More change than a patch covers (a bulk sync, an item moving day).
            dropPendingPatch()
            beginBackgroundBuild(of: latest, placeholder: .current)
            return
        }
        // Applied even when a newer timeline has arrived meanwhile, so a steady stream of
        // updates cannot hold the screen back indefinitely.
        timeline = target
        applyPatch(patch.snapshot, changed: patch.changed)
        if version == patchTargetVersion {
            patchTarget = nil
        } else {
            startPatch()
        }
    }

    /// For anything else about to write the data source: whatever patch is in flight was
    /// computed against contents that are about to change.
    func dropPendingPatch() {
        patchTarget = nil
        patchGeneration += 1
    }

    /// Pushes `displayed` — timeline or search results — into the diffable data source, building
    /// or patching on the main thread. Only for content small enough to do that, or a patch.
    func applyDisplayedSnapshot(reloading: Bool) {
        let current = displayed
        if !reloading, let patch = Self.patch(dataSource.snapshot(), to: current) {
            applyPatch(patch.snapshot, changed: patch.changed)
            return
        }
        var snapshot = Self.fullSnapshot(of: current)
        if reloading {
            dataSource.applySnapshotUsingReloadData(snapshot)
        } else {
            reconfigure(&snapshot, for: current)
            dataSource.apply(snapshot, animatingDifferences: true)
        }
        didApply(current)
    }

    private func applyPatch(_ patched: Snapshot, changed: Bool) {
        let current = displayed
        var snapshot = patched
        let reconfigured = reconfigure(&snapshot, for: current)
        if changed || reconfigured {
            dataSource.apply(snapshot, animatingDifferences: true)
        }
        didApply(current)
    }

    /// Content-only changes keep their identifiers, so the diff misses them entirely.
    @discardableResult
    private func reconfigure(_ snapshot: inout Snapshot, for timeline: TimelineSnapshot) -> Bool {
        let reconfigurable = timeline.reconfiguredIDs.filter { snapshot.indexOfItem($0) != nil }
        guard !reconfigurable.isEmpty else { return false }
        snapshot.reconfigureItems(reconfigurable)
        return true
    }

    func didApply(_ current: TimelineSnapshot) {
        retainSelection(in: current)
        updateStatusViews()
        updateScrubberVisibility()
    }

    /// Assets can disappear underneath a live selection (deleted here or on another device).
    private func retainSelection(in current: TimelineSnapshot) {
        // The set costs 22–30 ms at 70k items on an iPhone 13, on every update.
        guard selection.isActive else { return }
        selection.retain(only: Set(current.buckets.flatMap { $0.items.map(\.id) }))
    }

    // MARK: - Background snapshot builds

    private func beginBackgroundBuild(of target: TimelineSnapshot, placeholder: Placeholder) {
        pendingFullTimeline = target
        pendingFullTimelineGeneration += 1
        pendingPlaceholder = placeholder
        switch placeholder {
        case .prefix:
            pendingAnchor = nil
            timeline = target.prefix(maxItems: Self.backgroundBuildThreshold)
            applyDisplayedSnapshot(reloading: true)
        case .current:
            // `timeline` and the data source stay as they are, which keeps them consistent.
            pendingAnchor = topVisibleAnchor()
        }
        if fullBuildTask == nil { startFullBuild() }
    }

    /// Builds `pendingFullTimeline`'s snapshot off the main thread. Snapshots are values and may
    /// be built on any thread; only applying them is confined to the main queue.
    private func startFullBuild() {
        guard let target = pendingFullTimeline else { return }
        let generation = pendingFullTimelineGeneration
        fullBuildTask = Task.detached(priority: .userInitiated) { [weak self] in
            let snapshot = GridViewController.fullSnapshot(of: target)
            await self?.finishFullBuild(snapshot, generation: generation)
        }
    }

    private func finishFullBuild(_ built: Snapshot, generation: Int) {
        fullBuildTask = nil
        guard let latest = pendingFullTimeline else { return }

        if generation != pendingFullTimelineGeneration {
            // The timeline moved on while building. Patch off the main thread so 70k items
            // never stall the UI; if patching cannot express the delta, rebuild in the background.
            let targetGeneration = pendingFullTimelineGeneration
            fullBuildTask = Task.detached(priority: .userInitiated) { [weak self] in
                let patched = GridViewController.patch(built, to: latest)
                await self?.finishFullBuildPatch(patched?.snapshot, generation: targetGeneration)
            }
            return
        }

        let anchor = pendingAnchor
        pendingFullTimeline = nil
        pendingAnchor = nil
        timeline = latest
        defaultRightBarButtonItem?.menu = makeGroupingMenu()
        guard searchResults == nil else {
            // Search keeps the screen; leaving it restores this directly rather than rebuilding.
            timelineSnapshotBeforeSearch = built
            timelineChangedDuringSearch = false
            return
        }
        dataSource.applySnapshotUsingReloadData(built)
        if let anchor { restore(anchor) }
        didApply(latest)
    }

    private func finishFullBuildPatch(_ patched: Snapshot?, generation: Int) {
        fullBuildTask = nil
        guard pendingFullTimeline != nil else { return }
        guard let patched else {
            startFullBuild()
            return
        }
        finishFullBuild(patched, generation: generation)
    }

    private func topVisibleAnchor() -> ScrollAnchor? {
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let candidates = collectionView.indexPathsForVisibleItems.sorted()
        for indexPath in candidates {
            guard let stub = displayed.stub(at: indexPath),
                  let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame,
                  frame.maxY > top else { continue }
            return ScrollAnchor(id: stub.id, offsetFromTop: frame.minY - top)
        }
        return nil
    }

    private func restore(_ anchor: ScrollAnchor) {
        guard let indexPath = timeline.indexPath(of: anchor.id) else { return }
        collectionView.layoutIfNeeded()
        guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return }
        let inset = collectionView.adjustedContentInset
        let maxY = max(-inset.top,
                       collectionView.contentSize.height + inset.bottom - collectionView.bounds.height)
        let y = min(max(frame.minY - anchor.offsetFromTop - inset.top, -inset.top), maxY)
        collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: y), animated: false)
    }

    nonisolated static func fullSnapshot(of timeline: TimelineSnapshot) -> NSDiffableDataSourceSnapshot<String, AssetID> {
        var snapshot = NSDiffableDataSourceSnapshot<String, AssetID>()
        snapshot.appendSections(timeline.buckets.map(\.id))
        for bucket in timeline.buckets {
            snapshot.appendItems(bucket.items.map(\.id), toSection: bucket.id)
        }
        return snapshot
    }

    /// Above this many inserted plus removed items, a fresh snapshot is built instead.
    nonisolated static let maxPatchedChanges = 500

    /// Edits `snapshot` into one matching `target`, rather than building a new one.
    ///
    /// Building a snapshot with thousands of sections is dominated by a per-call cost in
    /// `appendItems(_:toSection:)`: ~3 s for 70k photos in 4k day sections on an iPhone 13, all
    /// on the main thread, where the same items appended in a single call take 60 ms. Deleting
    /// one item from the existing snapshot takes ~20 ms.
    ///
    /// Returns nil when the result does not reproduce `target` exactly (an item moved between
    /// days, sections reordered), so correctness never rests on the delta logic being complete.
    nonisolated static func patch(_ original: NSDiffableDataSourceSnapshot<String, AssetID>,
                                  to target: TimelineSnapshot)
        -> (snapshot: NSDiffableDataSourceSnapshot<String, AssetID>, changed: Bool)? {
        var snapshot = original
        guard snapshot.numberOfItems > 0 else { return nil }

        let sectionIDs = target.buckets.map(\.id)
        let itemIDs = target.buckets.flatMap { $0.items.map(\.id) }

        let oldItemIDs = snapshot.itemIdentifiers
        let oldItemSet = Set(oldItemIDs)
        let newItemSet = Set(itemIDs)
        let removed = oldItemIDs.filter { !newItemSet.contains($0) }
        let inserted = Set(itemIDs.filter { !oldItemSet.contains($0) })
        guard removed.count + inserted.count <= maxPatchedChanges else { return nil }

        let newSectionSet = Set(sectionIDs)
        let removedSections = snapshot.sectionIdentifiers.filter { !newSectionSet.contains($0) }
        var presentSections = Set(snapshot.sectionIdentifiers)
        let insertsSections = sectionIDs.contains { !presentSections.contains($0) }

        if !removed.isEmpty { snapshot.deleteItems(removed) }
        if !removedSections.isEmpty { snapshot.deleteSections(removedSections) }

        if insertsSections {
            // In target order, so each section's predecessor is already in place.
            for (i, id) in sectionIDs.enumerated() where !presentSections.contains(id) {
                if i > 0 {
                    snapshot.insertSections([id], afterSection: sectionIDs[i - 1])
                } else if let first = snapshot.sectionIdentifiers.first {
                    snapshot.insertSections([id], beforeSection: first)
                } else {
                    snapshot.appendSections([id])
                }
                presentSections.insert(id)
            }
        }

        if !inserted.isEmpty {
            // Also in target order: an item's predecessor in its bucket is either an existing
            // item or one inserted on an earlier iteration.
            for bucket in target.buckets {
                for (j, stub) in bucket.items.enumerated() where inserted.contains(stub.id) {
                    if j > 0 {
                        snapshot.insertItems([stub.id], afterItem: bucket.items[j - 1].id)
                    } else if let first = snapshot.itemIdentifiers(inSection: bucket.id).first {
                        snapshot.insertItems([stub.id], beforeItem: first)
                    } else {
                        snapshot.appendItems([stub.id], toSection: bucket.id)
                    }
                }
            }
        }

        guard snapshot.sectionIdentifiers == sectionIDs,
              snapshot.itemIdentifiers == itemIDs,
              target.buckets.allSatisfy({ snapshot.numberOfItems(inSection: $0.id) == $0.items.count })
        else { return nil }

        let changed = !removed.isEmpty || !inserted.isEmpty || !removedSections.isEmpty || insertsSections
        return (snapshot, changed)
    }
}
