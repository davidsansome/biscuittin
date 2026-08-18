import Foundation

/// Publishes backup progress to the UI (requirement 14).
@MainActor
final class BackupStatusStore: ObservableObject {
    /// Items still owing the server an upload. Assets excluded by the chosen scope are *not*
    /// counted — the user deliberately left them out (D17).
    @Published private(set) var remainingCount: Int = 0
    @Published private(set) var isActivelyUploading = false
    @Published private(set) var isEnabled = false
    @Published private(set) var lastError: String?

    func update(remaining: Int, uploading: Bool, enabled: Bool) {
        remainingCount = remaining
        isActivelyUploading = uploading
        isEnabled = enabled
    }

    func setError(_ message: String?) {
        lastError = message
    }

    /// What the grid's nav-bar pill should show, or nil when the indicator is hidden.
    var indicatorText: String? {
        guard isEnabled else { return nil }
        return remainingCount > 0 ? "\(remainingCount)" : nil
    }

    var indicatorSymbol: String {
        if !isEnabled { return "icloud.slash" }
        if remainingCount > 0 { return isActivelyUploading ? "arrow.up.circle" : "icloud.and.arrow.up" }
        return "checkmark.icloud"
    }
}
