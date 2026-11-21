import Foundation
import HearMeOutCore

/// Uploads audio straight to the media server with a background URLSession, so a transfer keeps going
/// while the window is closed or the app is in the background, and an upload that finished while the app
/// was quit is picked up on the next launch instead of being sent twice.
final class UploadManager: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = UploadManager()
    static let identifier = "uk.george-hall.hearmeout.uploads"

    private let lock = NSLock()
    private var waiters: [String: CheckedContinuation<Void, Error>] = [:]
    private var progress: [String: @Sendable (Double) -> Void] = [:]
    private var finished: [String: Result<Void, Error>] = [:]

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        c.isDiscretionary = false
        c.sessionSendsLaunchEvents = true
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 6 * 3600
        c.httpMaximumConnectionsPerHost = 3
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    /// Reconnects to the background session early so completed transfers are delivered.
    func activate() { _ = session }

    func upload(file: URL, ticket: UploadTicket, itemId: UUID, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let key = itemId.uuidString
        lock.lock()
        if let done = finished.removeValue(forKey: key) {
            lock.unlock()
            return try done.get()
        }
        progress[key] = onProgress
        lock.unlock()

        let tasks = await session.allTasks
        let existing = tasks.first { $0.taskDescription == key && $0.state == .running }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                if let done = finished.removeValue(forKey: key) {
                    lock.unlock()
                    cont.resume(with: done)
                    return
                }
                waiters[key] = cont
                lock.unlock()
                if existing == nil {
                    var req = URLRequest(url: ticket.uploadURL)
                    req.httpMethod = ticket.method
                    for (k, v) in ticket.headers { req.setValue(v, forHTTPHeaderField: k) }
                    let task = session.uploadTask(with: req, fromFile: file)
                    task.taskDescription = key
                    task.resume()
                }
            }
        } onCancel: {
            Task { [session] in
                for t in await session.allTasks where t.taskDescription == key { t.cancel() }
            }
        }
    }

    // MARK: Delegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let key = task.taskDescription, totalBytesExpectedToSend > 0 else { return }
        lock.lock(); let cb = progress[key]; lock.unlock()
        cb?(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = task.taskDescription else { return }
        let result: Result<Void, Error>
        if let error = error as NSError? {
            result = .failure(error.code == NSURLErrorCancelled ? CancellationError() : UploadError.network(error.localizedDescription))
        } else {
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300: result = .success(())
            case 401, 403: result = .failure(UploadError.tokenRejected)
            case 409: result = .failure(UploadError.alreadyFinalised)
            case 413: result = .failure(UploadError.tooLarge)
            default: result = .failure(UploadError.server(status))
            }
        }
        lock.lock()
        progress[key] = nil
        if let w = waiters.removeValue(forKey: key) {
            lock.unlock()
            w.resume(with: result)
        } else {
            finished[key] = result
            lock.unlock()
        }
    }
}
