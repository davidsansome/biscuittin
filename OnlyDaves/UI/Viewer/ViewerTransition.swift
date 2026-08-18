import UIKit

/// Supplies the grid-side geometry the zoom transition animates to and from.
/// Implemented by `GridViewController`.
@MainActor
protocol ViewerTransitionSource: AnyObject {
    /// Frame of the tile for `id`, in window coordinates, or nil when it is off screen.
    func viewerTransitionSourceFrame(for id: AssetID) -> CGRect?
    /// The already-decoded thumbnail, used as the placeholder so the animation can start on
    /// the same runloop tick as the tap (§14 P4).
    func viewerTransitionSourceImage(for id: AssetID) -> UIImage?
    /// Called before a dismissal so the grid can scroll the destination tile into view.
    func viewerTransitionPrepareForDismissal(to id: AssetID)
    /// Hides/shows the tile underneath the animating image to avoid a visible duplicate.
    func viewerTransitionSetSourceHidden(_ hidden: Bool, for id: AssetID)
}

/// Zoom transition between a grid tile and the full-screen viewer (§13.2).
///
/// Falls back to a crossfade whenever the source tile is off screen or has no thumbnail yet,
/// so an unusual entry point degrades gracefully rather than jumping.
final class ViewerZoomAnimator: NSObject, UIViewControllerAnimatedTransitioning {

    private let isPresenting: Bool
    private weak var source: ViewerTransitionSource?
    /// Supplies the viewer-side geometry: the on-screen frame of the displayed image.
    private let viewerFrameProvider: () -> (frame: CGRect, image: UIImage?, id: AssetID)?

    init(isPresenting: Bool,
         source: ViewerTransitionSource?,
         viewerFrameProvider: @escaping () -> (frame: CGRect, image: UIImage?, id: AssetID)?) {
        self.isPresenting = isPresenting
        self.source = source
        self.viewerFrameProvider = viewerFrameProvider
    }

    func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
        isPresenting ? 0.34 : 0.30
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        if isPresenting {
            animatePresentation(using: context)
        } else {
            animateDismissal(using: context)
        }
    }

    // MARK: - Present

    private func animatePresentation(using context: UIViewControllerContextTransitioning) {
        guard let toVC = context.viewController(forKey: .to),
              let toView = context.view(forKey: .to) else {
            context.completeTransition(false)
            return
        }

        let container = context.containerView
        toView.frame = context.finalFrame(for: toVC)
        container.addSubview(toView)
        toView.layoutIfNeeded()

        guard let target = viewerFrameProvider(),
              let startFrame = source?.viewerTransitionSourceFrame(for: target.id),
              let image = source?.viewerTransitionSourceImage(for: target.id) ?? target.image else {
            // No tile to fly from: crossfade.
            toView.alpha = 0
            UIView.animate(withDuration: transitionDuration(using: context)) {
                toView.alpha = 1
            } completion: { _ in
                context.completeTransition(!context.transitionWasCancelled)
            }
            return
        }

        let travelling = UIImageView(image: image)
        travelling.contentMode = .scaleAspectFill
        travelling.clipsToBounds = true
        travelling.frame = startFrame
        container.addSubview(travelling)

        source?.viewerTransitionSetSourceHidden(true, for: target.id)
        toView.alpha = 0
        toView.isHidden = false

        // Fade the backdrop in slightly ahead of the image landing.
        UIView.animate(withDuration: transitionDuration(using: context) * 0.6) {
            toView.alpha = 1
        }

        UIView.animate(withDuration: transitionDuration(using: context),
                       delay: 0,
                       usingSpringWithDamping: 0.9,
                       initialSpringVelocity: 0,
                       options: [.curveEaseOut]) {
            travelling.frame = target.frame
            travelling.contentMode = .scaleAspectFit
        } completion: { _ in
            travelling.removeFromSuperview()
            self.source?.viewerTransitionSetSourceHidden(false, for: target.id)
            context.completeTransition(!context.transitionWasCancelled)
        }
    }

    // MARK: - Dismiss

    private func animateDismissal(using context: UIViewControllerContextTransitioning) {
        guard let fromView = context.view(forKey: .from) else {
            context.completeTransition(false)
            return
        }
        let container = context.containerView

        guard let current = viewerFrameProvider(), let image = current.image else {
            UIView.animate(withDuration: transitionDuration(using: context)) {
                fromView.alpha = 0
            } completion: { _ in
                context.completeTransition(!context.transitionWasCancelled)
            }
            return
        }

        source?.viewerTransitionPrepareForDismissal(to: current.id)
        container.layoutIfNeeded()
        let destination = source?.viewerTransitionSourceFrame(for: current.id)

        let travelling = UIImageView(image: image)
        travelling.contentMode = .scaleAspectFit
        travelling.clipsToBounds = true
        travelling.frame = current.frame
        container.addSubview(travelling)
        fromView.isHidden = true

        if let destination {
            source?.viewerTransitionSetSourceHidden(true, for: current.id)
            UIView.animate(withDuration: transitionDuration(using: context),
                           delay: 0,
                           options: [.curveEaseInOut]) {
                travelling.frame = destination
                travelling.contentMode = .scaleAspectFill
            } completion: { _ in
                travelling.removeFromSuperview()
                self.source?.viewerTransitionSetSourceHidden(false, for: current.id)
                context.completeTransition(!context.transitionWasCancelled)
            }
        } else {
            // Destination tile is not on screen; shrink and fade in place.
            UIView.animate(withDuration: transitionDuration(using: context)) {
                travelling.alpha = 0
                travelling.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
            } completion: { _ in
                travelling.removeFromSuperview()
                context.completeTransition(!context.transitionWasCancelled)
            }
        }
    }
}

/// Wires the animators up for presentation. Kept separate from the pager so the pager stays
/// about paging.
final class ViewerTransitionDelegate: NSObject, UIViewControllerTransitioningDelegate {
    weak var source: ViewerTransitionSource?
    var viewerFrameProvider: () -> (frame: CGRect, image: UIImage?, id: AssetID)? = { nil }

    func animationController(forPresented presented: UIViewController,
                             presenting: UIViewController,
                             source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        ViewerZoomAnimator(isPresenting: true,
                           source: self.source,
                           viewerFrameProvider: viewerFrameProvider)
    }

    func animationController(forDismissed dismissed: UIViewController)
    -> UIViewControllerAnimatedTransitioning? {
        ViewerZoomAnimator(isPresenting: false,
                           source: source,
                           viewerFrameProvider: viewerFrameProvider)
    }
}
