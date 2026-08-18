import UIKit
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
                           isSelected: false)
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
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "square.grid.2x2"),
            menu: makeGroupingMenu())
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

        if shouldReload {
            dataSource.applySnapshotUsingReloadData(snapshot)
        } else {
            dataSource.apply(snapshot, animatingDifferences: true)
        }

        navigationItem.rightBarButtonItem?.menu = makeGroupingMenu()
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
        openViewer(at: indexPath)
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
