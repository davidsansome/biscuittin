import UIKit

/// Translates a pinch gesture into discrete column-count steps (requirement 4, §13.1).
///
/// Uses a ratio threshold rather than continuous tracking: crossing ±30 % steps one column
/// and resets the gesture's accumulated scale, which gives a firm detent instead of tiles
/// that jitter between counts mid-pinch.
final class PinchColumnsController {
    private static let stepThreshold: CGFloat = 1.3

    private(set) var columns: Int
    /// Reports a new column count plus the point the pinch is centred on, so the caller can
    /// keep that tile visually anchored across the layout change.
    var onChange: ((Int, CGPoint) -> Void)?

    init(columns: Int) {
        self.columns = min(max(columns, AppSettings.minColumns), AppSettings.maxColumns)
    }

    func setColumnsWithoutNotifying(_ value: Int) {
        columns = min(max(value, AppSettings.minColumns), AppSettings.maxColumns)
    }

    @objc func handle(_ gesture: UIPinchGestureRecognizer) {
        guard let view = gesture.view else { return }
        switch gesture.state {
        case .began:
            gesture.scale = 1
        case .changed:
            let centroid = gesture.numberOfTouches >= 2
                ? midpoint(gesture.location(ofTouch: 0, in: view), gesture.location(ofTouch: 1, in: view))
                : gesture.location(in: view)

            if gesture.scale >= Self.stepThreshold {
                // Spreading fingers zooms in: fewer, larger tiles.
                step(by: -1, at: centroid)
                gesture.scale = 1
            } else if gesture.scale <= 1 / Self.stepThreshold {
                step(by: +1, at: centroid)
                gesture.scale = 1
            }
        default:
            gesture.scale = 1
        }
    }

    private func step(by delta: Int, at point: CGPoint) {
        let next = min(max(columns + delta, AppSettings.minColumns), AppSettings.maxColumns)
        guard next != columns else { return }
        columns = next
        onChange?(next, point)
    }

    private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}
