import Foundation

/// Publishes backup progress to the UI (requirement 14).
@MainActor
final class BackupStatusStore: ObservableObject {

    /// What the sync engine is doing right now, or why it is not running.
    enum Phase: Equatable {
        case idle
        case scanning
        /// Hashing originals and asking the server which it already has.
        case preparing
        case uploading
        case waitingForNetwork
        /// Only metered networks are available and the user has not allowed mobile data.
        case waitingForWiFi
        case noPhotoAccess

        /// Set by the engine when it declines to start; survives the status refresh that follows.
        fileprivate var isWaiting: Bool {
            switch self {
            case .waitingForNetwork, .waitingForWiFi, .noPhotoAccess: return true
            default: return false
            }
        }
    }

    /// Items still owing the server an upload. Assets excluded by the chosen scope are *not*
    /// counted — the user deliberately left them out (D17).
    @Published private(set) var remainingCount: Int = 0
    @Published private(set) var isActivelyUploading = false
    @Published private(set) var isEnabled = false
    @Published private(set) var lastError: String?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var uploadBytesPerSecond: Double?
    /// Outstanding items that have used up their retries; the engine no longer tries them.
    @Published private(set) var failedCount: Int = 0
    /// Items whose last attempt failed but which have retries left, for the next sync run.
    @Published private(set) var retryingCount: Int = 0
    /// Items backed up since the queue was last empty, so progress reads "3/40" rather than
    /// a bare countdown. Grows the total too when new photos arrive mid-run.
    @Published private(set) var completedCount: Int = 0

    var totalCount: Int { completedCount + remainingCount }

    func update(remaining: Int, uploading: Bool, enabled: Bool, failed: Int = 0, retrying: Int = 0) {
        if !enabled || remaining == 0 {
            completedCount = 0
        } else if remaining < remainingCount {
            completedCount += remainingCount - remaining
        }
        remainingCount = remaining
        isActivelyUploading = uploading
        isEnabled = enabled
        failedCount = failed
        retryingCount = retrying
        if !uploading {
            if !phase.isWaiting { phase = .idle }
            uploadBytesPerSecond = nil
        }
    }

    func setError(_ message: String?) {
        lastError = message
    }

    func setPhase(_ phase: Phase) {
        self.phase = phase
        if phase != .uploading { uploadBytesPerSecond = nil }
    }

    /// Smoothed further than the meter's own window, because individual uploads starting and
    /// finishing make the raw rate swing on every reading.
    func setUploadRate(_ bytesPerSecond: Double?) {
        guard phase == .uploading else { return }
        guard let bytesPerSecond, let previous = uploadBytesPerSecond else {
            uploadBytesPerSecond = bytesPerSecond
            return
        }
        uploadBytesPerSecond = previous + (bytesPerSecond - previous) * Self.rateSmoothing
    }

    private static let rateSmoothing = 0.4

    var indicatorSymbol: String {
        if !isEnabled { return "icloud.slash" }
        if remainingCount > 0 { return isActivelyUploading ? "arrow.up.circle" : "icloud.and.arrow.up" }
        return "checkmark.icloud"
    }

    // MARK: - Progress text (grid info bar and Settings)

    /// The grid's info bar line, e.g. "3/40 · Uploading 376 kbps", or nil to hide the bar.
    /// Shown only while something is owed: once everything is backed up the nav-bar pill's
    /// checkmark says so without taking a row of the screen.
    var infoBarText: String? {
        guard isEnabled, let progressText else { return nil }
        return "\(progressText) · \(stateText)"
    }

    /// "3/40", or nil when nothing is owed.
    var progressText: String? {
        remainingCount > 0 ? "\(completedCount)/\(totalCount)" : nil
    }

    /// Fraction backed up this run, for the progress lines.
    var progress: Float {
        totalCount > 0 ? Float(completedCount) / Float(totalCount) : 0
    }

    var infoBarSymbol: String {
        switch phase {
        case .waitingForNetwork, .waitingForWiFi: return "wifi.slash"
        case .noPhotoAccess: return "exclamationmark.icloud"
        case .uploading: return "arrow.up.circle"
        case .scanning, .preparing: return "arrow.triangle.2.circlepath.icloud"
        case .idle: return lastError != nil || failedCount > 0
            ? "exclamationmark.icloud" : "icloud.and.arrow.up"
        }
    }

    /// What the engine is doing, or why it is not, with the upload rate when there is one.
    var stateText: String {
        guard let rateText else { return stateTitle }
        return "\(stateTitle) \(rateText)"
    }

    /// The upload rate, e.g. "376 kbps", while one is being measured.
    var rateText: String? {
        guard remainingCount > 0, phase == .uploading,
              let rate = uploadBytesPerSecond, rate > 0 else { return nil }
        return Self.formatBitRate(bytesPerSecond: rate)
    }

    /// `stateText` without the rate. The info bar shows the two apart, so that the rate can
    /// change every second without the rest of the line being redrawn.
    var stateTitle: String {
        if remainingCount == 0 { return "All backed up" }
        switch phase {
        case .scanning: return "Scanning library"
        case .preparing: return "Preparing"
        case .waitingForNetwork: return "Waiting for network"
        case .waitingForWiFi: return "Waiting for Wi-Fi"
        case .noPhotoAccess: return "No photo access"
        case .uploading: return "Uploading"
        case .idle:
            if let lastError { return lastError }
            if failedCount > 0 { return "\(failedCount) failed" }
            // A run stops once a round makes no progress; these go again on the next one,
            // which the next foreground, background task or network change starts.
            if retryingCount > 0 { return "\(retryingCount) to retry" }
            // Between launch and the first sync run, which waits for the grid to draw (D19).
            return "Queued"
        }
    }

    /// Network rates are conventionally quoted in bits, which is also what speed tests show.
    nonisolated static func formatBitRate(bytesPerSecond: Double) -> String {
        let bits = bytesPerSecond * 8
        if bits >= 1_000_000 {
            let mbps = bits / 1_000_000
            return mbps >= 10 ? "\(Int(mbps.rounded())) Mbps" : String(format: "%.1f Mbps", mbps)
        }
        return "\(max(1, Int((bits / 1_000).rounded()))) kbps"
    }
}
