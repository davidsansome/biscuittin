import UIKit
import VisionKit

/// One full-screen page. Hosts either a zoomable image or a video player, depending on the
/// asset's `MediaKind` (D3).
final class ViewerPageCell: UICollectionViewCell {
    static let reuseIdentifier = "ViewerPageCell"

    let photoView = ZoomablePhotoView()
    let videoView = VideoPlayerPageView()

    private(set) var stub: AssetStub?
    private var token: ImageRequestToken?
    private var fullResolutionToken: ImageRequestToken?
    private var thumbnailToken: ImageRequestToken?
    private var hasPreview = false
    private var hasFullResolution = false
    private weak var loader: ImageLoader?

    /// The first full-quality rendition delivered, kept so Live Text can run on it once the
    /// page becomes current. Degraded frames are too soft to read text from.
    private var liveTextSource: UIImage?
    private var liveTextTask: Task<Void, Never>?
    private var isCurrentPage = false

    /// Carries the optimistic rotation (§14 P4).
    ///
    /// Deliberately *not* `photoView.imageView`: that is the scroll view's `viewForZooming`,
    /// and `UIScrollView` implements `zoomScale` through its transform. Setting the transform
    /// there clobbers the zoom, snapping the image to 1:1 with its full pixel size — which on a
    /// real photo reads as "zoomed all the way in".
    fileprivate let rotationOverlay = UIImageView()
    fileprivate var previewRotationAngle: CGFloat = 0

    var onSingleTap: (() -> Void)?
    /// Fires when the page's Live Text state changes: analysis finished, highlight mode or
    /// text selection toggled.
    var onLiveTextChange: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear

        photoView.frame = contentView.bounds
        photoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(photoView)

        videoView.frame = contentView.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        videoView.isHidden = true
        contentView.addSubview(videoView)

        photoView.onSingleTap = { [weak self] in self?.onSingleTap?() }
        videoView.onSingleTap = { [weak self] in self?.onSingleTap?() }
        photoView.onZoomedIn = { [weak self] in self?.requestFullResolution() }
        photoView.onLiveTextChange = { [weak self] in self?.onLiveTextChange?() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        loader?.cancel(token)
        loader?.cancel(fullResolutionToken)
        loader?.cancel(thumbnailToken)
        token = nil
        fullResolutionToken = nil
        thumbnailToken = nil
        hasPreview = false
        hasFullResolution = false
        stub = nil
        liveTextTask?.cancel()
        liveTextTask = nil
        liveTextSource = nil
        isCurrentPage = false
        photoView.setLiveTextAnalysis(nil)
        clearRotationOverlay()
        photoView.setImage(nil, resetZoom: true)
        videoView.detachPlayer()
        videoView.setPoster(nil)
        videoView.isHidden = true
        photoView.isHidden = false
    }

    /// The view actually showing content, used by the zoom transition for its geometry.
    var displayedImageView: UIImageView? {
        stub?.kind == .video ? nil : photoView.imageView
    }

    func configure(stub: AssetStub, loader: ImageLoader, toolbarInset: CGFloat) {
        self.stub = stub
        self.loader = loader

        let isVideo = stub.kind == .video
        photoView.isHidden = isVideo
        videoView.isHidden = !isVideo
        videoView.bottomInset = toolbarInset

        // `.opportunistic` delivers a cached low-resolution frame almost immediately and then
        // upgrades, which is what keeps a local page from ever showing empty (§14 P4). A remote
        // preview has no such first frame — it is a download — so the grid's thumbnail stands
        // in until it lands. Requested first so that, when both are cached, it is delivered
        // first.
        if stub.isRemoteOnly { showThumbnail(for: stub, loader: loader) }

        token = loader.requestImage(for: stub, variant: .viewerPreview) { [weak self] image, degraded in
            guard let self, self.stub?.id == stub.id else { return }
            guard let image else {
                if !degraded, self.thumbnailToken == nil { self.showThumbnail(for: stub, loader: loader) }
                return
            }
            // A late preview must not undo the native-resolution rendition already on screen.
            guard !self.hasFullResolution else { return }
            self.hasPreview = true
            if isVideo {
                self.videoView.setPoster(image)
            } else {
                self.photoView.setImage(image, resetZoom: self.photoView.imageView.image == nil)
                if !degraded { self.offerLiveTextSource(image) }
            }
        }
    }

    /// Shows the grid's thumbnail while the preview downloads, or instead of it when the
    /// preview cannot be had, rather than an empty black page. For a remote photo it is almost
    /// always cached already, since the user just tapped it in the grid — which is also what
    /// still works while the server is unreachable or the session has expired. Never offered to
    /// Live Text: it is too small to read text from.
    private func showThumbnail(for stub: AssetStub, loader: ImageLoader) {
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        thumbnailToken = loader.requestImage(for: stub,
                                             variant: .gridThumb(pointSize: contentView.bounds.size,
                                                                 scale: scale)) { [weak self] image, _ in
            // An uncached thumbnail is itself a download, and may lose the race to the preview.
            guard let self, self.stub?.id == stub.id, let image,
                  !self.hasPreview, !self.hasFullResolution else { return }
            if stub.kind == .video {
                self.videoView.setPoster(image)
            } else {
                self.photoView.setImage(image, resetZoom: self.photoView.imageView.image == nil)
            }
        }
    }

    /// Fetches the photo's native-resolution pixels, once, for the page the user is zooming.
    ///
    /// Owned by the cell rather than the pager: a single pager-wide request was cancelled by
    /// whichever page asked next, and a delivery that landed after the user had paged on was
    /// discarded for belonging to a different asset. Since the trigger is one-shot, a page that
    /// lost its request that way stayed on the screen-sized preview however far it was zoomed.
    private func requestFullResolution() {
        guard let stub, stub.kind != .video, let loader,
              !hasFullResolution, fullResolutionToken == nil else { return }

        fullResolutionToken = loader.requestImage(for: stub, variant: .fullResolution) {
            [weak self] image, degraded in
            guard let self, !degraded, let image, self.stub?.id == stub.id else { return }
            self.hasFullResolution = true
            self.photoView.setImage(image, resetZoom: false)
            self.offerLiveTextSource(image)
        }
    }

    // MARK: - Live Text (D25)

    /// Analysis runs only for the page the user has settled on, never for neighbours being
    /// prefetched or pages flicked past (§14 P1).
    func setCurrentPage(_ current: Bool) {
        isCurrentPage = current
        if current {
            analyzeLiveTextIfNeeded()
        } else {
            liveTextTask?.cancel()
            liveTextTask = nil
            photoView.resetLiveText()
        }
    }

    var liveTextHasText: Bool { stub?.kind != .video && photoView.liveTextHasText }

    var isLiveTextHighlighted: Bool {
        get { photoView.isLiveTextHighlighted }
        set { photoView.isLiveTextHighlighted = newValue }
    }

    var hasActiveTextSelection: Bool { photoView.hasActiveTextSelection }

    private func offerLiveTextSource(_ image: UIImage) {
        guard liveTextSource == nil else { return }
        liveTextSource = image
        analyzeLiveTextIfNeeded()
    }

    private func analyzeLiveTextIfNeeded() {
        guard isCurrentPage, LiveText.isSupported, let stub, stub.kind != .video,
              let image = liveTextSource, liveTextTask == nil,
              !photoView.hasLiveTextAnalysis else { return }

        liveTextTask = Task { [weak self] in
            let analysis: ImageAnalysis
            do {
                analysis = try await LiveText.analyze(image)
            } catch {
                guard !Task.isCancelled else { return }
                Log.device("ui", "Live Text analysis failed for \(stub.id.raw): \(error)")
                self?.liveTextTask = nil
                return
            }
            guard let self, !Task.isCancelled, self.stub?.id == stub.id else { return }
            self.liveTextTask = nil
            self.photoView.setLiveTextAnalysis(analysis)
            self.onLiveTextChange?()
        }
    }

    func resetZoom(animated: Bool) {
        photoView.resetZoom(animated: animated)
    }

    /// Turns the displayed image immediately so the tap has a visible effect before the real
    /// edit completes (§14 P4). `revertPreviewRotation` undoes it if the edit fails.
    func previewRotation(clockwise: Bool) {
        guard stub?.kind != .video, let image = photoView.imageView.image else { return }

        // Spin a copy that sits above the scroll view. Rotating the scroll view's own zooming
        // view would fight `zoomScale`, which is itself implemented as a transform.
        if rotationOverlay.superview == nil {
            rotationOverlay.contentMode = .scaleAspectFit
            rotationOverlay.isUserInteractionEnabled = false
            contentView.addSubview(rotationOverlay)
        }
        if rotationOverlay.isHidden || rotationOverlay.image == nil {
            rotationOverlay.image = image
            rotationOverlay.transform = .identity
            rotationOverlay.frame = Self.aspectFitRect(for: image.size, in: contentView.bounds)
            rotationOverlay.isHidden = false
            photoView.isHidden = true
        }

        previewRotationAngle += clockwise ? .pi / 2 : -.pi / 2
        let angle = previewRotationAngle
        let fitted = Self.fitScale(for: rotationOverlay.frame.size,
                                   rotatedBy: angle,
                                   in: contentView.bounds)

        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseInOut]) {
            self.rotationOverlay.transform = CGAffineTransform(rotationAngle: angle)
                .scaledBy(x: fitted, y: fitted)
        }
    }

    /// Where an aspect-fit image actually lands on screen.
    private static func aspectFitRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, !bounds.isEmpty else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2,
                      y: bounds.midY - size.height / 2,
                      width: size.width,
                      height: size.height)
    }

    /// Scale that keeps the rotated image inside the screen. A quarter turn swaps the bounding
    /// box, so without this the long edge would overflow.
    private static func fitScale(for size: CGSize, rotatedBy angle: CGFloat, in bounds: CGRect) -> CGFloat {
        guard size.width > 0, size.height > 0, !bounds.isEmpty else { return 1 }
        let quarterTurns = Int(round(abs(angle) / (.pi / 2)))
        guard quarterTurns % 2 == 1 else { return 1 }   // 180° keeps the same box
        return min(bounds.width / size.height, bounds.height / size.width)
    }

    func revertPreviewRotation() {
        previewRotationAngle = 0
        UIView.animate(withDuration: 0.2) {
            self.rotationOverlay.transform = .identity
        } completion: { _ in
            self.clearRotationOverlay()
        }
    }

    var isAtMinimumZoom: Bool {
        stub?.kind == .video ? true : photoView.isAtMinimumZoom
    }

    func setChromeVisible(_ visible: Bool, animated: Bool) {
        guard stub?.kind == .video else { return }
        videoView.setControlsVisible(visible, animated: animated)
    }
}

extension ViewerPageCell {
    /// Puts the real, zoomable image back in charge.
    func clearRotationOverlay() {
        previewRotationAngle = 0
        rotationOverlay.isHidden = true
        rotationOverlay.image = nil
        rotationOverlay.transform = .identity
        photoView.isHidden = stub?.kind == .video
    }
}
