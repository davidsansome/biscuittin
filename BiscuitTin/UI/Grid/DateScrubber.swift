import UIKit

/// A fast-scroll handle along the grid's trailing edge, mirroring the date-jump index in Photos
/// and Contacts: dragging it jumps the timeline to any point and pops up a bubble naming the
/// date bucket that landed there.
///
/// Deliberately dumb about the grid: this view knows nothing about `TimelineSnapshot` or
/// `UICollectionView`. `GridViewController` drives `scrollFraction` to mirror ordinary
/// scrolling, and answers every drag update through `onScrub` with whatever label the resulting
/// position should show — every grid-specific concern (content insets, section lookup) stays on
/// the one side that already has it.
final class DateScrubber: UIView {

    /// Fired for every drag update, and once on touch-down, with the touch's normalized
    /// position (0 = top, 1 = bottom). Returns the bucket title to show in the bubble, or nil
    /// to hide it (an empty timeline).
    var onScrub: ((CGFloat) -> String?)?
    var onScrubEnd: (() -> Void)?

    /// Mirrors ordinary scrolling so the handle reads as a real scroll indicator whenever the
    /// user isn't actively dragging it.
    var scrollFraction: CGFloat = 0 {
        didSet {
            guard !isDragging else { return }
            positionHandle(fraction: scrollFraction)
        }
    }

    /// Width of the invisible strip that accepts touches. Much wider than the visible handle —
    /// a hairline is not something a thumb can reliably grab, and the system scroll indicator's
    /// own hit area is similarly generous.
    static let hitTargetWidth: CGFloat = 44

    private let handle = UIView()
    private let bubble = DateScrubberBubble()
    private var isDragging = false
    private let feedback = UISelectionFeedbackGenerator()
    private var lastTitle: String?

    private let idleWidth: CGFloat = 4
    private let activeWidth: CGFloat = 6
    private let handleHeight: CGFloat = 34
    private let trailingInset: CGFloat = 6

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = false   // the bubble extends past this view's own narrow bounds

        handle.backgroundColor = .label
        handle.alpha = 0.28
        handle.layer.cornerCurve = .continuous
        handle.isUserInteractionEnabled = false
        addSubview(handle)

        bubble.alpha = 0
        bubble.isUserInteractionEnabled = false
        addSubview(bubble)

        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        positionHandle(fraction: isDragging ? lastFraction : scrollFraction)
    }

    private var lastFraction: CGFloat = 0

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            isDragging = true
            feedback.prepare()
            update(with: gesture)
            UIView.animate(withDuration: 0.16) { self.bubble.alpha = self.lastTitle == nil ? 0 : 1 }
        case .changed:
            update(with: gesture)
        case .ended, .cancelled, .failed:
            isDragging = false
            UIView.animate(withDuration: 0.2) {
                self.bubble.alpha = 0
                self.positionHandle(fraction: self.scrollFraction)
            }
            onScrubEnd?()
        default:
            break
        }
    }

    private func update(with gesture: UIPanGestureRecognizer) {
        let y = gesture.location(in: self).y
        let fraction = max(0, min(1, bounds.height > 0 ? y / bounds.height : 0))
        lastFraction = fraction
        positionHandle(fraction: fraction)

        let title = onScrub?(fraction) ?? nil
        if title != lastTitle {
            lastTitle = title
            feedback.selectionChanged()
            UIView.animate(withDuration: 0.12) { self.bubble.alpha = title == nil ? 0 : 1 }
        }
        if let title { bubble.text = title }
        positionBubble()
    }

    private func positionHandle(fraction: CGFloat) {
        let width = isDragging ? activeWidth : idleWidth
        let travel = max(0, bounds.height - handleHeight)
        let y = max(0, min(1, fraction)) * travel
        handle.frame = CGRect(x: bounds.width - trailingInset - width, y: y,
                              width: width, height: handleHeight)
        handle.layer.cornerRadius = width / 2
        positionBubble()
    }

    private func positionBubble() {
        let size = bubble.intrinsicContentSize
        let gap: CGFloat = 10
        bubble.frame = CGRect(x: handle.frame.minX - gap - size.width,
                              y: handle.frame.midY - size.height / 2,
                              width: size.width, height: size.height)
    }
}

/// The floating pill showing the bucket title while dragging.
private final class DateScrubberBubble: UIView {
    var text: String = "" {
        didSet {
            label.text = text
            invalidateIntrinsicContentSize()
        }
    }

    private let label = UILabel()
    private let horizontalPadding: CGFloat = 14
    private let verticalPadding: CGFloat = 8

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.95)
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)

        label.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        label.textColor = .label
        label.textAlignment = .center
        label.numberOfLines = 1
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: horizontalPadding, dy: verticalPadding)
    }

    override var intrinsicContentSize: CGSize {
        let textSize = label.sizeThatFits(CGSize(width: 240, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: ceil(textSize.width) + horizontalPadding * 2,
                     height: ceil(textSize.height) + verticalPadding * 2)
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight]
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
