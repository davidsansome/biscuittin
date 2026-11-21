import UIKit

extension UITraitEnvironment {
    /// Display scale from the trait collection, falling back to 2x before the view joins a window.
    var effectiveDisplayScale: CGFloat {
        traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
    }
}
