import AVFoundation
import UIKit
import XCTest
@testable import BiscuitTin

@MainActor
final class ViewerUITests: XCTestCase {

    func testZoomablePhotoViewResetsZoomStateWhenImageCleared() {
        let view = ZoomablePhotoView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.layoutIfNeeded()

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 1000))
        let image = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1000, height: 1000))
        }

        view.setImage(image, resetZoom: true)
        XCTAssertTrue(view.isAtMinimumZoom)

        view.setZoomScale(view.minimumZoomScale * 2, animated: false)
        XCTAssertFalse(view.isAtMinimumZoom)

        view.setImage(nil, resetZoom: true)
        XCTAssertTrue(view.isAtMinimumZoom)
        XCTAssertEqual(view.minimumZoomScale, 1, accuracy: 0.001)
        XCTAssertEqual(view.maximumZoomScale, 1, accuracy: 0.001)
        XCTAssertEqual(view.zoomScale, 1, accuracy: 0.001)
        XCTAssertEqual(view.contentSize, .zero)
        XCTAssertEqual(view.contentOffset, .zero)
        XCTAssertEqual(view.contentInset, .zero)
        XCTAssertEqual(view.imageView.frame, .zero)
    }

    func testVideoPlayerPageViewResetsErrorAndControlsOnDetach() {
        let view = VideoPlayerPageView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controlsStack = view.subviews.compactMap { $0 as? UIStackView }.first
        let errorLabel = view.subviews.compactMap { $0 as? UILabel }.first
        let spinner = view.subviews.compactMap { $0 as? UIActivityIndicatorView }.first

        XCTAssertNotNil(controlsStack)
        XCTAssertNotNil(errorLabel)
        XCTAssertNotNil(spinner)

        view.showError("Unavailable")
        XCTAssertEqual(controlsStack?.isHidden, true)
        XCTAssertEqual(errorLabel?.isHidden, false)

        view.detachPlayer()
        XCTAssertEqual(controlsStack?.isHidden, false)
        XCTAssertEqual(errorLabel?.isHidden, true)
        XCTAssertEqual(spinner?.isAnimating, false)

        view.showError("Unavailable again")
        view.showLoading()
        XCTAssertEqual(errorLabel?.isHidden, true)
        XCTAssertEqual(spinner?.isAnimating, true)

        view.attach(player: AVPlayer(), autoplay: false)
        XCTAssertEqual(controlsStack?.isHidden, false)
        XCTAssertEqual(errorLabel?.isHidden, true)
        XCTAssertEqual(spinner?.isAnimating, false)
    }

    func testIndexAfterRemovingHandlesAllPositions() {
        // Removed before current: shift current index back by 1 to stay on the same item.
        XCTAssertEqual(ViewerPagerController.indexAfterRemoving(1, currentIndex: 3, remainingCount: 4), 2)
        // Removed after current: current index is unaffected.
        XCTAssertEqual(ViewerPagerController.indexAfterRemoving(4, currentIndex: 2, remainingCount: 4), 2)
        // Removed current in the middle: stay at same slot (next item shifts in).
        XCTAssertEqual(ViewerPagerController.indexAfterRemoving(2, currentIndex: 2, remainingCount: 4), 2)
        // Removed current at the end: clamp to new last index.
        XCTAssertEqual(ViewerPagerController.indexAfterRemoving(3, currentIndex: 3, remainingCount: 3), 2)
        // Removed the last remaining item: returns nil so viewer dismisses.
        XCTAssertNil(ViewerPagerController.indexAfterRemoving(0, currentIndex: 0, remainingCount: 0))
    }

    func testDoubleTapTakesPriorityOverImageViewTapsButNotLongPress() {
        let view = ZoomablePhotoView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.layoutIfNeeded()

        let taps = (view.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
        let doubleTap = taps.first { $0.numberOfTapsRequired == 2 }
        let singleTap = taps.first { $0.numberOfTapsRequired == 1 }
        XCTAssertNotNil(doubleTap)
        XCTAssertNotNil(singleTap)
        guard let doubleTap, let singleTap,
              let doubleDelegate = doubleTap.delegate,
              let singleDelegate = singleTap.delegate else {
            return XCTFail("Expected tap gestures with delegates")
        }

        // Simulate Live Text overlay subview inside imageView.
        let overlay = UIView(frame: view.imageView.bounds)
        view.imageView.addSubview(overlay)

        let overlaySingleTap = UITapGestureRecognizer()
        overlaySingleTap.numberOfTapsRequired = 1
        overlay.addGestureRecognizer(overlaySingleTap)

        let overlayDoubleTap = UITapGestureRecognizer()
        overlayDoubleTap.numberOfTapsRequired = 2
        overlay.addGestureRecognizer(overlayDoubleTap)

        let overlayLongPress = UILongPressGestureRecognizer()
        overlay.addGestureRecognizer(overlayLongPress)

        let overlayPan = UIPanGestureRecognizer()
        overlay.addGestureRecognizer(overlayPan)

        let externalView = UIView()
        let externalTap = UITapGestureRecognizer()
        externalView.addGestureRecognizer(externalTap)

        // Both double-tap zoom and single-tap chrome toggle take priority over tap gestures
        // inside imageView (single-tap yields via gestureRecognizerShouldBegin when Live Text
        // owns the tap).
        XCTAssertEqual(doubleDelegate.gestureRecognizer?(doubleTap, shouldBeRequiredToFailBy: overlaySingleTap), true)
        XCTAssertEqual(doubleDelegate.gestureRecognizer?(doubleTap, shouldBeRequiredToFailBy: overlayDoubleTap), true)
        XCTAssertEqual(singleDelegate.gestureRecognizer?(singleTap, shouldBeRequiredToFailBy: overlaySingleTap), true)
        XCTAssertEqual(singleDelegate.gestureRecognizer?(singleTap, shouldBeRequiredToFailBy: overlayDoubleTap), true)

        // Long press (text selection) and pan (selection handles) must never be blocked.
        XCTAssertEqual(doubleDelegate.gestureRecognizer?(doubleTap, shouldBeRequiredToFailBy: overlayLongPress), false)
        XCTAssertEqual(singleDelegate.gestureRecognizer?(singleTap, shouldBeRequiredToFailBy: overlayLongPress), false)
        XCTAssertEqual(doubleDelegate.gestureRecognizer?(doubleTap, shouldBeRequiredToFailBy: overlayPan), false)
        XCTAssertEqual(singleDelegate.gestureRecognizer?(singleTap, shouldBeRequiredToFailBy: overlayPan), false)

        // Gestures outside imageView are unaffected.
        XCTAssertEqual(doubleDelegate.gestureRecognizer?(doubleTap, shouldBeRequiredToFailBy: externalTap), false)
        XCTAssertEqual(singleDelegate.gestureRecognizer?(singleTap, shouldBeRequiredToFailBy: externalTap), false)
    }

    func testDoubleTapArbitratesRealLiveTextGestureRecognizers() async throws {
        try XCTSkipUnless(LiveText.isSupported, "Live Text unsupported on this destination")

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let view = ZoomablePhotoView(frame: window.bounds)
        window.addSubview(view)
        window.makeKeyAndVisible()

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 800))
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 800))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 72),
                .foregroundColor: UIColor.black
            ]
            NSString(string: "HELLO WORLD").draw(at: CGPoint(x: 100, y: 350), withAttributes: attrs)
        }
        view.setImage(image, resetZoom: true)
        view.layoutIfNeeded()

        let analysis = try await LiveText.analyze(image)
        view.setLiveTextAnalysis(analysis)
        view.layoutIfNeeded()

        let taps = (view.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
        let doubleTapGR = try XCTUnwrap(taps.first { $0.numberOfTapsRequired == 2 })
        let singleTapGR = try XCTUnwrap(taps.first { $0.numberOfTapsRequired == 1 })
        let doubleDelegate = try XCTUnwrap(doubleTapGR.delegate)
        let singleDelegate = try XCTUnwrap(singleTapGR.delegate)

        func collectRecognizers(in root: UIView) -> [UIGestureRecognizer] {
            (root.gestureRecognizers ?? []) + root.subviews.flatMap { collectRecognizers(in: $0) }
        }

        // VisionKit installs its overlay recognizers asynchronously after `analysis` is set.
        // Note: the non-empty assertions below pin VisionKit's current recognizer placement under
        // `imageView` and may need relaxing if a future OS moves them.
        var liveTextTaps: [UITapGestureRecognizer] = []
        var liveTextLongPresses: [UILongPressGestureRecognizer] = []
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            let imageViewRecognizers = collectRecognizers(in: view.imageView)
            liveTextTaps = imageViewRecognizers.compactMap { $0 as? UITapGestureRecognizer }
            liveTextLongPresses = imageViewRecognizers.compactMap { $0 as? UILongPressGestureRecognizer }
            if !liveTextTaps.isEmpty, !liveTextLongPresses.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertFalse(liveTextTaps.isEmpty, "Expected VisionKit tap recognizers inside imageView")
        XCTAssertFalse(liveTextLongPresses.isEmpty, "Expected VisionKit long-press recognizers inside imageView")

        for tap in liveTextTaps {
            XCTAssertEqual(doubleDelegate.gestureRecognizer?(doubleTapGR, shouldBeRequiredToFailBy: tap), true,
                           "Double-tap zoom should take priority over VisionKit tap \(tap)")
            XCTAssertEqual(singleDelegate.gestureRecognizer?(singleTapGR, shouldBeRequiredToFailBy: tap), true,
                           "Single-tap chrome toggle should arbitrate VisionKit tap \(tap)")
        }
        for longPress in liveTextLongPresses {
            XCTAssertEqual(doubleDelegate.gestureRecognizer?(doubleTapGR, shouldBeRequiredToFailBy: longPress), false,
                           "Double-tap zoom must not block VisionKit long-press \(longPress)")
            XCTAssertEqual(singleDelegate.gestureRecognizer?(singleTapGR, shouldBeRequiredToFailBy: longPress), false,
                           "Single-tap chrome toggle must not block VisionKit long-press \(longPress)")
        }
    }
}
