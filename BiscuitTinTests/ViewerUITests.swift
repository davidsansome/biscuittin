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
}
