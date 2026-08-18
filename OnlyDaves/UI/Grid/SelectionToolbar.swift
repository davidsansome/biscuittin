import UIKit

/// Bottom bar shown in the grid's multi-select mode (requirement 11).
///
/// Mirrors the viewer toolbar's action set — back, rotate left, rotate right, delete — but sits
/// on a material background rather than a gradient, because it appears over the light grid
/// rather than over a photo.
final class SelectionToolbar: UIView {

    var onCancel: (() -> Void)?
    var onRotateLeft: (() -> Void)?
    var onRotateRight: (() -> Void)?
    var onDelete: (() -> Void)?

    static let contentHeight: CGFloat = 56

    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private let separator = UIView()
    private let cancelButton = UIButton(type: .system)
    private let rotateLeftButton = UIButton(type: .system)
    private let rotateRightButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let rightStack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        blur.frame = bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(blur)

        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        configure(cancelButton, systemName: "chevron.backward", action: #selector(cancelTapped),
                  label: "Cancel selection", tint: .label)
        configure(rotateLeftButton, systemName: "rotate.left", action: #selector(rotateLeftTapped),
                  label: "Rotate left", tint: .label)
        configure(rotateRightButton, systemName: "rotate.right", action: #selector(rotateRightTapped),
                  label: "Rotate right", tint: .label)
        configure(deleteButton, systemName: "trash", action: #selector(deleteTapped),
                  label: "Delete", tint: .systemRed)

        rightStack.axis = .horizontal
        rightStack.spacing = 4
        rightStack.alignment = .center
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        [rotateLeftButton, rotateRightButton, deleteButton].forEach(rightStack.addArrangedSubview)

        addSubview(cancelButton)
        addSubview(rightStack)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            cancelButton.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 8),
            cancelButton.topAnchor.constraint(equalTo: topAnchor),
            cancelButton.heightAnchor.constraint(equalToConstant: Self.contentHeight),

            rightStack.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
            rightStack.topAnchor.constraint(equalTo: topAnchor),
            rightStack.heightAnchor.constraint(equalToConstant: Self.contentHeight)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure(_ button: UIButton,
                           systemName: String,
                           action: Selector,
                           label: String,
                           tint: UIColor) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: systemName,
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 19,
                                                                              weight: .medium))
        config.baseForegroundColor = tint
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = label
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    /// Actions are meaningless with an empty selection, and rotation is unavailable when the
    /// selection contains nothing rotatable (D10).
    func update(selectionCount: Int, canRotateAny: Bool) {
        let hasSelection = selectionCount > 0
        for button in [rotateLeftButton, rotateRightButton] {
            button.isEnabled = hasSelection && canRotateAny
            button.alpha = button.isEnabled ? 1 : 0.35
        }
        deleteButton.isEnabled = hasSelection
        deleteButton.alpha = hasSelection ? 1 : 0.35
    }

    @objc private func cancelTapped() { onCancel?() }
    @objc private func rotateLeftTapped() { onRotateLeft?() }
    @objc private func rotateRightTapped() { onRotateRight?() }
    @objc private func deleteTapped() { onDelete?() }
}
