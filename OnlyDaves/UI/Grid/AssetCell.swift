import UIKit

/// One thumbnail tile.
///
/// Cheap by construction (§14 P3): no layer effects on the common image path, the video
/// scrim is created lazily only for video tiles, and the cell never decodes anything — it
/// only receives finished images from `ImageLoader`.
final class AssetCell: UICollectionViewCell {
    static let reuseIdentifier = "AssetCell"

    private let imageView = UIImageView()
    private var durationLabel: UILabel?
    private var scrimView: GradientView?
    private var cloudBadge: UIImageView?
    private var selectionOverlay: UIView?
    private var checkmark: UIImageView?

    private var token: ImageRequestToken?
    private weak var loader: ImageLoader?
    private(set) var representedID: AssetID?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.clipsToBounds = true
        contentView.backgroundColor = UIColor.secondarySystemBackground

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        loader?.cancel(token)
        token = nil
        representedID = nil
        imageView.image = nil
        imageView.alpha = 1
        setVideoChrome(visible: false, duration: 0)
        cloudBadge?.isHidden = true
        setSelected(false, animated: false)
    }

    func configure(stub: AssetStub, loader: ImageLoader, tileSize: CGSize, isSelected: Bool) {
        self.loader = loader
        representedID = stub.id

        setVideoChrome(visible: stub.kind == .video, duration: stub.durationSeconds)
        setCloudBadge(visible: stub.isRemoteOnly)
        setSelected(isSelected, animated: false)

        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        token = loader.requestImage(for: stub,
                                    variant: .gridThumb(pointSize: tileSize, scale: scale)) { [weak self] image, _ in
            // Guard against a cell that was reused while the request was in flight.
            guard let self, self.representedID == stub.id, let image else { return }
            self.imageView.image = image
        }
    }

    // MARK: - Selection (used from M4)

    func setSelected(_ selected: Bool, animated: Bool) {
        guard selected else {
            selectionOverlay?.isHidden = true
            checkmark?.isHidden = true
            return
        }
        if selectionOverlay == nil {
            let overlay = UIView(frame: contentView.bounds)
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.28)
            contentView.addSubview(overlay)
            selectionOverlay = overlay

            let mark = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
            mark.tintColor = .white
            mark.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(mark)
            NSLayoutConstraint.activate([
                mark.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
                mark.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4)
            ])
            checkmark = mark
        }
        selectionOverlay?.isHidden = false
        checkmark?.isHidden = false
    }

    // MARK: - Badges

    private func setCloudBadge(visible: Bool) {
        guard visible else { cloudBadge?.isHidden = true; return }
        if cloudBadge == nil {
            let badge = UIImageView(image: UIImage(systemName: "icloud.fill"))
            badge.tintColor = UIColor.white.withAlphaComponent(0.9)
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.layer.shadowColor = UIColor.black.cgColor
            badge.layer.shadowOpacity = 0.4
            badge.layer.shadowRadius = 2
            badge.layer.shadowOffset = .zero
            contentView.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
                badge.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4)
            ])
            cloudBadge = badge
        }
        cloudBadge?.isHidden = false
    }

    private func setVideoChrome(visible: Bool, duration: Float) {
        guard visible else {
            durationLabel?.isHidden = true
            scrimView?.isHidden = true
            return
        }
        if durationLabel == nil {
            let scrim = GradientView()
            scrim.translatesAutoresizingMaskIntoConstraints = false
            scrim.isUserInteractionEnabled = false
            contentView.addSubview(scrim)

            let label = UILabel()
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .white
            label.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(label)

            NSLayoutConstraint.activate([
                scrim.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                scrim.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                scrim.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                scrim.heightAnchor.constraint(equalToConstant: 26),
                label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
                label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3)
            ])
            scrimView = scrim
            durationLabel = label
        }
        scrimView?.isHidden = false
        durationLabel?.isHidden = false
        durationLabel?.text = Self.durationText(duration)
    }

    static func durationText(_ seconds: Float) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}

/// Bottom-up dark gradient used behind the video duration label.
final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        guard let layer = layer as? CAGradientLayer else { return }
        layer.colors = [UIColor.black.withAlphaComponent(0).cgColor,
                        UIColor.black.withAlphaComponent(0.55).cgColor]
        layer.startPoint = CGPoint(x: 0.5, y: 0)
        layer.endPoint = CGPoint(x: 0.5, y: 1)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
