import UIKit

/// One zoomable image page in the viewer (DESIGN.md §13.2).
///
/// Shows the grid thumbnail immediately and swaps in better renditions as they arrive, so a
/// tap never waits on I/O (§14 P4). Zoom range is aspect-fit to 4×, with double-tap toggling
/// between them.
final class ZoomablePhotoView: UIScrollView {

    let imageView = UIImageView()

    /// Fires on a single tap that was not part of a double tap — the chrome toggle.
    var onSingleTap: (() -> Void)?
    /// Fires when the user zooms past 1×, so the pager can request a full-resolution image.
    var onZoomedIn: (() -> Void)?

    private var hasRequestedFullResolution = false
    private var lastLayoutSize: CGSize = .zero

    var isAtMinimumZoom: Bool {
        // A little slack: floating-point zoom scales rarely compare exactly.
        zoomScale <= minimumZoomScale * 1.01
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        bouncesZoom = true
        delegate = self
        backgroundColor = .clear

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Content

    func setImage(_ image: UIImage?, resetZoom: Bool) {
        imageView.image = image
        if resetZoom {
            hasRequestedFullResolution = false
        }
        // Must re-run explicitly: the image can arrive long after the last bounds change, and
        // laying out only on bounds changes would leave the image view at zero size.
        configureZoomScales(resetToMinimum: resetZoom)
        centerContent()
    }

    func resetZoom(animated: Bool) {
        setZoomScale(minimumZoomScale, animated: animated)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastLayoutSize {
            lastLayoutSize = bounds.size
            configureZoomScales(resetToMinimum: isAtMinimumZoom)
        }
        centerContent()
    }

    /// Rebuilds the zoom range for the current image and bounds.
    ///
    /// The content is laid out in the image's own pixel coordinate space, with the minimum
    /// zoom scale being whatever makes it aspect-fit. The scale limits are relaxed before
    /// resetting to 1× because `UIScrollView` clamps `zoomScale` to the *existing* range, and
    /// a stale range from the previous image would otherwise distort the new one.
    private func configureZoomScales(resetToMinimum: Bool) {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }

        let previousScale = zoomScale
        let wasAtMinimum = zoomScale <= minimumZoomScale * 1.01

        minimumZoomScale = 0.01
        maximumZoomScale = 100
        zoomScale = 1

        imageView.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size

        let fitScale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        minimumZoomScale = fitScale
        maximumZoomScale = fitScale * 4
        zoomScale = (resetToMinimum || wasAtMinimum)
            ? fitScale
            : min(max(previousScale, fitScale), fitScale * 4)
    }

    /// Keeps the image centred when it is smaller than the viewport in either axis.
    private func centerContent() {
        // `imageView.frame` already reflects the current zoom scale, so this is simply the
        // leftover space on each axis.
        let vertical = max(0, bounds.height - imageView.frame.height) / 2
        let horizontal = max(0, bounds.width - imageView.frame.width) / 2
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    // MARK: - Gestures

    @objc private func handleSingleTap() {
        onSingleTap?()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard imageView.image != nil else { return }
        if isAtMinimumZoom {
            let point = gesture.location(in: imageView)
            let targetScale = minimumZoomScale * 2.5
            let size = CGSize(width: bounds.width / targetScale, height: bounds.height / targetScale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height),
                 animated: true)
        } else {
            setZoomScale(minimumZoomScale, animated: true)
        }
    }
}

extension ZoomablePhotoView: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        if !isAtMinimumZoom, !hasRequestedFullResolution {
            hasRequestedFullResolution = true
            onZoomedIn?()
        }
    }
}
