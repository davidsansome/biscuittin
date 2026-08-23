import UIKit
import SwiftUI
import Combine
import Photos

/// The home screen: a date-grouped grid of every photo and video (requirements 1–4).
///
/// UIKit rather than SwiftUI (D2) because this view has to stay smooth over 100k+ items with
/// a diffable data source, custom pinch relayout, and (from M2) a custom zoom transition.
final class GridViewController: UIViewController {

    private typealias DataSource = UICollectionViewDiffableDataSource<String, AssetID>
    private typealias Snapshot = NSDiffableDataSourceSnapshot<String, AssetID>

    private let env: AppEnvironment
    private var collectionView: UICollectionView!
    private var dataSource: DataSource!
    private var pinchController: PinchColumnsController

    /// The snapshot currently on screen. Cell configuration resolves index paths against it.
    private var timeline: TimelineSnapshot
    private var columns: Int
    private var snapshotTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var hasSignalledFirstFrame = false

    private let selection = SelectionController()
    private let selectionToolbar = SelectionToolbar()
    private var selectionToolbarBottom: NSLayoutConstraint?
    private var defaultRightBarButtonItem: UIBarButtonItem?

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

    init(env: AppEnvironment) {
        self.env = env
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
        configureNavigationItem()
        configureStatusViews()
        configureSelection()
        observeStartupPhase()

        // Subscribe before kicking the boot cache so the very first snapshot is not missed.
        subscribeToSnapshots()
        Task { await env.timelineStore.loadBootSnapshot() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasSignalledFirstFrame else { return }
        hasSignalledFirstFrame = true
        // The grid is genuinely on screen now: everything deferred by D19 may start.
        env.startup.firstFrameDidRender()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        env.imageLoader.updateScreenMetrics(scale: view.window?.screen.scale ?? traitCollection.displayScale,
                                            size: view.bounds.size)
    }

    // MARK: - Setup

    private func configureCollectionView() {
        collectionView = UICollectionView(frame: view.bounds,
                                          collectionViewLayout: GridLayoutProvider.make(columns: columns))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .systemBackground
        collectionView.alwaysBounceVertical = true
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
                  indexPath.section < self.timeline.buckets.count else { return view }
            header.configure(title: self.timeline.buckets[indexPath.section].title)
            return header
        }
    }

    private func configureNavigationItem() {
        let item = UIBarButtonItem(image: UIImage(systemName: "square.grid.2x2"),
                                   menu: makeGroupingMenu())
        defaultRightBarButtonItem = item
        navigationItem.rightBarButtonItem = item
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

        selection.onChange = { [weak self] in self?.selectionDidChange() }
        selectionDidChange()
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: point),
              let stub = timeline.stub(at: indexPath) else { return }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        selection.begin(with: stub.id)
    }

    private func selectionDidChange() {
        let active = selection.isActive

        // Nav bar reflects the mode: count and Cancel while selecting, grouping menu otherwise.
        navigationItem.rightBarButtonItem = active
            ? UIBarButtonItem(title: "Cancel", style: .done, target: self,
                              action: #selector(cancelSelection))
            : defaultRightBarButtonItem
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
    }

    @objc private func cancelSelection() {
        selection.end()
    }

    private func selectionContainsRotatable() -> Bool {
        for bucket in timeline.buckets {
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

        var snapshot = Snapshot()
        snapshot.appendSections(new.buckets.map(\.id))
        for bucket in new.buckets {
            snapshot.appendItems(bucket.items.map(\.id), toSection: bucket.id)
        }

        // Animate small deltas; fall back to a straight reload for first paint, regrouping,
        // and bulk changes where diffing would cost more than it buys (§14 P3).
        let delta = abs(new.totalCount - previousCount)
        let shouldReload = previousCount == 0 || groupingChanged || delta > 500

        // Content-only changes keep their identifiers, so the diff misses them entirely.
        let reconfigurable = new.reconfiguredIDs.filter { snapshot.indexOfItem($0) != nil }
        if !reconfigurable.isEmpty {
            snapshot.reconfigureItems(reconfigurable)
        }

        if shouldReload {
            dataSource.applySnapshotUsingReloadData(snapshot)
        } else {
            dataSource.apply(snapshot, animatingDifferences: true)
        }

        defaultRightBarButtonItem?.menu = makeGroupingMenu()
        // Assets can disappear underneath a live selection (deleted here or on another device).
        selection.retain(only: Set(new.buckets.flatMap { $0.items.map(\.id) }))
        updateStatusViews()
    }

    private func stub(at indexPath: IndexPath, expecting id: AssetID) -> AssetStub? {
        if let stub = timeline.stub(at: indexPath), stub.id == id { return stub }
        // Index paths and the local snapshot can disagree for one frame mid-apply; fall back
        // to an identity lookup rather than showing the wrong photo.
        guard let fallback = timeline.indexPath(of: id) else { return nil }
        return timeline.stub(at: fallback)
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
                  let stub = timeline.stub(at: indexPath) else { continue }
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
        let isEmpty = timeline.isEmpty

        switch phase {
        case .accessDenied:
            statusLabel.text = "OnlyDaves needs access to your photo library.\nYou can grant it in Settings."
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
        let stubs = indexPaths.compactMap { timeline.stub(at: $0) }
        guard !stubs.isEmpty else { return }
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        env.imageLoader.startPrefetch(stubs, variant: .gridThumb(pointSize: currentTileSize(), scale: scale))
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        let stubs = indexPaths.compactMap { timeline.stub(at: $0) }
        guard !stubs.isEmpty else { return }
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        env.imageLoader.cancelPrefetch(stubs, variant: .gridThumb(pointSize: currentTileSize(), scale: scale))
    }
}

// MARK: - Selection

extension GridViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let stub = timeline.stub(at: indexPath) else { return }

        // In selection mode a tap adds to or removes from the selection instead of opening the
        // viewer (requirement 11).
        if selection.isActive {
            selection.toggle(stub.id)
        } else {
            openViewer(at: indexPath)
        }
    }
}

// MARK: - Viewer presentation (requirement 5)

extension GridViewController {
    /// Presents the viewer synchronously off the tap — no `await` before the animation starts
    /// (§14 P4). The flattened item list and start index both come from the snapshot already
    /// in hand.
    private func openViewer(at indexPath: IndexPath) {
        guard let startIndex = timeline.flatIndex(of: indexPath) else { return }
        let items = timeline.flattened()
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
        guard let indexPath = timeline.indexPath(of: id),
              let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return nil }
        let frameInCollectionView = attributes.frame
        // Only offer a frame when the tile is actually on screen; otherwise the animation
        // would fly in from somewhere the user cannot see.
        guard collectionView.bounds.intersects(frameInCollectionView) else { return nil }
        return collectionView.convert(frameInCollectionView, to: nil)
    }

    func viewerTransitionSourceImage(for id: AssetID) -> UIImage? {
        guard let indexPath = timeline.indexPath(of: id),
              let cell = collectionView.cellForItem(at: indexPath) as? AssetCell else { return nil }
        return cell.thumbnailImage
    }

    func viewerTransitionPrepareForDismissal(to id: AssetID) {
        guard let indexPath = timeline.indexPath(of: id), isValid(indexPath) else { return }
        // Scroll the destination tile into view so the viewer has somewhere to land.
        guard !collectionView.indexPathsForVisibleItems.contains(indexPath) else { return }
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        collectionView.layoutIfNeeded()
    }

    func viewerTransitionSetSourceHidden(_ hidden: Bool, for id: AssetID) {
        guard let indexPath = timeline.indexPath(of: id),
              let cell = collectionView.cellForItem(at: indexPath) as? AssetCell else { return }
        cell.contentView.alpha = hidden ? 0 : 1
    }
}
