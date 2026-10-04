import UIKit

/// The viewer's bottom button bar (requirements 7 and 8).
///
/// Semi-transparent with a vertical gradient — fully clear at the top, ~55 % black at the
/// bottom — so it reads over any photo without hiding it. Back sits on the left; Live Text (only
/// on photos with text in them), rotate left, rotate right, delete, share and info are grouped
/// on the right.
final class ViewerToolbar: UIView {

    var onBack: (() -> Void)?
    var onLiveText: (() -> Void)?
    var onRotateLeft: (() -> Void)?
    var onRotateRight: (() -> Void)?
    var onDelete: (() -> Void)?
    var onShare: (() -> Void)?
    var onInfo: (() -> Void)?

    private let gradientLayer = CAGradientLayer()
    private let backButton = UIButton(type: .system)
    private let liveTextButton = UIButton(type: .system)
    private let rotateLeftButton = UIButton(type: .system)
    private let rotateRightButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    let shareButton = UIButton(type: .system)
    private let infoButton = UIButton(type: .system)
    private let rightStack = UIStackView()

    /// Height of the control row, excluding the safe-area inset the gradient extends through.
    static let contentHeight: CGFloat = 56

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true

        gradientLayer.colors = [UIColor.black.withAlphaComponent(0).cgColor,
                                UIColor.black.withAlphaComponent(0.55).cgColor]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(gradientLayer)

        configure(backButton, systemName: "chevron.backward", action: #selector(backTapped),
                  accessibilityLabel: "Back")
        configure(liveTextButton, systemName: "text.viewfinder", action: #selector(liveTextTapped),
                  accessibilityLabel: "Live Text")
        liveTextButton.isHidden = true
        configure(rotateLeftButton, systemName: "rotate.left", action: #selector(rotateLeftTapped),
                  accessibilityLabel: "Rotate left")
        configure(rotateRightButton, systemName: "rotate.right", action: #selector(rotateRightTapped),
                  accessibilityLabel: "Rotate right")
        configure(deleteButton, systemName: "trash", action: #selector(deleteTapped),
                  accessibilityLabel: "Delete")
        configure(shareButton, systemName: "square.and.arrow.up", action: #selector(shareTapped),
                  accessibilityLabel: "Share")
        configure(infoButton, systemName: "info.circle", action: #selector(infoTapped),
                  accessibilityLabel: "Info")

        rightStack.axis = .horizontal
        rightStack.spacing = 4
        rightStack.alignment = .center
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        // Live Text first: it appears and disappears per photo, and at the leading end of a
        // trailing-pinned stack that moves nothing else.
        [liveTextButton, rotateLeftButton, rotateRightButton, deleteButton, shareButton, infoButton]
            .forEach(rightStack.addArrangedSubview)

        addSubview(backButton)
        addSubview(rightStack)

        // Controls sit at the *bottom* of the bar, just above the home indicator; the
        // gradient extends upward behind them. Pinning them to the top instead would leave
        // them floating in the middle of the gradient.
        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 8),
            backButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            backButton.heightAnchor.constraint(equalToConstant: Self.contentHeight),
            rightStack.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
            rightStack.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            rightStack.heightAnchor.constraint(equalToConstant: Self.contentHeight)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure(_ button: UIButton,
                           systemName: String,
                           action: Selector,
                           accessibilityLabel: String) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: systemName,
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 19,
                                                                              weight: .medium))
        config.baseForegroundColor = .white
        // 44pt minimum touch target.
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = accessibilityLabel
        button.addTarget(self, action: action, for: .touchUpInside)
        // Symbols need a shadow to stay legible over bright photos.
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.35
        button.layer.shadowRadius = 3
        button.layer.shadowOffset = .zero
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
    }

    /// Rotation is images-only until M9 ships the video and Live Photo rotators (D10).
    func setRotationAvailable(_ available: Bool) {
        [rotateLeftButton, rotateRightButton].forEach {
            $0.isEnabled = available
            $0.alpha = available ? 1 : 0.35
        }
    }

    /// Hides the controls that change a photo, for a library the user does not own (§22).
    func setEditingAvailable(_ available: Bool) {
        [rotateLeftButton, rotateRightButton, deleteButton].forEach { $0.isHidden = !available }
    }

    /// Shown only once the current photo's analysis has found text; filled while highlighted.
    func setLiveText(available: Bool, highlighted: Bool) {
        liveTextButton.isHidden = !available
        guard var config = liveTextButton.configuration else { return }
        config.background.backgroundColor = highlighted ? UIColor.white.withAlphaComponent(0.28) : .clear
        config.background.cornerRadius = 10
        liveTextButton.configuration = config
        liveTextButton.accessibilityTraits = highlighted ? [.button, .selected] : .button
    }

    /// Touches only count inside the actual controls; the gradient area above them stays
    /// transparent to taps so the chrome toggle keeps working there.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        for control in [backButton, liveTextButton, rotateLeftButton, rotateRightButton, deleteButton,
                        shareButton, infoButton]
        where control.isEnabled && !control.isHidden && control.frame.contains(convert(point, to: control.superview)) {
            return true
        }
        return false
    }

    @objc private func backTapped() { onBack?() }
    @objc private func liveTextTapped() { onLiveText?() }
    @objc private func rotateLeftTapped() { onRotateLeft?() }
    @objc private func rotateRightTapped() { onRotateRight?() }
    @objc private func deleteTapped() { onDelete?() }
    @objc private func shareTapped() { onShare?() }
    @objc private func infoTapped() { onInfo?() }
}
