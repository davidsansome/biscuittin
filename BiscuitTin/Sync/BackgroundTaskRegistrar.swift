import Foundation
import BackgroundTasks

/// Owns BGTaskScheduler registration (DESIGN.md D12).
///
/// Registration must happen before the app finishes launching, which is earlier than
/// `AppEnvironment` exists — hence the split: the app delegate registers the identifiers at
/// launch, and the environment supplies the handlers once it is built.
///
/// Submitting a request for an unregistered identifier raises an **Objective-C** exception
/// that Swift's `try`/`catch` cannot intercept, so it aborts the process. `canSubmit` is the
/// guard that makes that unreachable.
enum BackgroundTaskRegistrar {
    nonisolated(unsafe) private static var handlers: [String: (BGTask) -> Void] = [:]
    nonisolated(unsafe) private static var registered: Set<String> = []
    private static let lock = NSLock()

    static func canSubmit(_ identifier: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return registered.contains(identifier)
    }

    /// Call from `application(_:didFinishLaunchingWithOptions:)`, once per identifier.
    static func registerAtLaunch(identifier: String) {
        lock.lock()
        guard !registered.contains(identifier) else { lock.unlock(); return }
        lock.unlock()

        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            lock.lock()
            let handler = handlers[identifier]
            lock.unlock()
            guard let handler else {
                // Nothing wired up yet; let the system reschedule rather than hang.
                return task.setTaskCompleted(success: false)
            }
            handler(task)
        }

        lock.lock()
        if ok { registered.insert(identifier) }
        lock.unlock()

        if !ok {
            // Happens when the identifier is missing from BGTaskSchedulerPermittedIdentifiers,
            // and on some simulator configurations. Sync still works in the foreground.
            Log.sync.error("Background task registration refused for \(identifier, privacy: .public)")
        }
    }

    static func setHandler(for identifier: String, _ handler: @escaping (BGTask) -> Void) {
        lock.lock(); defer { lock.unlock() }
        handlers[identifier] = handler
    }
}
