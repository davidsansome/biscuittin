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

    var isAtMinimumZoom: Bool {
        stub?.kind == .video ? true : photoView.isAtMinimumZoom
    }

    func setChromeVisible(_ visible: Bool, animated: Bool) {
        guard stub?.kind == .video else { return }
        videoView.setControlsVisible(visible, animated: animated)
    }
}
