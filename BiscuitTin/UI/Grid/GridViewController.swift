import UIKit
import SwiftUI
import Combine
import Photos

/// The home screen: a date-grouped grid of every photo and video (requirements 1–4).
///
/// UIKit rather than SwiftUI (D2) because this view has to stay smooth over 100k+ items with
/// a diffable data source, custom pinch relayout, and (from M2) a custom zoom transition.
final class GridViewController: UIViewController {

    /// Where this grid is being used. The home screen owns the timeline and its chrome; the map
    /// panel (§20) is handed a filtered snapshot and must not draw a search bar, a date scrubber
    /// or navigation items of its own.
    enum Mode {
        /// Home screen: subscribes to the timeline, full chrome.
        case timeline
        /// A panel inside another screen, driven entirely by `showExternalSnapshot`.
        case map
    }

    private typealias DataSource = UICollectionViewDiffableDataSource<String, AssetID>
    private typealias Snapshot = NSDiffableDataSourceSnapshot<String, AssetID>

    private let env: AppEnvironment
    private let mode: Mode
    private var collectionView: UICollectionView!
    private var dataSource: DataSource!
    private var pinchController: PinchColumnsController

    /// The live, date-grouped timeline. Kept even while search results are on screen, so
    /// cancelling search restores instantly and snapshot updates keep flowing underneath.
    private var timeline: TimelineSnapshot
    /// Ranked search results, when a search is active. `displayed` is what the grid draws;
    /// everything that resolves an index path must go through it, not `timeline`.
    private var searchResults: TimelineSnapshot?

    /// What the collection view is currently showing.
    private var displayed: TimelineSnapshot { searchResults ?? timeline }

    /// The newest timeline from the store while its full snapshot is still being built off the
    /// main thread. `timeline` meanwhile holds whatever the collection view actually shows —
    /// a prefix of this, or the previous timeline — so everything resolving index paths stays
    /// consistent with the screen; anything that needs the whole library reads `fullTimeline`.
    private var pendingFullTimeline: TimelineSnapshot?
    /// Bumped whenever `pendingFullTimeline` is replaced, so a finished build knows whether it
    /// is already stale.
    private var pendingFullTimelineGeneration = 0
    private var pendingPlaceholder = Placeholder.prefix
    /// The item to keep in place on screen when the finished build replaces the grid.
    private var pendingAnchor: ScrollAnchor?
    private var fullBuildTask: Task<Void, Never>?

    /// The newest timeline from the store while a patch to it is computed off the main thread
    /// (~105–150 ms at 70k items on an iPhone 13). `timeline` keeps describing what the data
    /// source shows until the patch lands.
    private var patchTarget: TimelineSnapshot?
    /// Bumped whenever `patchTarget` is replaced, so a finished patch knows whether it is behind.
    private var patchTargetVersion = 0
    /// Bumped when anything else takes over the data source, so a patch computed against the
    /// old contents is dropped rather than applied over the new.
    private var patchGeneration = 0
    private var patchTask: Task<Void, Never>?
    private var fullTimeline: TimelineSnapshot { pendingFullTimeline ?? timeline }

    /// What the grid shows while a full snapshot builds in the background.
    private enum Placeholder {
        /// The newest items of the target, kept live. Used when there is nothing sensible
        /// already on screen: first paint, and leaving search.
        case prefix
        /// The grid as it was, frozen. Used for regrouping and bulk changes, where a prefix
        /// would throw away the user's scroll position.
        case current
    }

    private struct ScrollAnchor {
        let id: AssetID
        /// The item's top edge relative to the visible top of the collection view.
        let offsetFromTop: CGFloat
    }

    /// Item count above which a full snapshot is built in the background rather than on the
    /// main thread, and the size of the prefix shown meanwhile. Building one costs ~40 µs per
    /// item across many sections (see `patch`), so this is a few screens' worth.
    private static let backgroundBuildThreshold = 1_000

    /// The timeline's snapshot as it stood when search took over the screen, so leaving search
    /// is a patch rather than a rebuild.
    private var timelineSnapshotBeforeSearch: Snapshot?

    private var columns: Int
    private var snapshotTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var hasSignalledFirstFrame = false

    private let selection = SelectionController()
    private let selectionToolbar = SelectionToolbar()
    private var selectionToolbarBottom: NSLayoutConstraint?
    private var defaultRightBarButtonItem: UIBarButtonItem?
    private var mapBarButtonItem: UIBarButtonItem?

    private let dateScrubber = DateScrubber()

    private var searchController: UISearchController?
    private lazy var searchSession = SearchSessionController(engine: env.searchEngine)

    private lazy var statusLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.numberOfLines = 0
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .body)
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var backupIndicatorButton = UIButton(type: .system)
    private lazy var backupIndicatorItem: UIBarButtonItem = {
        let item = UIBarButtonItem(customView: backupIndicatorButton)
        item.isHidden = true
        backupIndicatorButton.addAction(UIAction { [weak self] _ in
            self?.presentSettings()
        }, for: .touchUpInside)
        return item
    }()

    private lazy var settingsButton: UIButton = {
        var config = UIButton.Configuration.borderedProminent()
        config.title = "Open Settings"
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        })
        button.isHidden = true
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    init(env: AppEnvironment, mode: Mode = .timeline) {
        self.env = env
        self.mode = mode
        self.columns = env.settings.gridColumns
        self.pinchController = PinchColumnsController(columns: env.settings.gridColumns)
        self.timeline = .empty(grouping: env.settings.grouping, provenance: .bootCache)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        snapshotTask?.cancel()
        fullBuildTask?.cancel()
        patchTask?.cancel()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Photos"
        navigationItem.largeTitleDisplayMode = .never

        configureCollectionView()
        configureDataSource()
        configureStatusViews()

        guard mode == .timeline else {
            // The map panel gets its content pushed in; everything below drives or decorates the
            // home screen's own timeline.
            configureSelection()
            return
        }

        // Before `configureSelection`: its initial `selectionDidChange` installs the right-hand
        // bar items, and would otherwise install them while they are still nil.
        configureNavigationItem()
        configureSelection()
        configureDateScrubber()
        configureSearch()
        observeStartupPhase()

        // Subscribe before kicking the boot cache so the very first snapshot is not missed.
        subscribeToSnapshots()
        Task { await env.timelineStore.loadBootSnapshot() }
    }

    /// Displays a snapshot chosen by an owning screen (the map's region filter, §20). Only valid
    /// in `.map` mode; the timeline grid publishes its own content.
    ///
    /// `built` is `fullSnapshot(of: snapshot)` made off the main thread by the caller; a region
    /// can hold tens of thousands of photos.
    func showExternalSnapshot(_ snapshot: TimelineSnapshot,
                              built: NSDiffableDataSourceSnapshot<String, AssetID>) {
        guard mode == .map, isViewLoaded else { return }
        let isFirst = timeline.isEmpty
        timeline = snapshot
        // Reload rather than diff: consecutive map regions share most of their photos but the
        // *order* is what changed, and animating a reorder of a few hundred tiles per pan is
        // both expensive and visually noisy.
        dataSource.applySnapshotUsingReloadData(built)
        didApply(snapshot)
        if !isFirst { collectionView.setContentOffset(.zero, animated: false) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard mode == .timeline, !hasSignalledFirstFrame else { return }
        hasSignalledFirstFrame = true
        // §14 P1: measured here because this is the first moment the grid is actually visible.
        LaunchClock.reportFirstFrame(
            itemCount: timeline.totalCount,
            provenance: timeline.provenance == .bootCache ? "boot-cache" : "live")
        // The grid is genuinely on screen now: everything deferred by D19 may start.
        env.startup.firstFrameDidRender()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        env.imageLoader.updateScreenMetrics(scale: view.window?.screen.scale ?? traitCollection.displayScale,
                                            size: view.bounds.size)
        updateScrubberVisibility()
    }

    // MARK: - Setup

    private func configureCollectionView() {
        collectionView = UICollectionView(frame: view.bounds,
                                          collectionViewLayout: GridLayoutProvider.make(columns: columns))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .systemBackground
        collectionView.alwaysBounceVertical = true
        // The date scrubber replaces the system indicator; showing both is a duplicate. The map
        // panel has no scrubber, so there it keeps the system one.
        collectionView.showsVerticalScrollIndicator = (mode == .map)
        collectionView.register(AssetCell.self, forCellWithReuseIdentifier: AssetCell.reuseIdentifier)
        collectionView.register(BucketHeaderView.self,
                                forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                withReuseIdentifier: BucketHeaderView.reuseIdentifier)
        collectionView.prefetchDataSource = self
        collectionView.isPrefetchingEnabled = true
        collectionView.delegate = self
        view.addSubview(collectionView)

        // Only the home screen owns a live server connection; the map panel is fed a filtered
        // snapshot and has nothing of its own to refresh (D9).
        if mode == .timeline {
            let refresh = UIRefreshControl()
            refresh.addAction(UIAction { [weak self] _ in self?.handlePullToRefresh() }, for: .valueChanged)
            collectionView.refreshControl = refresh
        }

        let pinch = UIPinchGestureRecognizer(target: pinchController,
                                             action: #selector(PinchColumnsController.handle(_:)))
        collectionView.addGestureRecognizer(pinch)
        pinchController.onChange = { [weak self] columns, centroid in
            self?.setColumns(columns, anchoredAt: centroid)
        }
    }

    private func configureDataSource() {
        dataSource = DataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, itemID in
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: AssetCell.reuseIdentifier,
                                                          for: indexPath)
            guard let self, let cell = cell as? AssetCell else { return cell }
            guard let stub = self.stub(at: indexPath, expecting: itemID) else { return cell }
            cell.configure(stub: stub,
                           loader: self.env.imageLoader,
                           tileSize: self.currentTileSize(),
                           isSelected: self.selection.isActive && self.selection.contains(stub.id))
            return cell
        }

        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            guard kind == UICollectionView.elementKindSectionHeader else { return nil }
            let view = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: BucketHeaderView.reuseIdentifier,
                for: indexPath)
            guard let self, let header = view as? BucketHeaderView,
                  indexPath.section < self.displayed.buckets.count else { return view }
            header.configure(title: self.displayed.buckets[indexPath.section].title)
            return header
        }
    }

    private func configureNavigationItem() {
        let item = UIBarButtonItem(image: UIImage(systemName: "square.grid.2x2"),
                                   menu: makeGroupingMenu())
        defaultRightBarButtonItem = item
        mapBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "map"),
                                           style: .plain,
                                           target: self,
                                           action: #selector(presentMap))
        mapBarButtonItem?.accessibilityLabel = "Map"
        // `rightBarButtonItems` is ordered right-to-left, so the map sits outermost.
        navigationItem.rightBarButtonItems = [mapBarButtonItem, item].compactMap { $0 }
        navigationItem.leftBarButtonItems = [
            UIBarButtonItem(image: UIImage(systemName: "gearshape"),
                            style: .plain,
                            target: self,
                            action: #selector(presentSettings)),
            backupIndicatorItem
        ]
        observeBackupStatus()
    }

    /// Requirement 14: cloud glyph plus the outstanding count, hidden when sync is off.
    private func observeBackupStatus() {
        env.backupStatus.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateBackupIndicator() }
            .store(in: &cancellables)
        updateBackupIndicator()
    }

    private func updateBackupIndicator() {
        let status = env.backupStatus
        guard status.isEnabled else {
            backupIndicatorItem.isHidden = true
            return
        }
        backupIndicatorItem.isHidden = false

        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: status.indicatorSymbol,
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 15,
                                                                              weight: .medium))
        config.title = status.indicatorText
        config.imagePadding = 4
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        config.baseForegroundColor = status.remainingCount > 0 ? .secondaryLabel : .systemGreen
        backupIndicatorButton.configuration = config
        backupIndicatorButton.accessibilityLabel = status.remainingCount > 0
            ? "\(status.remainingCount) items waiting to back up"
            : "All items backed up"
    }

    /// Full screen: the map owns the whole window, and its own close button dismisses it
    /// (§20.2). A sheet would put a second dismissal affordance next to that one.
    @objc private func presentMap() {
        let map = MapViewController(env: env)
        map.modalPresentationStyle = .fullScreen
        present(map, animated: true)
    }

    @objc private func presentSettings() {
        let host = UIHostingController(rootView: SettingsScreen(viewModel: env.makeSettingsViewModel()))
        present(host, animated: true)
    }

    // MARK: - Multi-select (requirement 11)

    private func configureSelection() {
        let longPress = UILongPressGestureRecognizer(target: self,
                                                     action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.4
        collectionView.addGestureRecognizer(longPress)

        selectionToolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(selectionToolbar)
        let bottom = selectionToolbar.topAnchor.constraint(equalTo: view.bottomAnchor)
        selectionToolbarBottom = bottom
        NSLayoutConstraint.activate([
            selectionToolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            selectionToolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            selectionToolbar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottom
        ])

        selectionToolbar.onCancel = { [weak self] in self?.selection.end() }
        selectionToolbar.onRotateLeft = { [weak self] in self?.rotateSelection(clockwise: false) }
        selectionToolbar.onRotateRight = { [weak self] in self?.rotateSelection(clockwise: true) }
        selectionToolbar.onDelete = { [weak self] in self?.deleteSelection() }
        selectionToolbar.onShare = { [weak self] in self?.shareSelection() }

        selection.onChange = { [weak self] in self?.selectionDidChange() }
        selectionDidChange()
    }

    // MARK: - Search (requirement 15)

    private func configureSearch() {
        // Search is unavailable rather than broken when the CLIP resources were never fetched
        // (Tools/fetch_models.sh is a manual build step) — no bar at all beats one that
        // silently returns nothing. The absence itself must not be silent, though: builds from a
        // fresh git worktree lacked the gitignored models and shipped without a search bar for
        // weeks, unnoticed, because this line was `.info` and never reached a device console.
        guard env.clipEncoder.isAvailable else {
            Log.device("search", "CLIP models absent from the bundle; search UI disabled. "
                       + "Run Tools/fetch_models.sh and rebuild.")
            return
        }

        let controller = UISearchController(searchResultsController: nil)
        controller.searchResultsUpdater = self
        controller.delegate = self
        controller.obscuresBackgroundDuringPresentation = false
        controller.searchBar.placeholder = "Search your photos"
        controller.searchBar.autocapitalizationType = .none
        navigationItem.searchController = controller
        navigationItem.hidesSearchBarWhenScrolling = true
        definesPresentationContext = true
        searchController = controller

        searchSession.stubProvider = { [weak self] id in
            guard let self, let indexPath = self.fullTimeline.indexPath(of: id) else { return nil }
            return self.fullTimeline.stub(at: indexPath)
        }
        searchSession.onResults = { [weak self] results in
            self?.showSearchResults(results)
        }
    }

    private func showSearchResults(_ results: TimelineSnapshot?) {
        // Cancelling reports "no results" more than once; the timeline is already showing.
        if results == nil, searchResults == nil { return }
        if searchResults == nil, results != nil, pendingFullTimeline == nil {
            timelineSnapshotBeforeSearch = dataSource.snapshot()
        }
        if results != nil, let target = patchTarget {
            // Search takes the screen; leaving it patches the saved snapshot to the newest timeline.
            dropPendingPatch()
            timeline = target
        }
        searchResults = results
        // A selection carried from the timeline into a result set (or back) would act on items
        // the user can no longer see.
        selection.end()
        if results == nil {
            showTimelineAfterSearch()
        } else {
            applyDisplayedSnapshot(reloading: true)
            collectionView.setContentOffset(.zero, animated: false)
        }
        updateStatusViews()
        updateScrubberVisibility()
    }

    private func showTimelineAfterSearch() {
        let saved = timelineSnapshotBeforeSearch
        timelineSnapshotBeforeSearch = nil
        // A build still running keeps going; its placeholder just needs putting back.
        if let pending = pendingFullTimeline {
            timeline = pending.prefix(maxItems: Self.backgroundBuildThreshold)
            pendingPlaceholder = .prefix
            pendingAnchor = nil
            applyDisplayedSnapshot(reloading: true)
            return
        }
        if let saved, let patch = Self.patch(saved, to: timeline) {
            var snapshot = patch.snapshot
            let reconfigurable = timeline.reconfiguredIDs.filter { snapshot.indexOfItem($0) != nil }
            if !reconfigurable.isEmpty { snapshot.reconfigureItems(reconfigurable) }
            dataSource.applySnapshotUsingReloadData(snapshot)
            retainSelection(in: timeline)
            return
        }
        if timeline.totalCount > Self.backgroundBuildThreshold {
            beginBackgroundBuild(of: timeline, placeholder: .prefix)
        } else {
            applyDisplayedSnapshot(reloading: true)
        }
    }

    // MARK: - Date scrubber (fast-scroll index)

    private func configureDateScrubber() {
        dateScrubber.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dateScrubber)
        NSLayoutConstraint.activate([
            dateScrubber.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dateScrubber.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            dateScrubber.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            dateScrubber.widthAnchor.constraint(equalToConstant: DateScrubber.hitTargetWidth)
        ])
        dateScrubber.onScrub = { [weak self] fraction in self?.scrub(toFraction: fraction) }
    }

    /// Total scrollable distance, accounting for content insets — 0 (or negative) when
    /// everything already fits on screen, which is also when the scrubber has nothing to do.
    private func scrollableContentHeight() -> CGFloat {
        let insets = collectionView.adjustedContentInset
        return collectionView.contentSize.height + insets.top + insets.bottom
            - collectionView.bounds.height
    }

    private func currentScrollFraction() -> CGFloat {
        let scrollable = scrollableContentHeight()
        guard scrollable > 0 else { return 0 }
        let offset = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        return max(0, min(1, offset / scrollable))
    }

    private func updateScrubberVisibility() {
        // Search results are ranked by relevance, not date, so a date scrubber over them would
        // be lying about what it scrolls to.
        dateScrubber.isHidden = selection.isActive
            || searchResults != nil
            || scrollableContentHeight() <= 0
    }

    /// Jumps the grid to a normalized position and reports which bucket landed at the top, for
    /// the scrubber's bubble. Mirrors the system scroll indicator's own travel range 1:1 rather
    /// than modelling section heights separately — the compositional layout already knows the
    /// true (self-sized) geometry, so asking it after the jump is simpler and can't drift out of
    /// sync with what the layout actually did.
    private func scrub(toFraction fraction: CGFloat) -> String? {
        let scrollable = scrollableContentHeight()
        guard scrollable > 0 else { return nil }
        let y = fraction * scrollable - collectionView.adjustedContentInset.top
        collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        return topmostVisibleBucketTitle()
    }

    private func topmostVisibleBucketTitle() -> String? {
        guard let indexPath = collectionView.indexPathsForVisibleItems.min(),
              indexPath.section < displayed.buckets.count else { return nil }
        return displayed.buckets[indexPath.section].title
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: point),
              let stub = displayed.stub(at: indexPath) else { return }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        selection.begin(with: stub.id)
    }

    private func selectionDidChange() {
        let active = selection.isActive

        // Nav bar reflects the mode: count and Cancel while selecting, grouping menu otherwise.
        navigationItem.rightBarButtonItems = active
            ? [UIBarButtonItem(title: "Cancel", style: .done, target: self,
                               action: #selector(cancelSelection))]
            : [mapBarButtonItem, defaultRightBarButtonItem].compactMap { $0 }
        title = active
            ? (selection.isEmpty ? "Select Items" : "\(selection.count) Selected")
            : "Photos"

        selectionToolbar.update(selectionCount: selection.count,
                                canRotateAny: selectionContainsRotatable())

        let height = SelectionToolbar.contentHeight + view.safeAreaInsets.bottom
        selectionToolbarBottom?.constant = active ? -height : 0
        collectionView.contentInset.bottom = active ? height : 0
        collectionView.verticalScrollIndicatorInsets.bottom = active ? height : 0

        UIView.animate(withDuration: 0.22) { self.view.layoutIfNeeded() }
        refreshSelectionAppearance()
        updateScrubberVisibility()
    }

    @objc private func cancelSelection() {
        selection.end()
    }

    private func selectionContainsRotatable() -> Bool {
        for bucket in displayed.buckets {
            for stub in bucket.items where selection.contains(stub.id) {
                if env.photoActions.canRotate(stub.kind) { return true }
            }
        }
        return false
    }

    /// Updates check overlays in place rather than reloading, so toggling never re-requests a
    /// thumbnail or animates the tile (§14 P4).
    private func refreshSelectionAppearance() {
        for case let cell as AssetCell in collectionView.visibleCells {
            guard let id = cell.representedID else { continue }
            cell.setSelected(selection.isActive && selection.contains(id), animated: false)
        }
    }

    private func rotateSelection(clockwise: Bool) {
        let ids = selection.orderedIDs
        guard !ids.isEmpty else { return }

        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.env.photoActions.rotate(ids: ids, clockwise: clockwise)
            if let message = Toast.message(for: outcome, verb: "rotated") {
                Toast.show(message, in: self.view)
            }
            self.selection.end()
        }
    }

    private func deleteSelection() {
        let ids = selection.orderedIDs
        guard !ids.isEmpty else { return }

        Task { [weak self] in
            guard let self else { return }
            let plan = await self.env.photoActions.deletePlan(ids: ids)
            if plan.needsInAppConfirmation, await !self.confirmDelete(plan: plan) { return }

            let outcome = await self.env.photoActions.delete(ids: ids)
            if let message = Toast.message(for: outcome, verb: "deleted") {
                Toast.show(message, in: self.view)
            }
            self.selection.end()
        }
    }

    private func shareSelection() {
        let ids = selection.orderedIDs
        guard !ids.isEmpty else { return }

        Task { [weak self] in
            guard let self else { return }
            let (items, failures) = await self.env.shareService.activityItems(for: ids)
            guard !items.isEmpty else {
                let message = (failures.first?.error as? LocalizedError)?.errorDescription
                    ?? failures.first?.error.localizedDescription
                    ?? "Couldn’t share the selection."
                Toast.show(message, in: self.view)
                return
            }
            if !failures.isEmpty {
                let noun = failures.count == 1 ? "1 item" : "\(failures.count) items"
                Toast.show("\(noun) couldn’t be shared", in: self.view)
            }
            self.presentActivity(items: items, anchor: self.selectionToolbar.shareButton)
        }
    }

    /// Anchors the iPad popover on the button that opened it; a nil `sourceView` crashes on
    /// iPad the first time the share sheet is presented from a regular (non-compact) size class.
    private func presentActivity(items: [Any], anchor: UIView) {
        let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = anchor
            popover.sourceRect = anchor.bounds
        }
        present(activityVC, animated: true)
    }

    private func confirmDelete(plan: DeletePlan) async -> Bool {
        await withCheckedContinuation { continuation in
            let noun = plan.total == 1 ? "item" : "\(plan.total) items"
            let alert = UIAlertController(
                title: "Delete \(noun)?",
                message: "This deletes from this iPhone and moves the copy on Immich to its trash.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                continuation.resume(returning: false)
            })
            alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
                continuation.resume(returning: true)
            })
            present(alert, animated: true)
        }
    }

    private func configureStatusViews() {
        view.addSubview(statusLabel)
        view.addSubview(settingsButton)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            settingsButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            settingsButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16)
        ])
    }

    private func makeGroupingMenu() -> UIMenu {
        // The chosen grouping, even while the grid still shows the previous one during a build.
        let current = fullTimeline.grouping
        let actions = Grouping.allCases.map { grouping in
            UIAction(title: grouping.localizedName,
                     state: grouping == current ? .on : .off) { [weak self] _ in
                self?.setGrouping(grouping)
            }
        }
        return UIMenu(title: "Group by", children: actions)
    }

    // MARK: - Snapshot plumbing

    private func subscribeToSnapshots() {
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in self.env.timelineStore.snapshots {
                await MainActor.run { self.apply(snapshot) }
            }
        }
    }

    /// Pull-to-refresh (D9): a manual `sync/stream` catch-up, including any server-side deletes.
    private func handlePullToRefresh() {
        Task { [weak self] in
            guard let self else { return }
            await self.env.startup.pullToRefresh()
            await MainActor.run { self.collectionView.refreshControl?.endRefreshing() }
        }
    }

    private func apply(_ new: TimelineSnapshot) {
        let previous = patchTarget ?? fullTimeline

        // §14 P1 is about photos being visible, not just a view existing. Measured from the
        // live timeline even mid-search: it is a launch metric, not a display one.
        LaunchClock.reportFirstContent(
            itemCount: new.totalCount,
            provenance: new.provenance == .bootCache ? "boot-cache" : "live")

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

    // MARK: - Background patches

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
    private func dropPendingPatch() {
        patchTarget = nil
        patchGeneration += 1
    }

    /// Pushes `displayed` — timeline or search results — into the diffable data source, building
    /// or patching on the main thread. Only for content small enough to do that, or a patch.
    private func applyDisplayedSnapshot(reloading: Bool) {
        let current = displayed
        if !reloading, let patch = Self.patch(dataSource.snapshot(), to: current) {
            applyPatch(patch.snapshot, changed: patch.changed)
            return
        }
        var snapshot = Self.fullSnapshot(of: current)
        reconfigure(&snapshot, for: current)
        if reloading {
            dataSource.applySnapshotUsingReloadData(snapshot)
        } else {
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

    private func didApply(_ current: TimelineSnapshot) {
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

        var snapshot = built
        if generation != pendingFullTimelineGeneration {
            // The timeline moved on while building. Usually a small delta; a regroup or a
            // bulk sync is not, and gets another background build rather than a main-thread one.
            guard let patched = Self.patch(built, to: latest) else {
                startFullBuild()
                return
            }
            snapshot = patched.snapshot
        }

        let anchor = pendingAnchor
        pendingFullTimeline = nil
        pendingAnchor = nil
        timeline = latest
        defaultRightBarButtonItem?.menu = makeGroupingMenu()
        guard searchResults == nil else {
            // Search keeps the screen; leaving it patches from this rather than rebuilding.
            timelineSnapshotBeforeSearch = snapshot
            return
        }
        dataSource.applySnapshotUsingReloadData(snapshot)
        if let anchor { restore(anchor) }
        didApply(latest)
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

    private func stub(at indexPath: IndexPath, expecting id: AssetID) -> AssetStub? {
        if let stub = displayed.stub(at: indexPath), stub.id == id { return stub }
        // Index paths and the local snapshot can disagree for one frame mid-apply; fall back
        // to an identity lookup rather than showing the wrong photo.
        guard let fallback = displayed.indexPath(of: id) else { return nil }
        return displayed.stub(at: fallback)
    }

    private func currentTileSize() -> CGSize {
        GridLayoutProvider.tileSize(forWidth: collectionView.bounds.width, columns: columns)
    }

    // MARK: - Grouping and zoom

    private func setGrouping(_ grouping: Grouping) {
        guard grouping != fullTimeline.grouping else { return }
        Task { await env.timelineStore.setGrouping(grouping) }
    }

    private func setColumns(_ newColumns: Int, anchoredAt point: CGPoint) {
        guard newColumns != columns else { return }
        let anchorIndexPath = collectionView.indexPathForItem(at: point)
            ?? collectionView.indexPathsForVisibleItems.min()

        columns = newColumns
        env.settings.gridColumns = newColumns
        env.imageLoader.resetCaches()

        collectionView.setCollectionViewLayout(GridLayoutProvider.make(columns: newColumns),
                                               animated: true) { [weak self] _ in
            guard let self else { return }
            if let anchorIndexPath, self.isValid(anchorIndexPath) {
                self.collectionView.scrollToItem(at: anchorIndexPath, at: .centeredVertically,
                                                 animated: false)
            }
            // Tiles changed size, so visible thumbnails need re-requesting at the new scale.
            self.reconfigureVisibleCells()
            self.updateScrubberVisibility()
        }
    }

    private func isValid(_ indexPath: IndexPath) -> Bool {
        indexPath.section < collectionView.numberOfSections
            && indexPath.item < collectionView.numberOfItems(inSection: indexPath.section)
    }

    private func reconfigureVisibleCells() {
        let tileSize = currentTileSize()
        for case let cell as AssetCell in collectionView.visibleCells {
            guard let indexPath = collectionView.indexPath(for: cell),
                  let stub = displayed.stub(at: indexPath) else { continue }
            cell.configure(stub: stub, loader: env.imageLoader, tileSize: tileSize, isSelected: false)
        }
    }

    // MARK: - Status / empty states

    private func observeStartupPhase() {
        env.startup.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusViews() }
            .store(in: &cancellables)
    }

    private func updateStatusViews() {
        let phase = env.startup.phase
        let isEmpty = displayed.isEmpty

        // A search with no matches is not an empty library; saying so would read as data loss.
        if searchSession.isSearching {
            statusLabel.text = isEmpty ? "No photos match that search." : nil
            statusLabel.isHidden = !isEmpty
            settingsButton.isHidden = true
            return
        }

        switch phase {
        case .accessDenied:
            statusLabel.text = "Biscuit Tin needs access to your photo library.\nYou can grant it in Settings."
            statusLabel.isHidden = false
            settingsButton.isHidden = false
        case .ready where isEmpty:
            statusLabel.text = "No photos or videos yet."
            statusLabel.isHidden = false
            settingsButton.isHidden = true
        default:
            statusLabel.isHidden = !isEmpty
            statusLabel.text = isEmpty ? "Loading your library…" : nil
            settingsButton.isHidden = true
        }
    }
}

// MARK: - Prefetching

extension GridViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let stubs = indexPaths.compactMap { displayed.stub(at: $0) }
        guard !stubs.isEmpty else { return }
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        env.imageLoader.startPrefetch(stubs, variant: .gridThumb(pointSize: currentTileSize(), scale: scale))
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        let stubs = indexPaths.compactMap { displayed.stub(at: $0) }
        guard !stubs.isEmpty else { return }
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        env.imageLoader.cancelPrefetch(stubs, variant: .gridThumb(pointSize: currentTileSize(), scale: scale))
    }
}

// MARK: - Selection

extension GridViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let stub = displayed.stub(at: indexPath) else { return }

        // In selection mode a tap adds to or removes from the selection instead of opening the
        // viewer (requirement 11).
        if selection.isActive {
            selection.toggle(stub.id)
        } else {
            openViewer(at: indexPath)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        dateScrubber.scrollFraction = currentScrollFraction()
    }

    // §14 P6: search indexing yields while the user is scrolling. Embedding a batch competes
    // for the same CPU as cell configuration, and the grid must win.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        setIndexingPaused(true)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { setIndexingPaused(false) }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        setIndexingPaused(false)
    }

    private func setIndexingPaused(_ paused: Bool) {
        Task { await env.searchIndexer.setPaused(paused) }
    }
}

// MARK: - Search (requirement 15)

extension GridViewController: UISearchResultsUpdating, UISearchControllerDelegate {
    func updateSearchResults(for searchController: UISearchController) {
        searchSession.update(query: searchController.searchBar.text ?? "")
    }

    func willPresentSearchController(_ searchController: UISearchController) {
        // Parse the vocabulary and warm the text encoder now, so the first keystroke is not the
        // thing that pays for them (P8).
        searchSession.begin()
    }

    func didDismissSearchController(_ searchController: UISearchController) {
        // Frees the tokenizer tables and the text encoder's weights, and restores the timeline —
        // which may have moved on while results were on screen.
        searchSession.end()
    }
}

// MARK: - Viewer presentation (requirement 5)

extension GridViewController {
    /// Presents the viewer synchronously off the tap — no `await` before the animation starts
    /// (§14 P4). The flattened item list and start index both come from the snapshot already
    /// in hand.
    private func openViewer(at indexPath: IndexPath) {
        // A prefix shares its index paths with the full timeline, so the start index holds and
        // the viewer can page past what the grid has drawn so far. A frozen grid does not.
        let source = searchResults
            ?? (pendingFullTimeline != nil && pendingPlaceholder == .prefix ? fullTimeline : timeline)
        guard let startIndex = displayed.flatIndex(of: indexPath) else { return }
        let items = source.flattened()
        guard !items.isEmpty else { return }

        let viewer = ViewerPagerController(env: env,
                                           items: items,
                                           startIndex: startIndex,
                                           source: self)
        present(viewer, animated: true)
    }
}

// MARK: - Zoom transition source

extension GridViewController: ViewerTransitionSource {
    func viewerTransitionSourceFrame(for id: AssetID) -> CGRect? {
        guard let indexPath = displayed.indexPath(of: id),
              let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return nil }
        let frameInCollectionView = attributes.frame
        // Only offer a frame when the tile is actually on screen; otherwise the animation
        // would fly in from somewhere the user cannot see.
        guard collectionView.bounds.intersects(frameInCollectionView) else { return nil }
        return collectionView.convert(frameInCollectionView, to: nil)
    }

    func viewerTransitionSourceImage(for id: AssetID) -> UIImage? {
        guard let indexPath = displayed.indexPath(of: id),
              let cell = collectionView.cellForItem(at: indexPath) as? AssetCell else { return nil }
        return cell.thumbnailImage
    }

    func viewerTransitionPrepareForDismissal(to id: AssetID) {
        guard let indexPath = displayed.indexPath(of: id), isValid(indexPath) else { return }
        // Scroll the destination tile into view so the viewer has somewhere to land.
        guard !collectionView.indexPathsForVisibleItems.contains(indexPath) else { return }
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        collectionView.layoutIfNeeded()
    }

    func viewerTransitionSetSourceHidden(_ hidden: Bool, for id: AssetID) {
        guard let indexPath = displayed.indexPath(of: id),
              let cell = collectionView.cellForItem(at: indexPath) as? AssetCell else { return }
        cell.contentView.alpha = hidden ? 0 : 1
    }
}
