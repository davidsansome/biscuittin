import Foundation

/// Bridges a PhotoKit request identifier into `withTaskCancellationHandler` without racing
/// between task cancellation and the request returning its ID.
final class CancellableRequestBox<ID: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var id: ID?
    private var isCancelled = false

    func store(_ requestID: ID, cancel: (ID) -> Void) {
        lock.lock()
        let shouldCancel = isCancelled
        if !shouldCancel {
            id = requestID
        }
        lock.unlock()
        if shouldCancel {
            cancel(requestID)
        }
    }

    func cancel(using cancel: (ID) -> Void) {
        lock.lock()
        isCancelled = true
        let existing = id
        id = nil
        lock.unlock()
        if let existing {
            cancel(existing)
        }
    }
}
