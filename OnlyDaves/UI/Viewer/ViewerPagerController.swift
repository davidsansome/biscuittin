import UIKit
import AVFoundation
import SwiftUI

/// Full-screen viewer (requirements 5–9).
///
/// A horizontally-paging collection view rather than `UIPageViewController`: it reuses pages,
/// keeps memory flat over a long swipe run, and gives direct control over the paging offset
/// during the dismissal drag.
final class ViewerPagerController: UIViewController {

    // MARK: - Dependencies

    private let env: AppEnvironment
    private let metadataService: MetadataService
    private let videoProvider: VideoPlaybackProvider

    // MARK: - State

    private var items: [AssetStub]
    private(set) var currentIndex: Int
    private var isChromeVisible = true
    private var fullResolutionToken: ImageRequestToken?

    // MARK: - Views

    private let backdropView = UIView()
    private let contentContainer = UIView()
    private var collectionView: UICollectionView!
    private let toolbar = ViewerToolbar()

    private let transitionDelegate = ViewerTransitionDelegate()
    private weak var transitionSource: ViewerTransitionSource?

    /// Distance the dismissal drag must travel before releasing commits to it.
    private let dismissThreshold: CGFloat = 110

    init(env: AppEnvironment,
         items: [AssetStub],
         startIndex: Int,
         source: ViewerTransitionSource?) {
        self.env = env
        self.metadataService = MetadataService(resolver: env.assetResolver)
        self.videoProvider = VideoPlaybackProvider(resolver: env.assetResolver)
        self.items = items
        self.currentIndex = max(0, min(startIndex, max(0, items.count - 1)))
        self.transitionSource = source
        super.init(nibName: nil, bundle: nil)

        modalPresentationStyle = .overFullScreen
        modalPresentationCapturesStatusBarAppearance = true
        transitionDelegate.source = source
        transitionDelegate.viewerFrameProvider = { [weak self] in self?.currentTransitionGeometry() }
        transitioningDelegate = transitionDelegate
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var prefersStatusBarHidden: Bool { !isChromeVisible }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        backdropView.backgroundColor = .black
        backdropView.frame = view.bounds
        backdropView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(backdropView)

        contentContainer.frame = view.bounds
        contentContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(contentContainer)

        configureCollectionView()
        configureToolbar()
        configureDismissGesture()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout,
           layout.itemSize != collectionView.bounds.size,
           collectionView.bounds.size != .zero {
            layout.itemSize = collectionView.bounds.size
            layout.invalidateLayout()
            // Keep the current page pinned across a bounds change (rotation).
            collectionView.setContentOffset(
                CGPoint(x: CGFloat(currentIndex) * collectionView.bounds.width, y: 0),
                animated: false)
        }
        env.imageLoader.updateScreenMetrics(scale: view.window?.screen.scale ?? traitCollection.displayScale,
                                            size: view.bounds.size)
        updateVideoControlInsets()
    }

    /// Keeps video transport controls clear of the toolbar. Must run at layout time: safe-area
    /// insets are still zero when cells are first configured, which would let the scrubber
    /// collide with the toolbar buttons.
    private func updateVideoControlInsets() {
        let inset = ViewerToolbar.contentHeight + view.safeAreaInsets.bottom + 8
        for case let cell as ViewerPageCell in collectionView.visibleCells {
            cell.videoView.bottomInset = inset
        }
    }

    private var currentVideoControlInset: CGFloat {
        ViewerToolbar.contentHeight + view.safeAreaInsets.bottom + 8
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        activateCurrentPage()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        currentCell()?.videoView.pause()
    }

    // MARK: - Setup

    private func configureCollectionView() {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = .zero

        collectionView = UICollectionView(frame: contentContainer.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.isPagingEnabled = true
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(ViewerPageCell.self, forCellWithReuseIdentifier: ViewerPageCell.reuseIdentifier)
        contentContainer.addSubview(collectionView)

        // Jump to the tapped asset before the first frame so no intermediate page is shown.
        collectionView.performBatchUpdates(nil) { [weak self] _ in
            guard let self, self.currentIndex > 0 else { return }
            self.collectionView.scrollToItem(at: IndexPath(item: self.currentIndex, section: 0),
                                             at: .centeredHorizontally, animated: false)
        }
    }

    private func configureToolbar() {
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: ViewerToolbar.contentHeight + 90)
        ])

        toolbar.onBack = { [weak self] in self?.dismissViewer() }
        toolbar.onInfo = { [weak self] in self?.presentInfoSheet() }
        toolbar.onRotateLeft = { [weak self] in self?.rotateCurrent(clockwise: false) }
        toolbar.onRotateRight = { [weak self] in self?.rotateCurrent(clockwise: true) }
        toolbar.onDelete = { [weak self] in self?.deleteCurrent() }
    }

    private func configureDismissGesture() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        pan.delegate = self
        contentContainer.addGestureRecognizer(pan)
    }

    // MARK: - Chrome (requirement 7)

    private func toggleChrome() {
        setChromeVisible(!isChromeVisible, animated: true)
    }

    private func setChromeVisible(_ visible: Bool, animated: Bool) {
        guard visible != isChromeVisible else { return }
        isChromeVisible = visible

        let apply = {
            self.toolbar.alpha = visible ? 1 : 0
            self.setNeedsStatusBarAppearanceUpdate()
        }
        animated ? UIView.animate(withDuration: 0.22, animations: apply) : apply()
        currentCell()?.setChromeVisible(visible, animated: animated)
    }

    // MARK: - Paging

    private func currentCell() -> ViewerPageCell? {
        collectionView.cellForItem(at: IndexPath(item: currentIndex, section: 0)) as? ViewerPageCell
    }

    private func updateCurrentIndexFromScroll() {
        guard collectionView.bounds.width > 0 else { return }
        let page = Int((collectionView.contentOffset.x / collectionView.bounds.width).rounded())
        let clamped = max(0, min(page, items.count - 1))
        guard clamped != currentIndex else { return }

        // Leaving a video page: stop playback and release the player immediately.
        if let leaving = collectionView.cellForItem(at: IndexPath(item: currentIndex, section: 0)) as? ViewerPageCell {
            leaving.videoView.detachPlayer()
            leaving.resetZoom(animated: false)
        }
        currentIndex = clamped
        activateCurrentPage()
    }

    /// Starts video playback for the page that just became current (§13.2).
    private func activateCurrentPage() {
        guard items.indices.contains(currentIndex) else { return }
        let stub = items[currentIndex]
        toolbar.setRotationAvailable(env.photoActions.canRotate(stub.kind))
        currentCell()?.setChromeVisible(isChromeVisible, animated: false)

        guard stub.kind == .video, let cell = currentCell() else { return }
        cell.videoView.showLoading()

        let task = Task { [weak self, weak cell] in
            guard let self else { return }
            guard let asset = await self.env.timelineStore.asset(for: stub.id) else { return }
            do {
                let item = try await self.videoProvider.playerItem(for: asset)
                try Task.checkCancellation()
                await MainActor.run {
                    guard let cell, cell.stub?.id == stub.id else { return }
                    self.videoProvider.activateAudioSessionForPlayback()
                    cell.videoView.attach(player: AVPlayer(playerItem: item), autoplay: true)
                    cell.setChromeVisible(self.isChromeVisible, animated: false)
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard let cell, cell.stub?.id == stub.id else { return }
                    cell.videoView.showError("This video isn’t available.")
                }
            }
        }
        cell.videoView.setLoadTask(task)
    }

    private func requestFullResolution(for stub: AssetStub) {
        env.imageLoader.cancel(fullResolutionToken)
        fullResolutionToken = env.imageLoader.requestImage(for: stub, variant: .fullResolution) {
            [weak self] image, degraded in
            guard let self, !degraded, let image else { return }
            self.currentCell()?.applyFullResolution(image, for: stub.id)
        }
    }

    // MARK: - Dismissal (requirement 6)

    private func dismissViewer() {
        currentCell()?.videoView.pause()
        dismiss(animated: true)
    }

    @objc private func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)

        switch gesture.state {
        case .changed:
            let progress = min(1, max(0, translation.y / (view.bounds.height * 0.6)))
            let scale = 1 - progress * 0.25
            contentContainer.transform = CGAffineTransform(translationX: translation.x * 0.6,
                                                           y: translation.y)
                .scaledBy(x: scale, y: scale)
            backdropView.alpha = 1 - progress * 0.9
            toolbar.alpha = isChromeVisible ? max(0, 1 - progress * 3) : 0

        case .ended, .cancelled:
            let shouldDismiss = gesture.state == .ended
                && (translation.y > dismissThreshold || velocity.y > 900)
            if shouldDismiss {
                dismissViewer()
            } else {
                UIView.animate(withDuration: 0.28,
                               delay: 0,
                               usingSpringWithDamping: 0.85,
                               initialSpringVelocity: 0.4,
                               options: [.curveEaseOut]) {
                    self.contentContainer.transform = .identity
                    self.backdropView.alpha = 1
                    self.toolbar.alpha = self.isChromeVisible ? 1 : 0
                }
            }
        default:
            break
        }
    }

    // MARK: - Rotate and delete (requirement 10)

    /// Optimistic: the on-screen image turns immediately and the real edit runs behind it,
    /// reverting with a toast on failure (§14 P4). No `await` precedes the visible effect.
    private func rotateCurrent(clockwise: Bool) {
        guard items.indices.contains(currentIndex) else { return }
        let stub = items[currentIndex]
        guard env.photoActions.canRotate(stub.kind) else {
            Toast.show("This item can’t be rotated yet.", in: view)
            return
        }
        guard let cell = currentCell() else { return }

        cell.previewRotation(clockwise: clockwise)

        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.env.photoActions.rotate(ids: [stub.id], clockwise: clockwise)
            guard !outcome.succeeded.isEmpty else {
                self.currentCell()?.revertPreviewRotation()
                let message = Toast.message(for: outcome, verb: "rotated")
                    ?? outcome.firstError?.localizedDescription
                    ?? "Rotation failed."
                Toast.show(message, in: self.view)
                return
            }
            // The real rendition has different dimensions; reload the page so it re-fits.
            self.reloadCurrentPageAfterEdit()
        }
    }

    private func deleteCurrent() {
        guard items.indices.contains(currentIndex) else { return }
        let stub = items[currentIndex]

        Task { [weak self] in
            guard let self else { return }
            let plan = await self.env.photoActions.deletePlan(ids: [stub.id])
            if plan.needsInAppConfirmation {
                guard await self.confirmDelete(plan: plan) else { return }
            }
            let outcome = await self.env.photoActions.delete(ids: [stub.id])
            guard !outcome.succeeded.isEmpty else {
                if let error = outcome.firstError {
                    Toast.show(error.localizedDescription, in: self.view)
                }
                return
            }
            self.advanceAfterDeleting(stub.id)
        }
    }

    /// Confirms deletions that reach the server (D11). Purely local deletions rely on the
    /// system's own confirmation and never reach here.
    private func confirmDelete(plan: DeletePlan) async -> Bool {
        await withCheckedContinuation { continuation in
            let count = plan.total
            let noun = count == 1 ? "item" : "\(count) items"
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

    /// Moves to the next asset after a delete, or leaves if that was the last one.
    private func advanceAfterDeleting(_ id: AssetID) {
        guard let removed = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: removed)

        guard !items.isEmpty else {
            dismiss(animated: true)
            return
        }
        currentIndex = min(removed, items.count - 1)
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
        collectionView.setContentOffset(
            CGPoint(x: CGFloat(currentIndex) * collectionView.bounds.width, y: 0), animated: false)
        activateCurrentPage()
    }

    private func reloadCurrentPageAfterEdit() {
        let indexPath = IndexPath(item: currentIndex, section: 0)
        guard indexPath.item < items.count else { return }
        collectionView.reloadItems(at: [indexPath])
        activateCurrentPage()
    }

    // MARK: - Info sheet (requirement 9)

    private func presentInfoSheet() {
        guard items.indices.contains(currentIndex) else { return }
        let stub = items[currentIndex]

        // Opens immediately with the stub-derived subset and fills in as sources resolve.
        let viewModel = InfoViewModel(stub: stub,
                                      timelineStore: env.timelineStore,
                                      metadataService: metadataService)
        let host = UIHostingController(rootView: InfoSheet(viewModel: viewModel))
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(host, animated: true)
    }

    // MARK: - Transition geometry

    private func currentTransitionGeometry() -> (frame: CGRect, image: UIImage?, id: AssetID)? {
        guard items.indices.contains(currentIndex) else { return nil }
        let stub = items[currentIndex]

        guard let cell = currentCell() else {
            return (view.bounds, nil, stub.id)
        }

        if stub.kind == .video {
            // Videos fly to/from the poster frame's aspect-fit rect.
            let frame = cell.videoView.convert(cell.videoView.bounds, to: nil)
            return (frame, nil, stub.id)
        }

        guard let imageView = cell.displayedImageView, let image = imageView.image else {
            return (view.bounds, nil, stub.id)
        }
        let frame = imageView.superview?.convert(imageView.frame, to: nil)
            ?? imageView.convert(imageView.bounds, to: nil)
        return (frame, image, stub.id)
    }
}

// MARK: - Data source

extension ViewerPagerController: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ViewerPageCell.reuseIdentifier,
                                                      for: indexPath)
        guard let page = cell as? ViewerPageCell, items.indices.contains(indexPath.item) else { return cell }

        page.configure(stub: items[indexPath.item],
                       loader: env.imageLoader,
                       toolbarInset: currentVideoControlInset)
        page.onSingleTap = { [weak self] in self?.toggleChrome() }
        page.onNeedsFullResolution = { [weak self] stub in self?.requestFullResolution(for: stub) }
        page.setChromeVisible(isChromeVisible, animated: false)
        return page
    }
}

// MARK: - Delegate

extension ViewerPagerController: UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        collectionView.bounds.size
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateCurrentIndexFromScroll()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        updateCurrentIndexFromScroll()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { updateCurrentIndexFromScroll() }
    }
}

// MARK: - Gesture arbitration

extension ViewerPagerController: UIGestureRecognizerDelegate {
    /// The dismissal drag only takes over when the gesture is clearly vertical and the page is
    /// not zoomed in — otherwise horizontal paging and pan-while-zoomed keep priority (§13.2).
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        guard currentCell()?.isAtMinimumZoom ?? true else { return false }
        let velocity = pan.velocity(in: view)
        return abs(velocity.y) > abs(velocity.x) && velocity.y > 0
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }
}
