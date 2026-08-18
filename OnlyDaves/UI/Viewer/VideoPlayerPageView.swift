import UIKit
import AVFoundation

/// One video page in the viewer (DESIGN.md §13.2).
///
/// The poster frame shows instantly and the player is attached asynchronously, so paging onto
/// a video never stalls the swipe (§14 P4). Playback starts when the page becomes current and
/// stops when it is paged away; the transport controls follow the chrome.
final class VideoPlayerPageView: UIView {

    var onSingleTap: (() -> Void)?

    private let posterImageView = UIImageView()
    private let playerContainer = PlayerLayerView()
    private let activityIndicator = UIActivityIndicatorView(style: .large)
    private let playPauseButton = UIButton(type: .system)
    private let scrubber = UISlider()
    private let elapsedLabel = UILabel()
    private let remainingLabel = UILabel()
    private let controlsStack = UIStackView()
    private let errorLabel = UILabel()

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var isScrubbing = false
    private var loadTask: Task<Void, Never>?

    /// Distance from the bottom edge reserved for the viewer toolbar, including its safe-area
    /// inset. The caller supplies the final value; nothing is added on top of it here.
    var bottomInset: CGFloat = 8 {
        didSet { controlsBottomConstraint?.constant = -bottomInset }
    }
    private var controlsBottomConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        configureSubviews()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { detachPlayer() }

    // MARK: - Setup

    private func configureSubviews() {
        posterImageView.contentMode = .scaleAspectFit
        posterImageView.frame = bounds
        posterImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(posterImageView)

        playerContainer.frame = bounds
        playerContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        playerContainer.isHidden = true
        addSubview(playerContainer)

        activityIndicator.color = .white
        activityIndicator.hidesWhenStopped = true
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(activityIndicator)

        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "play.circle.fill",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 56))
        config.baseForegroundColor = .white
        playPauseButton.configuration = config
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.layer.shadowColor = UIColor.black.cgColor
        playPauseButton.layer.shadowOpacity = 0.35
        playPauseButton.layer.shadowRadius = 8
        playPauseButton.layer.shadowOffset = .zero
        playPauseButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)
        addSubview(playPauseButton)

        errorLabel.textColor = .white
        errorLabel.font = .preferredFont(forTextStyle: .subheadline)
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(errorLabel)

        for label in [elapsedLabel, remainingLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            label.textColor = .white
            label.text = "0:00"
        }
        remainingLabel.textAlignment = .right

        scrubber.minimumTrackTintColor = .white
        scrubber.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        scrubber.setThumbImage(Self.thumbImage(), for: .normal)
        scrubber.addTarget(self, action: #selector(scrubbingBegan), for: .touchDown)
        scrubber.addTarget(self, action: #selector(scrubbingChanged), for: .valueChanged)
        scrubber.addTarget(self, action: #selector(scrubbingEnded),
                           for: [.touchUpInside, .touchUpOutside, .touchCancel])

        controlsStack.axis = .horizontal
        controlsStack.alignment = .center
        controlsStack.spacing = 8
        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        controlsStack.addArrangedSubview(elapsedLabel)
        controlsStack.addArrangedSubview(scrubber)
        controlsStack.addArrangedSubview(remainingLabel)
        addSubview(controlsStack)

        let bottom = controlsStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        controlsBottomConstraint = bottom

        NSLayoutConstraint.activate([
            activityIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            playPauseButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            playPauseButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            errorLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            errorLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            errorLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            controlsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            controlsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            bottom,
            elapsedLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
            remainingLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
    }

    private static func thumbImage() -> UIImage {
        let size = CGSize(width: 12, height: 12)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - Content

    func setPoster(_ image: UIImage?) {
        posterImageView.image = image
    }

    /// Attaches a player. Safe to call repeatedly; the previous player is torn down first.
    func attach(player: AVPlayer, autoplay: Bool) {
        detachPlayer()
        self.player = player
        playerContainer.playerLayer.player = player
        playerContainer.isHidden = false
        errorLabel.isHidden = true
        activityIndicator.stopAnimating()

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            self?.updateProgress(time: time)
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            self?.handlePlaybackEnded()
        }

        if autoplay {
            play()
        } else {
            updatePlayPauseIcon(isPlaying: false)
        }
    }

    func showLoading() {
        activityIndicator.startAnimating()
        playPauseButton.isHidden = true
    }

    func showError(_ message: String) {
        activityIndicator.stopAnimating()
        playPauseButton.isHidden = true
        controlsStack.isHidden = true
        errorLabel.text = message
        errorLabel.isHidden = false
    }

    func detachPlayer() {
        loadTask?.cancel()
        loadTask = nil
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        statusObservation = nil
        player?.pause()
        player = nil
        playerContainer.playerLayer.player = nil
        playerContainer.isHidden = true
        scrubber.value = 0
        elapsedLabel.text = "0:00"
        updatePlayPauseIcon(isPlaying: false)
    }

    func setLoadTask(_ task: Task<Void, Never>?) {
        loadTask?.cancel()
        loadTask = task
    }

    // MARK: - Transport

    func play() {
        guard let player else { return }
        player.play()
        updatePlayPauseIcon(isPlaying: true)
    }

    func pause() {
        player?.pause()
        updatePlayPauseIcon(isPlaying: false)
    }

    var isPlaying: Bool {
        guard let player else { return false }
        return player.timeControlStatus == .playing
    }

    @objc private func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            pause()
        } else {
            // Restart from the beginning if we are parked at the end.
            if let item = player.currentItem,
               item.duration.isNumeric,
               player.currentTime() >= item.duration - CMTime(value: 1, timescale: 10) {
                player.seek(to: .zero)
            }
            play()
        }
    }

    @objc private func handleTap() {
        onSingleTap?()
    }

    /// Chrome visibility drives the transport controls too.
    func setControlsVisible(_ visible: Bool, animated: Bool) {
        let apply = {
            self.playPauseButton.alpha = visible ? 1 : 0
            self.controlsStack.alpha = visible ? 1 : 0
        }
        animated ? UIView.animate(withDuration: 0.2, animations: apply) : apply()
    }

    // MARK: - Progress

    private func updateProgress(time: CMTime) {
        guard !isScrubbing,
              let item = player?.currentItem,
              item.duration.isNumeric, item.duration.seconds > 0 else { return }

        let elapsed = time.seconds
        let duration = item.duration.seconds
        scrubber.value = Float(elapsed / duration)
        elapsedLabel.text = AssetCell.durationText(Float(elapsed))
        remainingLabel.text = "-" + AssetCell.durationText(Float(max(0, duration - elapsed)))
        updatePlayPauseIcon(isPlaying: player?.timeControlStatus == .playing)
    }

    private func handlePlaybackEnded() {
        updatePlayPauseIcon(isPlaying: false)
    }

    private func updatePlayPauseIcon(isPlaying: Bool) {
        playPauseButton.isHidden = false
        let name = isPlaying ? "pause.circle.fill" : "play.circle.fill"
        playPauseButton.configuration?.image = UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 56))
    }

    @objc private func scrubbingBegan() { isScrubbing = true }

    @objc private func scrubbingChanged() {
        guard let item = player?.currentItem, item.duration.isNumeric else { return }
        let target = Double(scrubber.value) * item.duration.seconds
        elapsedLabel.text = AssetCell.durationText(Float(target))
        remainingLabel.text = "-" + AssetCell.durationText(Float(max(0, item.duration.seconds - target)))
    }

    @objc private func scrubbingEnded() {
        defer { isScrubbing = false }
        guard let player, let item = player.currentItem, item.duration.isNumeric else { return }
        let target = CMTime(seconds: Double(scrubber.value) * item.duration.seconds,
                            preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

/// A view whose backing layer is an `AVPlayerLayer`, so playback resizes with the view.
private final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
