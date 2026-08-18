import SwiftUI

/// SwiftUI entry point for the home screen.
///
/// The navigation controller lives on the UIKit side (a small deviation from the first
/// design draft) so the grid owns its own nav bar, menu and — from M2 — the custom zoom
/// transition to the viewer, none of which survive contact with a SwiftUI-owned toolbar.
struct GridScreen: UIViewControllerRepresentable {
    let env: AppEnvironment

    func makeUIViewController(context: Context) -> UINavigationController {
        let grid = GridViewController(env: env)
        let nav = UINavigationController(rootViewController: grid)
        nav.navigationBar.prefersLargeTitles = false
        return nav
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}
