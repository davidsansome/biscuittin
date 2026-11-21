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
    enum Mode: Equatable {
        /// Home screen: subscribes to the timeline, full chrome.
        case timeline
        /// A panel inside another screen, driven entirely by `showExternalSnapshot`.
        case map
        /// A partner's library (§22), pushed from the home screen. Read-only: no multi-select,
        /// and the viewer offers no rotate or delete. No search either — the index covers only
        /// the user's own photos.
        case partner(Partner)
    }

    typealias DataSource = UICollectionViewDiffableDataSource<String, AssetID>
    typealias Snapshot = NSDiffableDataSourceSnapshot<String, AssetID>

    let env: AppEnvironment
    let mode: Mode
    var collectionView: UICollectionView!
    var dataSource: DataSource!
    private var pinchController: PinchColumnsController

    /// The live, date-grouped timeline. Kept even while search results are on screen, so
    /// cancelling search restores instantly and snapshot updates keep flowing underneath.
    var timeline: TimelineSnapshot {
        didSet { fullStubsByIDCache = nil }
    }
    /// Ranked search results, when a search is active. `displayed` is what the grid draws;
    /// everything that resolves an index path must go through it, not `timeline`.
    var searchResults: TimelineSnapshot?

    /// What the collection view is currently showing.
    var displayed: TimelineSnapshot { searchResults ?? timeline }

    /// Lazily populated `[AssetID: AssetStub]` index over `fullTimeline`, invalidated whenever
    /// `timeline` or `pendingFullTimeline` changes. Keeps search result hydration and selection
    /// rotatability checks O(1) instead of scanning all buckets.
    private var fullStubsByIDCache: [AssetID: AssetStub]?

    /// Broadcasts live timeline snapshots to child/presented screens (like `MapViewController`)
    /// so `GridViewController` stays the sole consumer of `TimelineStore.snapshots`.
    let timelineUpdates = PassthroughSubject<TimelineSnapshot, Never>()

    /// The newest timeline from the store while its full snapshot is still being built off the
    /// main thread. `timeline` meanwhile holds whatever the collection view actually shows —
    /// a prefix of this, or the previous timeline — so everything resolving index paths stays
    /// consistent with the screen; anything that needs the whole library reads `fullTimeline`.
    var pendingFullTimeline: TimelineSnapshot? {
        didSet { fullStubsByIDCache = nil }
    }
    /// Bumped whenever `pendingFullTimeline` is replaced, so a finished build knows whether it
    /// is already stale.
    var pendingFullTimelineGeneration = 0
    var pendingPlaceholder = Placeholder.prefix
    /// The item to keep in place on screen when the finished build replaces the grid.
    var pendingAnchor: ScrollAnchor?
    var fullBuildTask: Task<Void, Never>?

    /// The newest timeline from the store while a patch to it is computed off the main thread
    /// (~105–150 ms at 70k items on an iPhone 13). `timeline` keeps describing what the data
    /// source shows until the patch lands.
    var patchTarget: TimelineSnapshot?
    /// Bumped whenever `patchTarget` is replaced, so a finished patch knows whether it is behind.
    var patchTargetVersion = 0
    /// Bumped when anything else takes over the data source, so a patch computed against the
    /// old contents is dropped rather than applied over the new.
    var patchGeneration = 0
    var patchTask: Task<Void, Never>?
    var fullTimeline: TimelineSnapshot { pendingFullTimeline ?? timeline }

    /// What the grid shows while a full snapshot builds in the background.
    enum Placeholder {
        /// The newest items of the target, kept live. Used when there is nothing sensible
        /// already on screen: first paint, and leaving search.
        case prefix
        /// The grid as it was, frozen. Used for regrouping and bulk changes, where a prefix
        /// would throw away the user's scroll position.
        case current
    }

    struct ScrollAnchor {
        let id: AssetID
        /// The item's top edge relative to the visible top of the collection view.
        let offsetFromTop: CGFloat
    }

    /// Item count above which a full snapshot is built in the background rather than on the
    /// main thread, and the size of the prefix shown meanwhile. Building one costs ~40 µs per
    /// item across many sections (see `patch`), so this is a few screens' worth.
    static let backgroundBuildThreshold = 1_000

    /// The timeline's snapshot as it stood when search took over the screen, so leaving search
    /// is a fast restore or background patch rather than a rebuild.
    var timelineSnapshotBeforeSearch: Snapshot?
    var timelineChangedDuringSearch = false

    private var columns: Int
    var snapshotTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var hasSignalledFirstFrame = false

    let selection = SelectionController()
    private let selectionToolbar = SelectionToolbar()
    private var selectionToolbarBottom: NSLayoutConstraint?
    private var isPerformingAction = false
    var defaultRightBarButtonItem: UIBarButtonItem?
    private var mapBarButtonItem: UIBarButtonItem?
    /// Shown only while someone shares a library with the user (§22), so it costs nothing to
    /// everyone else.
    private var partnersBarButtonItem: UIBarButtonItem?
    private var partners: [Partner] = []
    private var partnersTask: Task<Void, Never>?
    /// Whether the first snapshot has arrived, so an empty partner library is not reported as
    /// empty before it has been read.
    var hasReceivedSnapshot = false

    private var desiredIndexingPaused = false
    private var appliedIndexingPaused = false
    private var indexingPauseTask: Task<Void, Never>?

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

    private let backupInfoBar = BackupInfoBar()
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
        partnersTask?.cancel()
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

        if case let .partner(partner) = mode {
            title = partner.name
            configureDateScrubber()
            subscribeToSnapshots(env.partnerLibrary.snapshots(of: partner, grouping: env.settings.grouping))
            updateStatusViews()
            return
        }

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
        configureBackupInfoBar()
        observeStartupPhase()

        // Subscribe before kicking the boot cache so the very first snapshot is not missed.
        subscribeToSnapshots(env.timelineStore.snapshots)
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
        // Reading partners opens the database, which D19 keeps off the launch path.
        observePartners()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        setIndexingPaused(false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        env.imageLoader.updateScreenMetrics(scale: view.window?.screen.scale ?? effectiveDisplayScale,
                                            size: view.bounds.size)
        updateScrubberVisibility()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        if selection.isActive {
            updateSelectionInsets()
        }
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

        // The map panel is fed a filtered snapshot and has nothing of its own to refresh (D9).
        if mode != .map {
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
            self.configure(cell, with: stub)
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
        navigationItem.rightBarButtonItems = defaultRightBarButtonItems
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
    ///
    /// Doubles as the expired-session notice: every remote photo not already cached stops
    /// loading when the token dies, and Settings is otherwise the only place that says why.
    private func observeBackupStatus() {
        env.backupStatus.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateBackupIndicator() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: ImmichAuthSession.stateDidChangeNotification,
                                             object: env.immichSession)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateBackupIndicator() }
            .store(in: &cancellables)
        updateBackupIndicator()
    }

    private func updateBackupIndicator() {
        var config = UIButton.Configuration.plain()
        config.imagePadding = 4
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)

        updateBackupInfoBar()

        if env.immichSession.state == .expired {
            backupIndicatorItem.isHidden = false
            config.image = UIImage(systemName: "exclamationmark.icloud",
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 15,
                                                                                  weight: .medium))
            config.title = "Sign In"
            config.baseForegroundColor = .systemOrange
            backupIndicatorButton.configuration = config
            backupIndicatorButton.accessibilityLabel = "Immich session expired. Sign in again."
            return
        }

        let status = env.backupStatus
        guard status.isEnabled else {
            backupIndicatorItem.isHidden = true
            return
        }
        backupIndicatorItem.isHidden = false

        config.image = UIImage(systemName: status.indicatorSymbol,
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 15,
                                                                              weight: .medium))
        // No count beside the icon: the info bar under the navigation bar shows it.
        config.baseForegroundColor = status.remainingCount > 0 ? .secondaryLabel : .systemGreen
        backupIndicatorButton.configuration = config
        backupIndicatorButton.accessibilityLabel = status.remainingCount > 0
            ? "\(status.remainingCount) items waiting to back up"
            : "All items backed up"
    }

    /// Sits just below the navigation bar. It extends the safe area rather than overlapping the
    /// grid, so the collection view's insets, the date scrubber and the empty-state label all
    /// stay clear of it without knowing it exists.
    private func configureBackupInfoBar() {
        backupInfoBar.translatesAutoresizingMaskIntoConstraints = false
        backupInfoBar.isHidden = true
        backupInfoBar.addAction(UIAction { [weak self] _ in self?.presentSettings() }, for: .touchUpInside)
        view.addSubview(backupInfoBar)
        NSLayoutConstraint.activate([
            backupInfoBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backupInfoBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backupInfoBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            backupInfoBar.heightAnchor.constraint(equalToConstant: BackupInfoBar.height)
        ])
    }

    private func updateBackupInfoBar() {
        guard mode == .timeline else { return }
        let status = env.backupStatus
        // An expired session has its own notice in the nav bar, and nothing uploads until it
        // is renewed, so progress here would only be stale.
        let text = env.immichSession.state == .expired ? nil : status.infoBarText
        if text != nil, let count = status.progressText {
            backupInfoBar.configure(title: status.stateTitle, rate: status.rateText, count: count,
                                    symbol: status.infoBarSymbol, progress: status.progress)
            setBackupInfoBarVisible(true)
        } else {
            setBackupInfoBarVisible(false)
        }
    }

    private func setBackupInfoBarVisible(_ visible: Bool) {
        let inset = visible ? BackupInfoBar.height : 0
        guard additionalSafeAreaInsets.top != inset else { return }

        // Keep a grid that is scrolled to the top showing its first row; anywhere else, the
        // content stays put and the bar simply covers or uncovers a strip of it.
        let wasAtTop = collectionView.contentOffset.y <= -collectionView.adjustedContentInset.top + 1
        additionalSafeAreaInsets.top = inset
        backupInfoBar.isHidden = !visible
        view.layoutIfNeeded()
        if wasAtTop {
            collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x,
                                                    y: -collectionView.adjustedContentInset.top),
                                            animated: false)
        }
    }

    /// The non-selecting right-hand items, outermost first.
    private var defaultRightBarButtonItems: [UIBarButtonItem] {
        [mapBarButtonItem, partnersBarButtonItem, defaultRightBarButtonItem].compactMap { $0 }
    }

    private var isPartnerLibrary: Bool {
        if case .partner = mode { return true }
        return false
    }

    // MARK: - Partner sharing (§22)

    /// Keeps the partners button in step with who shares with the user. Each sync that touches
    /// partner data re-reads the list, and so does a sign-in or sign-out, which wipe it.
    private func observePartners() {
        guard mode == .timeline, partnersTask == nil else { return }
        partnersTask = Task { [weak self] in
            let changes = NotificationCenter.default.notifications(
                named: RemoteLibraryService.partnersDidChangeNotification)
            var iterator = changes.makeAsyncIterator()
            repeat {
                guard let library = self?.env.partnerLibrary else { return }
                let partners = await library.partners()
                self?.updatePartners(partners)
            } while await iterator.next() != nil
        }
    }

    private func updatePartners(_ new: [Partner]) {
        guard new != partners else { return }
        partners = new
        partnersBarButtonItem = makePartnersBarButtonItem()
        if !selection.isActive {
            navigationItem.rightBarButtonItems = defaultRightBarButtonItems
        }
    }

    /// One partner opens straight away; several are listed in a menu, which saves an
    /// intermediate screen with nothing on it but names.
    private func makePartnersBarButtonItem() -> UIBarButtonItem? {
        guard !partners.isEmpty else { return nil }
        let image = UIImage(systemName: partners.count == 1 ? "person" : "person.2")
        let item: UIBarButtonItem
        if partners.count == 1, let partner = partners.first {
            item = UIBarButtonItem(image: image, primaryAction: UIAction { [weak self] _ in
                self?.openPartnerLibrary(partner)
            })
            item.accessibilityLabel = "\(partner.name)’s photos"
        } else {
            let actions = partners.map { partner in
                UIAction(title: partner.name, image: UIImage(systemName: "person")) { [weak self] _ in
                    self?.openPartnerLibrary(partner)
                }
            }
            item = UIBarButtonItem(image: image, menu: UIMenu(title: "Shared with You", children: actions))
            item.accessibilityLabel = "Partners’ photos"
        }
        return item
    }

    /// Pushed rather than presented: it is another grid of photos, and the back button and
    /// edge swipe are how the user returns to their own.
    private func openPartnerLibrary(_ partner: Partner) {
        let library = GridViewController(env: env, mode: .partner(partner))
        navigationController?.pushViewController(library, animated: true)
    }

    /// Full screen: the map owns the whole window, and its own close button dismisses it
    /// (§20.2). A sheet would put a second dismissal affordance next to that one.
    @objc private func presentMap() {
        let map = MapViewController(env: env, timelineUpdates: timelineUpdates.eraseToAnyPublisher())
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
            self?.fullStubsByID()[id]
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
            timelineChangedDuringSearch = false
        }
        if results != nil, let target = patchTarget {
            // Search takes the screen; leaving it patches the saved snapshot to the newest timeline.
            dropPendingPatch()
            timeline = target
            timelineChangedDuringSearch = true
        }
        searchResults = results
        // A selection carried from the timeline into a result set (or back) would act on items
        // the user can no longer see.
        selection.end()
        if results == nil {
            showTimelineAfterSearch()
        } else {
            applyDisplayedSnapshot(reloading: true)
            collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top),
                                            animated: false)
        }
        updateStatusViews()
        updateScrubberVisibility()
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
        dateScrubber.onScrubBegin = { [weak self] in self?.setIndexingPaused(true) }
        dateScrubber.onScrub = { [weak self] fraction in self?.scrub(toFraction: fraction) }
        dateScrubber.onScrubEnd = { [weak self] in self?.setIndexingPaused(false) }
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

    func updateScrubberVisibility() {
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
        collectionView.layoutIfNeeded()
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
            : defaultRightBarButtonItems
        title = active
            ? (selection.isEmpty ? "Select Items" : "\(selection.count) Selected")
            : "Photos"

        selectionToolbar.update(selectionCount: selection.count,
                                canRotateAny: selectionContainsRotatable())

        updateSelectionInsets()

        UIView.animate(withDuration: 0.22) { self.view.layoutIfNeeded() }
        refreshSelectionAppearance()
        updateScrubberVisibility()
    }

    private func updateSelectionInsets() {
        let active = selection.isActive
        let height = SelectionToolbar.contentHeight + view.safeAreaInsets.bottom
        selectionToolbarBottom?.constant = active ? -height : 0
        collectionView.contentInset.bottom = active ? height : 0
        collectionView.verticalScrollIndicatorInsets.bottom = active ? height : 0
    }

    @objc private func cancelSelection() {
        selection.end()
    }

    private func fullStubsByID() -> [AssetID: AssetStub] {
        if let cached = fullStubsByIDCache { return cached }
        var map = [AssetID: AssetStub](minimumCapacity: fullTimeline.totalCount)
        for bucket in fullTimeline.buckets {
            for stub in bucket.items {
                map[stub.id] = stub
            }
        }
        fullStubsByIDCache = map
        return map
    }

    private func selectionContainsRotatable() -> Bool {
        guard !selection.isEmpty else { return false }
        let lookup = fullStubsByID()
        for id in selection.selected {
            if let stub = lookup[id], env.photoActions.canRotate(stub.kind) { return true }
        }
        return false
    }

    /// Updates check overlays in place rather than reloading, so toggling never re-requests a
    /// thumbnail or animates the tile (§14 P4).
    private func refreshSelectionAppearance() {
        for case let cell as AssetCell in collectionView.visibleCells {
            guard let id = cell.representedID else { continue }
            cell.setSelected(selection.isActive && selection.contains(id))
        }
    }

    private func rotateSelection(clockwise: Bool) {
        guard !isPerformingAction else { return }
        let ids = selection.orderedIDs
        guard !ids.isEmpty else { return }

        isPerformingAction = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isPerformingAction = false }
            let outcome = await self.env.photoActions.rotate(ids: ids, clockwise: clockwise)
            if let message = Toast.message(for: outcome, verb: "rotated") {
                Toast.show(message, in: self.view)
            }
            self.selection.end()
        }
    }

    private func deleteSelection() {
        guard !isPerformingAction else { return }
        let ids = selection.orderedIDs
        guard !ids.isEmpty else { return }

        isPerformingAction = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isPerformingAction = false }
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
        guard !isPerformingAction else { return }
        let ids = selection.orderedIDs
        guard !ids.isEmpty else { return }

        isPerformingAction = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isPerformingAction = false }
            let (items, failures) = await self.env.shareService.activityItems(for: ids)
            guard !items.isEmpty else {
                let message = failures.first?.error.userMessage ?? "Couldn’t share the selection."
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
        guard presentedViewController == nil else { return false }
        return await withCheckedContinuation { continuation in
            let noun = plan.total == 1 ? "item" : "\(plan.total) items"
            let alert = UIAlertController(
                title: "Delete \(noun)?",
                message: "This deletes from this \(DeviceName.current) and moves the copy on Immich to its trash.",
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

    func makeGroupingMenu() -> UIMenu {
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

    /// Pull-to-refresh (D9): a manual `sync/stream` catch-up, including any server-side deletes.
    private func handlePullToRefresh() {
        let isPartnerLibrary = isPartnerLibrary
        Task { [weak self] in
            guard let startup = self?.env.startup else { return }
            if isPartnerLibrary {
                await startup.pullToRefreshPartners()
            } else {
                await startup.pullToRefresh()
            }
            self?.collectionView.refreshControl?.endRefreshing()
        }
    }

    private func stub(at indexPath: IndexPath, expecting id: AssetID) -> AssetStub? {
        if let stub = displayed.stub(at: indexPath), stub.id == id { return stub }
        // Index paths and the local snapshot can disagree for one frame mid-apply; fall back
        // to an identity lookup rather than showing the wrong photo.
        if searchResults == nil, let cached = fullStubsByID()[id] { return cached }
        guard let fallback = displayed.indexPath(of: id) else { return nil }
        return displayed.stub(at: fallback)
    }

    private func configure(_ cell: AssetCell, with stub: AssetStub, tileSize: CGSize? = nil) {
        cell.configure(stub: stub,
                       loader: env.imageLoader,
                       tileSize: tileSize ?? currentTileSize(),
                       isSelected: selection.isActive && selection.contains(stub.id),
                       showsCloudBadge: !isPartnerLibrary)
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
            configure(cell, with: stub, tileSize: tileSize)
        }
    }

    // MARK: - Status / empty states

    private func observeStartupPhase() {
        env.startup.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusViews() }
            .store(in: &cancellables)
    }

    func updateStatusViews() {
        let phase = env.startup.phase
        let isEmpty = displayed.isEmpty

        if case let .partner(partner) = mode {
            statusLabel.text = !isEmpty ? nil
                : hasReceivedSnapshot ? "\(partner.name) hasn’t shared any photos yet." : "Loading…"
            statusLabel.isHidden = !isEmpty
            settingsButton.isHidden = true
            return
        }

        if mode == .map {
            statusLabel.text = isEmpty ? "No photos in this area." : nil
            statusLabel.isHidden = !isEmpty
            settingsButton.isHidden = true
            return
        }

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
    private func prefetchPayload(for indexPaths: [IndexPath]) -> (stubs: [AssetStub], variant: ImageVariant)? {
        let stubs = indexPaths.compactMap { displayed.stub(at: $0) }
        guard !stubs.isEmpty else { return nil }
        return (stubs, .gridThumb(pointSize: currentTileSize(), scale: effectiveDisplayScale))
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard let payload = prefetchPayload(for: indexPaths) else { return }
        env.imageLoader.startPrefetch(payload.stubs, variant: payload.variant)
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        guard let payload = prefetchPayload(for: indexPaths) else { return }
        env.imageLoader.cancelPrefetch(payload.stubs, variant: payload.variant)
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
        desiredIndexingPaused = paused
        guard indexingPauseTask == nil else { return }
        indexingPauseTask = Task { [weak self] in
            while let self, self.appliedIndexingPaused != self.desiredIndexingPaused {
                let next = self.desiredIndexingPaused
                await self.env.searchIndexer.setPaused(next)
                self.appliedIndexingPaused = next
            }
            self?.indexingPauseTask = nil
        }
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
                                           source: self,
                                           library: isPartnerLibrary ? .partner : .own)
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
