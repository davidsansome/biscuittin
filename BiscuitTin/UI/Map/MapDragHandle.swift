import UIKit

/// The draggable bar between the map and the grid (DESIGN.md §20.2).
///
/// Its own view rather than a decoration on either neighbour, because it owns the drag gesture
/// and needs a hit area taller than the grabber it draws — a 5 pt pill is visible enough to read
/// as a control but far too small to reliably catch a thumb.
final class MapDragHandle: UIView {

    static let height: CGFloat = 28

    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private let grabber = UIView()
    private let separator = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        blur.frame = bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(blur)

        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        grabber.backgroundColor = .tertiaryLabel
        grabber.layer.cornerRadius = 2.5
        grabber.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grabber)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            grabber.centerXAnchor.constraint(equalTo: centerXAnchor),
            grabber.centerYAnchor.constraint(equalTo: centerYAnchor),
            grabber.widthAnchor.constraint(equalToConstant: 40),
            grabber.heightAnchor.constraint(equalToConstant: 5)
        ])

        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityLabel = "Map size"
        accessibilityHint = "Swipe up to show photos full screen"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Points the hint at whichever move is available from the current stop.
    func setRaised(_ raised: Bool) {
        accessibilityHint = raised
            ? "Swipe down to show the map"
            : "Swipe up to show photos full screen"
    }
}
