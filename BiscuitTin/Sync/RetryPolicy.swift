import Foundation
import Photos

/// How failed uploads and pending edits are retried (DESIGN.md §12, D22). Nothing is abandoned:
/// a failure that is the item's fault waits longer each time, and one that is not (no network,
/// a server that is down, an expired sign-in) does not count against the item at all.
enum RetryPolicy {
    enum FailureKind { case transient, authentication, item }

    private static let firstDelay: TimeInterval = 60
    private static let maxDelay: TimeInterval = 6 * 60 * 60

    /// 1 failure: 60 s, doubling per failure, capped at 6 hours. 0 failures: 0.
    static func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        // 2^9 minutes already exceeds the cap; stopping there keeps the shift from overflowing.
        let doublings = min(failures - 1, 9)
        return min(firstDelay * Double(1 << doublings), maxDelay)
    }

    static func kind(of error: Error) -> FailureKind {
        if error is CancellationError { return .transient }
        if let urlError = error as? URLError, urlError.code == .cancelled { return .transient }
        if NetworkMonitor.isConnectivityError(error) { return .transient }
        let nsError = error as NSError
        if nsError.domain == PHPhotosErrorDomain {
            if nsError.code == PHPhotosError.networkAccessRequired.rawValue { return .transient }
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
               NetworkMonitor.isConnectivityError(underlying) {
                return .transient
            }
        }
        if let immich = error as? ImmichError {
            switch immich {
            case .unreachable:
                return .transient
            case .unauthorized, .notConfigured:
                return .authentication
            case .http(let status) where status == 408 || status == 429 || status >= 500:
                return .transient
            default:
                return .item
            }
        }
        return .item
    }

    /// PhotoKit itself refused to read the asset's bytes (e.g. an orphaned iCloud asset whose
    /// original is missing and unplayable even in Apple Photos). After repeated failures while
    /// online, these are marked `.ineligible` rather than staying "failed" forever.
    static func isPhotoKitError(_ error: Error) -> Bool {
        (error as NSError).domain == PHPhotosErrorDomain
    }
}

/// How long uploads wait after the server answered but could not take one: 30 s, doubling
/// up to 15 minutes, back to 30 s after any upload succeeds.
struct ServerPause {
    private static let first: TimeInterval = 30
    private static let max: TimeInterval = 900

    private(set) var next: TimeInterval = ServerPause.first

    /// Returns the current pause, then doubles it.
    mutating func take() -> TimeInterval {
        let current = next
        next = min(next * 2, Self.max)
        return current
    }

    mutating func reset() {
        next = Self.first
    }
}
