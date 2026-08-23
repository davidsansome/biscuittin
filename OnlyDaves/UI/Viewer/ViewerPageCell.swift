import UIKit

/// One full-screen page. Hosts either a zoomable image or a video player, depending on the
/// asset's `MediaKind` (D3).
final class ViewerPageCell: UICollectionViewCell {
    static let reuseIdentifier = "ViewerPageCell"

    let photoView = ZoomablePhotoView()
    let videoView = VideoPlayerPageView()

    private(set) var stub: AssetStub?
    private var token: ImageRequestToken?
    private weak var loader: ImageLoader?

    /// Carries the optimistic rotation (§14 P4).
    ///
    /// Deliberately *not* `photoView.imageView`: that is the scroll view's `viewForZooming`,
    /// and `UIScrollView` implements `zoomScale` through its transform. Setting the transform
    /// there clobbers the zoom, snapping the image to 1:1 with its full pixel size — which on a
    /// real photo reads as "zoomed all the way in".
    fileprivate let rotationOverlay = UIImageView()
    fileprivate var previewRotationAngle: CGFloat = 0

    var onSingleTap: (() -> Void)?
    /// Raised when the user zooms in past the fit scale, so a full-resolution image is fetched.
    var onNeedsFullResolution: ((AssetStub) -> Void)?

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
        photoView.onZoomedIn = { [weak self] in
            guard let self, let stub = self.stub else { return }
            self.onNeedsFullResolution?(stub)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        loader?.cancel(token)
        token = nil
        stub = nil
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
        // upgrades, which is what keeps the page from ever showing empty (§14 P4).
        token = loader.requestImage(for: stub, variant: .viewerPreview) { [weak self] image, _ in
            guard let self, self.stub?.id == stub.id, let image else { return }
            if isVideo {
                self.videoView.setPoster(image)
            } else {
                self.photoView.setImage(image, resetZoom: self.photoView.imageView.image == nil)
            }
        }
    }

    /// Swaps in a higher-quality rendition without disturbing the current zoom.
    func applyFullResolution(_ image: UIImage, for id: AssetID) {
        guard stub?.id == id, stub?.kind != .video else { return }
        photoView.setImage(image, resetZoom: false)
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
