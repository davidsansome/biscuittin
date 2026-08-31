import Foundation
import BackgroundTasks

/// Owns BGTaskScheduler registration (DESIGN.md D12).
///
/// Registration must happen before the app finishes launching, which is earlier than
/// `AppEnvironment` exists — hence the split: the app delegate registers the identifier at
/// launch, and the environment supplies the handler once it is built.
///
/// Submitting a request for an unregistered identifier raises an **Objective-C** exception
/// that Swift's `try`/`catch` cannot intercept, so it aborts the process. `canSubmit` is the
/// guard that makes that unreachable.
enum BackgroundTaskRegistrar {
    nonisolated(unsafe) private static var handler: ((BGProcessingTask) -> Void)?
    nonisolated(unsafe) private static var registered = false
    private static let lock = NSLock()

    static var canSubmit: Bool {
        lock.lock(); defer { lock.unlock() }
        return registered
    }

    /// Call from `application(_:didFinishLaunchingWithOptions:)`, once.
    static func registerAtLaunch(identifier: String) {
        lock.lock()
        guard !registered else { lock.unlock(); return }
        lock.unlock()

        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let processing = task as? BGProcessingTask else {
                return task.setTaskCompleted(success: false)
            }
            guard let handler = BackgroundTaskRegistrar.handler else {
                // Nothing wired up yet; let the system reschedule rather than hang.
                return processing.setTaskCompleted(success: false)
            }
            handler(processing)
        }

        lock.lock()
        registered = ok
        lock.unlock()

        if !ok {
            // Happens when the identifier is missing from BGTaskSchedulerPermittedIdentifiers,
            // and on some simulator configurations. Sync still works in the foreground.
            Log.sync.error("Background task registration refused for \(identifier, privacy: .public)")
        }
    }

    static func setHandler(_ handler: @escaping (BGProcessingTask) -> Void) {
        self.handler = handler
    }
}
