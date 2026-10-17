import Foundation

/// Runs uploads on a background `URLSession` (DESIGN.md D12).
///
/// The transfers happen in the system's upload daemon, so they carry on while the app is
/// suspended or not running, and iOS relaunches the app in the background to report how they
/// ended. The process that hears of a completion may therefore not be the one that started the
/// upload, so everything the bookkeeping needs travels with the task as its `Ticket`.
///
/// Background sessions do not support per-task delegates or the async `upload(for:)` API:
/// every callback arrives at this one session-level delegate.
final class BackgroundUploader: NSObject, @unchecked Sendable {
    static let shared = BackgroundUploader()
    static let sessionIdentifier = "dev.biscuittin.uploads"

    /// Carried in `taskDescription`, which the system keeps across relaunches.
    struct Ticket: Codable, Sendable, Equatable {
        let localIdentifier: String
        let checksumHex: String
        let filename: String
        let byteCount: Int64
        /// The multipart body's file name inside `bodyDirectory`.
        let bodyFilename: String
        /// The asset's modification date when its original was exported, to catch an edit
        /// made while the upload was in flight (`SyncEngine.queueReconcileIfEdited`).
        let modifiedBeforeExport: Date?
    }

    struct Outcome: Sendable {
        let ticket: Ticket
        let result: Result<Immich.UploadResponse?, Error>
    }

    /// Multipart bodies waiting for the daemon. Not the temporary directory: iOS may clear that
    /// while the app is not running, and the daemon reads a body only when its task starts.
    static let bodyDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var url = base.appendingPathComponent("PendingUploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }()

    /// Fed from the daemon's progress callbacks while the app is running, for the info bar.
    let meter = TransferRateMeter()

    private let lock = NSLock()
    private var _session: URLSession?
    private var responseBodies: [Int: Data] = [:]
    private var handler: (@Sendable (Outcome) async -> Void)?
    private var undelivered: [Outcome] = []
    private var recording: [UUID: Task<Void, Never>] = [:]
    private var finishEvents: (() -> Void)?

    /// Created on first use rather than at launch: recreating it with the same identifier is
    /// what reconnects to transfers a previous process started, and their completions wait in
    /// the daemon until then.
    private var session: URLSession {
        lock.lock(); defer { lock.unlock() }
        if let _session { return _session }
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        // Uploads queued from the foreground should start now. The system treats those queued
        // from the background as discretionary whatever this says.
        config.isDiscretionary = false
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        _session = session
        return session
    }

    /// Receives every outcome, including any that arrived before it was set.
    func setHandler(_ handler: @escaping @Sendable (Outcome) async -> Void) {
        lock.lock()
        self.handler = handler
        let pending = undelivered
        undelivered = []
        lock.unlock()
        pending.forEach(deliver)
    }

    /// Hands one upload to the daemon. The body file is deleted when the task ends.
    func enqueue(_ request: URLRequest, bodyURL: URL, ticket: Ticket) throws {
        let task = session.uploadTask(with: request, fromFile: bodyURL)
        task.taskDescription = String(decoding: try JSONEncoder().encode(ticket), as: UTF8.self)
        task.resume()
    }

    /// Uploads the daemon still owes an outcome for.
    func inFlightTickets() async -> [Ticket] {
        await session.allTasks
            .filter { $0.state != .completed }
            .compactMap(Self.ticket(of:))
    }

    /// Their outcomes arrive as `URLError.cancelled`, which the engine treats as "not this
    /// item's fault" and returns to the queue.
    func cancelAll() async {
        for task in await session.allTasks { task.cancel() }
    }

    /// Deletes bodies no live task will read: left by a process that was killed between
    /// writing a body and enqueueing it. Call only when nothing is being enqueued.
    func removeOrphanedBodies() async {
        let live = Set(await inFlightTickets().map(\.bodyFilename))
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.bodyDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where !live.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// From `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    func handleEvents(completion: @escaping () -> Void) {
        lock.lock()
        finishEvents = completion
        lock.unlock()
        _ = session
    }

    private static func ticket(of task: URLSessionTask) -> Ticket? {
        guard let description = task.taskDescription else { return nil }
        return try? JSONDecoder().decode(Ticket.self, from: Data(description.utf8))
    }

    private func deliver(_ outcome: Outcome) {
        lock.lock()
        guard let handler else {
            undelivered.append(outcome)
            lock.unlock()
            return
        }
        let id = UUID()
        recording[id] = Task {
            await handler(outcome)
            self.finishedRecording(id)
        }
        lock.unlock()
    }

    private func finishedRecording(_ id: UUID) {
        lock.withLock { _ = recording.removeValue(forKey: id) }
    }

    static func result(response: URLResponse?, body: Data?,
                       error: Error?) -> Result<Immich.UploadResponse?, Error> {
        if let error { return .failure(error) }
        guard let http = response as? HTTPURLResponse else { return .success(nil) }
        switch http.statusCode {
        case 200..<300:
            return .success(body.flatMap { try? JSONDecoder().decode(Immich.UploadResponse.self, from: $0) })
        case 401, 403:
            return .failure(ImmichError.unauthorized)
        default:
            return .failure(ImmichError.http(status: http.statusCode))
        }
    }
}

extension BackgroundUploader: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); defer { lock.unlock() }
        responseBodies[dataTask.taskIdentifier, default: Data()].append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        meter.record(bytes: bytesSent)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let body = responseBodies.removeValue(forKey: task.taskIdentifier)
        lock.unlock()

        guard let ticket = Self.ticket(of: task) else { return }
        try? FileManager.default.removeItem(
            at: Self.bodyDirectory.appendingPathComponent(ticket.bodyFilename))
        deliver(Outcome(ticket: ticket,
                        result: Self.result(response: task.response, body: body, error: error)))
    }

    /// Every outcome of this launch has been delivered. The system may suspend the app as soon
    /// as `finishEvents` runs, so it waits for them to be recorded first.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let pending = Array(recording.values)
        let finish = finishEvents
        finishEvents = nil
        lock.unlock()

        Task {
            for task in pending { await task.value }
            if let finish { DispatchQueue.main.async(execute: finish) }
        }
    }
}
