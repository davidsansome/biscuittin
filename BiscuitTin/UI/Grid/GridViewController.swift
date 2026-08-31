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

    deinit { snapshotTask?.cancel() }

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
    func showExternalSnapshot(_ snapshot: TimelineSnapshot) {
        guard mode == .map, isViewLoaded else { return }
        let isFirst = timeline.isEmpty
        timeline = snapshot
        selection.retain(only: Set(snapshot.buckets.flatMap { $0.items.map(\.id) }))
        // Reload rather than diff: consecutive map regions share most of their photos but the
        // *order* is what changed, and animating a reorder of a few hundred tiles per pan is
        // both expensive and visually noisy.
        applyDisplayedSnapshot(reloading: true)
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
        // silently returns nothing.
        guard env.clipEncoder.isAvailable else {
            Log.search.info("CLIP models absent; search UI disabled")
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
            guard let self, let indexPath = self.timeline.indexPath(of: id) else { return nil }
            return self.timeline.stub(at: indexPath)
        }
        searchSession.onResults = { [weak self] results in
            self?.showSearchResults(results)
        }
    }

    private func showSearchResults(_ results: TimelineSnapshot?) {
        searchResults = results
        // A selection carried from the timeline into a result set (or back) would act on items
        // the user can no longer see.
        selection.end()
        applyDisplayedSnapshot(reloading: true)
        updateStatusViews()
        updateScrubberVisibility()
        if results != nil { collectionView.setContentOffset(.zero, animated: false) }
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
        let current = timeline.grouping
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

    private func apply(_ new: TimelineSnapshot) {
        let previousCount = timeline.totalCount
        let groupingChanged = new.grouping != timeline.grouping
        timeline = new

        // §14 P1 is about photos being visible, not just a view existing. Measured from the
        // live timeline even mid-search: it is a launch metric, not a display one.
        LaunchClock.reportFirstContent(
            itemCount: new.totalCount,
            provenance: new.provenance == .bootCache ? "boot-cache" : "live")
        defaultRightBarButtonItem?.menu = makeGroupingMenu()

        // While search results are on screen the timeline keeps updating underneath but must not
        // replace them. Cancelling search re-applies whatever the timeline has become by then.
        guard searchResults == nil else { return }

        // Animate small deltas; fall back to a straight reload for first paint, regrouping,
        // and bulk changes where diffing would cost more than it buys (§14 P3).
        let delta = abs(new.totalCount - previousCount)
        let shouldReload = previousCount == 0 || groupingChanged || delta > 500
        applyDisplayedSnapshot(reloading: shouldReload)
    }

    /// Pushes `displayed` — timeline or search results — into the diffable data source.
    private func applyDisplayedSnapshot(reloading: Bool) {
        let current = displayed

        var snapshot = Snapshot()
        snapshot.appendSections(current.buckets.map(\.id))
        for bucket in current.buckets {
            snapshot.appendItems(bucket.items.map(\.id), toSection: bucket.id)
        }

        // Content-only changes keep their identifiers, so the diff misses them entirely.
        let reconfigurable = current.reconfiguredIDs.filter { snapshot.indexOfItem($0) != nil }
        if !reconfigurable.isEmpty {
            snapshot.reconfigureItems(reconfigurable)
        }

        if reloading {
            dataSource.applySnapshotUsingReloadData(snapshot)
        } else {
            dataSource.apply(snapshot, animatingDifferences: true)
        }

        // Assets can disappear underneath a live selection (deleted here or on another device).
        selection.retain(only: Set(current.buckets.flatMap { $0.items.map(\.id) }))
        updateStatusViews()
        updateScrubberVisibility()
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
        guard grouping != timeline.grouping else { return }
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
        guard let startIndex = displayed.flatIndex(of: indexPath) else { return }
        let items = displayed.flattened()
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
