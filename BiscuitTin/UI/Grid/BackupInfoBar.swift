import UIKit

/// Thin strip under the grid's navigation bar describing backup progress (requirement 14):
/// the state and rate on the left, e.g. "Uploading 376 kbps", and the count on the right.
/// Content scrolls beneath it, hence the material.
///
/// Anchored to both edges rather than centred, so that a change in the text's width moves
/// only its end and not the whole line.
final class BackupInfoBar: UIControl {

    static let height: CGFloat = 30

    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let rateLabel = UILabel()
    private let countLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .bar)

    override init(frame: CGRect) {
        super.init(frame: frame)

        blur.frame = bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        blur.isUserInteractionEnabled = false
        addSubview(blur)

        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote)
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        let font = UIFont.monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
        for label in [titleLabel, rateLabel, countLabel] {
            label.font = font
            label.textColor = .secondaryLabel
        }
        titleLabel.lineBreakMode = .byTruncatingTail
        // On a narrow screen the rate gives way first, then the state; the count never does.
        titleLabel.setContentCompressionResistancePriority(.defaultHigh - 1, for: .horizontal)
        rateLabel.setContentCompressionResistancePriority(.defaultHigh - 2, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        let leading = UIStackView(arrangedSubviews: [iconView, titleLabel, rateLabel])
        leading.axis = .horizontal
        leading.spacing = 6
        leading.alignment = .center
        leading.setCustomSpacing(4, after: titleLabel)
        leading.isUserInteractionEnabled = false
        leading.translatesAutoresizingMaskIntoConstraints = false
        addSubview(leading)

        countLabel.isUserInteractionEnabled = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)

        progressView.trackTintColor = .clear
        progressView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progressView)

        NSLayoutConstraint.activate([
            leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            leading.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            leading.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -12),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            progressView.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: trailingAnchor),
            progressView.bottomAnchor.constraint(equalTo: bottomAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2)
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = "Opens backup settings"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// - Parameters:
    ///   - title: What backup is doing, e.g. "Uploading". A change crossfades.
    ///   - rate: e.g. "376 kbps". Changes in place: it updates every second, and fading each
    ///     update would leave the line permanently shimmering.
    ///   - count: e.g. "3/40".
    func configure(title: String, rate: String?, count: String, symbol: String, progress: Float) {
        if titleLabel.text != nil && (titleLabel.text != title || symbolName != symbol) {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.2
            titleLabel.layer.add(fade, forKey: "fade")
            iconView.layer.add(fade, forKey: "fade")
        }
        titleLabel.text = title
        if symbolName != symbol {
            iconView.image = UIImage(systemName: symbol)
            symbolName = symbol
        }
        rateLabel.text = rate
        rateLabel.isHidden = rate == nil
        countLabel.text = count
        progressView.setProgress(progress, animated: progressView.progress < progress)
        accessibilityLabel = "Backup: \(count), \([title, rate].compactMap { $0 }.joined(separator: " "))"
    }

    private var symbolName: String?

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }
}
