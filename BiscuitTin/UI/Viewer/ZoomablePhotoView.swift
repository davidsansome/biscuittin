import UIKit
import VisionKit

/// One zoomable image page in the viewer (DESIGN.md §13.2).
///
/// Shows the grid thumbnail immediately and swaps in better renditions as they arrive, so a
/// tap never waits on I/O (§14 P4). Zoom range is aspect-fit up to the photo's own pixels,
/// with double-tap toggling between them.
final class ZoomablePhotoView: UIScrollView {

    let imageView = UIImageView()

    /// Fires on a single tap that was not part of a double tap — the chrome toggle.
    var onSingleTap: (() -> Void)?
    /// Fires when the user zooms past 1×, so the page can request a full-resolution image.
    var onZoomedIn: (() -> Void)?
    /// Fires when Live Text's highlight mode or text selection changes.
    var onLiveTextChange: (() -> Void)?

    /// Lives on the zooming view so highlights and selection track the photo through a pinch.
    /// Nil where the device cannot run text recognition.
    private let liveTextInteraction: ImageAnalysisInteraction?

    private var hasRequestedFullResolution = false
    private var lastLayoutSize: CGSize = .zero

    /// Set while `configureZoomScales` is driving `zoomScale` itself, so that the delegate can
    /// tell the app's own bookkeeping apart from a gesture.
    private var isConfiguringZoomScales = false
    private var isUserZooming = false
    /// A better rendition that arrived mid-pinch; applied once the fingers lift.
    private var pendingImage: UIImage?

    var isAtMinimumZoom: Bool {
        // A little slack: floating-point zoom scales rarely compare exactly.
        zoomScale <= minimumZoomScale * 1.01
    }

    override init(frame: CGRect) {
        liveTextInteraction = LiveText.isSupported ? ImageAnalysisInteraction() : nil
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

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)

        if let liveTextInteraction {
            liveTextInteraction.preferredInteractionTypes = .automatic
            // VisionKit places its own Live Text button inside the interaction's view, which
            // here is the zooming view. The viewer toolbar carries the toggle instead.
            liveTextInteraction.isSupplementaryInterfaceHidden = true
            liveTextInteraction.delegate = self
            imageView.addInteraction(liveTextInteraction)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Content

    func setImage(_ image: UIImage?, resetZoom: Bool) {
        // Re-laying out under an active pinch fights the gesture: UIScrollView derives
        // `zoomScale` from the scale at the gesture's start, and that number is expressed in
        // the outgoing image's pixel space. Hold the rendition until the fingers lift.
        if isUserZooming, !resetZoom, image != nil {
            pendingImage = image
            return
        }

        pendingImage = nil
        imageView.image = image
        if resetZoom {
            hasRequestedFullResolution = false
            isUserZooming = false
        }
        // Must re-run explicitly: the image can arrive long after the last bounds change, and
        // laying out only on bounds changes would leave the image view at zero size.
        configureZoomScales(resetToMinimum: resetZoom)
        centerContent()
        liveTextInteraction?.setContentsRectNeedsUpdate()
    }

    // MARK: - Live Text

    /// Set once per asset and kept across rendition swaps, not redone for the full-resolution
    /// image; `setImage` refreshes the contents rect it is laid out through.
    func setLiveTextAnalysis(_ analysis: ImageAnalysis?) {
        guard let liveTextInteraction else { return }
        if analysis == nil {
            resetLiveText()
        }
        liveTextInteraction.analysis = analysis
    }

    var hasLiveTextAnalysis: Bool { liveTextInteraction?.analysis != nil }

    var liveTextHasText: Bool {
        liveTextInteraction?.analysis?.hasResults(for: .text) ?? false
    }

    var isLiveTextHighlighted: Bool {
        get { liveTextInteraction?.selectableItemsHighlighted ?? false }
        set { liveTextInteraction?.selectableItemsHighlighted = newValue }
    }

    var hasActiveTextSelection: Bool {
        liveTextInteraction?.hasActiveTextSelection ?? false
    }

    func resetLiveText() {
        guard let liveTextInteraction, liveTextInteraction.analysis != nil else { return }
        liveTextInteraction.resetTextSelection()
        liveTextInteraction.selectableItemsHighlighted = false
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
    ///
    /// `zoomScale` therefore means something different for every rendition, so what carries
    /// across a swap is the `ZoomAnchor` — the view of the photo — never the number.
    private func configureZoomScales(resetToMinimum: Bool) {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }

        let anchor = resetToMinimum ? nil : currentAnchor()

        isConfiguringZoomScales = true
        defer { isConfiguringZoomScales = false }

        minimumZoomScale = 0.01
        maximumZoomScale = 100
        zoomScale = 1

        imageView.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size

        let fitScale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        minimumZoomScale = fitScale
        maximumZoomScale = max(fitScale * 4, nativePixelScale(for: image))

        guard let anchor, anchor.magnification > 1.01 else {
            zoomScale = fitScale
            return
        }
        zoomScale = min(fitScale * anchor.magnification, maximumZoomScale)
        centerContent()
        restore(anchor)
    }

    /// Zoom scale at which one image pixel covers exactly one device pixel — the point past
    /// which the photo has no more detail to give.
    ///
    /// The 4×-aspect-fit ceiling on its own is measured against the *screen*: it caps the photo
    /// at four viewports wide however many pixels it holds, so the higher the resolution the
    /// smaller the fraction of it that can be reached. Measured on an iPhone 17 Pro, a 12 MP
    /// original tops out at 1.2× its own pixels but a 48 MP one at 0.6× — the native pixels of
    /// exactly the photos that have the most of them were unreachable.
    private func nativePixelScale(for image: UIImage) -> CGFloat {
        let screenScale = window?.screen.scale ?? traitCollection.displayScale
        guard screenScale > 0 else { return 1 }
        // `image.size` is in points; `image.scale` is what converts it to the pixels on hand.
        return image.scale / screenScale
    }

    /// Keeps the image centred when it is smaller than the viewport in either axis.
    private func centerContent() {
        // `imageView.frame` already reflects the current zoom scale, so this is simply the
        // leftover space on each axis.
        let vertical = max(0, bounds.height - imageView.frame.height) / 2
        let horizontal = max(0, bounds.width - imageView.frame.width) / 2
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    // MARK: - Carrying the view of the photo across a rendition swap

    /// What the user is looking at, in terms that survive a change of image: how far past
    /// aspect-fit the photo is magnified, and which point of it sits in the middle of the
    /// viewport.
    private struct ZoomAnchor {
        let magnification: CGFloat
        let center: CGPoint
    }

    private func currentAnchor() -> ZoomAnchor? {
        guard minimumZoomScale > 0, imageView.frame.width > 0, imageView.frame.height > 0 else {
            return nil
        }
        let viewportCenter = CGPoint(x: contentOffset.x + bounds.width / 2,
                                     y: contentOffset.y + bounds.height / 2)
        return ZoomAnchor(
            magnification: zoomScale / minimumZoomScale,
            center: CGPoint(x: (viewportCenter.x - imageView.frame.minX) / imageView.frame.width,
                            y: (viewportCenter.y - imageView.frame.minY) / imageView.frame.height))
    }

    /// Puts the anchored point back in the middle of the viewport. Run after `centerContent`,
    /// which is what decides how far the offset is allowed to travel.
    private func restore(_ anchor: ZoomAnchor) {
        let target = CGPoint(
            x: imageView.frame.minX + anchor.center.x * imageView.frame.width - bounds.width / 2,
            y: imageView.frame.minY + anchor.center.y * imageView.frame.height - bounds.height / 2)
        contentOffset = CGPoint(
            x: clamp(target.x, lower: -contentInset.left,
                     upper: imageView.frame.maxX + contentInset.right - bounds.width),
            y: clamp(target.y, lower: -contentInset.top,
                     upper: imageView.frame.maxY + contentInset.bottom - bounds.height))
    }

    private func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), max(lower, upper))
    }

    // MARK: - Gestures

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        // A tap Live Text acts on — clearing a selection, or picking text or a link while items
        // are highlighted — must not also flip the chrome.
        if let liveTextInteraction, liveTextInteraction.analysis != nil {
            let point = gesture.location(in: imageView)
            if liveTextInteraction.hasActiveTextSelection
                || (liveTextInteraction.selectableItemsHighlighted
                    && liveTextInteraction.hasInteractiveItem(at: point)) {
                return
            }
        }
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
        // `configureZoomScales` steps `zoomScale` through 1× with the limits relaxed, which the
        // test below would otherwise read as the user having zoomed in — spending the one-shot
        // trigger on a request nobody asked for, and leaving none for the real pinch.
        guard !isConfiguringZoomScales else { return }
        if !isAtMinimumZoom, !hasRequestedFullResolution {
            hasRequestedFullResolution = true
            onZoomedIn?()
        }
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        guard !isConfiguringZoomScales else { return }
        isUserZooming = true
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        guard !isConfiguringZoomScales else { return }
        isUserZooming = false
        if let pending = pendingImage {
            pendingImage = nil
            setImage(pending, resetZoom: false)
        }
    }
}

extension ZoomablePhotoView: ImageAnalysisInteractionDelegate {
    /// Look Up, Translate and Share present from here; the window's root controller is already
    /// presenting the viewer, so it cannot.
    func presentingViewController(for interaction: ImageAnalysisInteraction) -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }

    func interaction(_ interaction: ImageAnalysisInteraction,
                     highlightSelectedItemsDidChange highlightSelectedItems: Bool) {
        onLiveTextChange?()
    }

    func textSelectionDidChange(_ interaction: ImageAnalysisInteraction) {
        onLiveTextChange?()
    }
}
