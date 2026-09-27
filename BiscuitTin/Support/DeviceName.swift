import UIKit

/// The kind of device the app is running on, for copy that names it ("this iPad").
enum DeviceName {
    /// "iPhone" or "iPad". `UIDevice.model` is the generic product name; `UIDevice.name` would be
    /// the user's own name for the device, which needs an entitlement since iOS 16.
    static let current = UIDevice.current.model

    /// SF Symbol for the device, for rows that show where a copy of a photo lives.
    static let symbolName = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
}
