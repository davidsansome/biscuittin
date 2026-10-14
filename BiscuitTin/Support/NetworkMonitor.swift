import Foundation
import Network

/// Whether the device currently has a usable network path, and whether it is metered.
///
/// Uploads consult it so an outage pauses the queue instead of spending each item's retries
/// (`SyncEngine.maxRetries`) on failures that say nothing about the item itself.
final class NetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var satisfied = true
    private var expensive = false
    private var onChange: (@Sendable () -> Void)?

    /// Optimistic until the first path update: being wrong costs one failed request, while
    /// starting pessimistic would hold uploads back on every launch.
    var isSatisfied: Bool {
        lock.lock(); defer { lock.unlock() }
        return satisfied
    }

    /// Cellular or a personal hotspot.
    var isExpensive: Bool {
        lock.lock(); defer { lock.unlock() }
        return expensive
    }

    /// Calls `onChange` whenever the path becomes usable or unusable, or switches between
    /// metered and unmetered — e.g. on walking from mobile data into Wi-Fi.
    func start(onChange: @escaping @Sendable () -> Void) {
        lock.lock()
        self.onChange = onChange
        lock.unlock()

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            let before = (self.satisfied, self.expensive)
            self.satisfied = path.status == .satisfied
            self.expensive = path.isExpensive
            let callback = before != (self.satisfied, self.expensive) ? self.onChange : nil
            self.lock.unlock()
            callback?()
        }
        monitor.start(queue: DispatchQueue(label: "dev.biscuittin.network-monitor", qos: .utility))
    }

    /// Errors that mean the path went away mid-request rather than that the request was bad.
    static func isConnectivityError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
             .internationalRoamingOff, .callIsActive:
            return true
        default:
            return false
        }
    }
}

/// A sliding-window transfer rate, fed from URLSession's progress callbacks.
final class TransferRateMeter: @unchecked Sendable {
    private static let window: TimeInterval = 3

    private let lock = NSLock()
    private var samples: [(time: TimeInterval, bytes: Int64)] = []
    private var startedAt: TimeInterval?

    func record(bytes: Int64, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        if startedAt == nil { startedAt = now }
        samples.append((now, bytes))
    }

    /// Bytes per second over the last few seconds, or nil before anything has been sent.
    func bytesPerSecond(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let startedAt else { return nil }
        samples.removeAll { now - $0.time > Self.window }
        let total = samples.reduce(Int64(0)) { $0 + $1.bytes }
        // Divide by the time actually observed while the window is still filling, or the first
        // seconds of every run would read as a fraction of the true rate.
        let span = max(min(Self.window, now - startedAt), 0.5)
        return Double(total) / span
    }
}
