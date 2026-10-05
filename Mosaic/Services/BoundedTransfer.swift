import Foundation

// Signed cloud responses are read in chunks under a strict byte budget, even when
// Content-Length is absent or dishonest. Ephemeral sessions do not persist signed
// URLs. Redirects are rejected; users must configure their provider's real endpoint.
final class BoundedTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Failure: LocalizedError {
        case tooLarge, redirect, invalidResponse
        var errorDescription: String? {
            switch self {
            case .tooLarge: "The server response exceeds the download limit."
            case .redirect: "The server redirected this request. Use its final HTTPS endpoint."
            case .invalidResponse: "The server did not return a valid response."
            }
        }
    }
    // All delegate state is confined to a serial delegate queue. The lock only
    // protects cancellation registration, which can occur before the task exists.
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private let configuration: URLSessionConfiguration
    private let limit: Int
    private var count = 0
    private var data = Data()
    private let file: URL?
    private var handle: FileHandle?
    private var failure: Error?
    private var completion: CheckedContinuation<Data, Error>?
    private init(limit: Int, file: URL?, configuration: URLSessionConfiguration) {
        self.configuration = configuration
        self.limit = limit
        self.file = file
    }

    static func read(
        _ request: URLRequest, limit: Int, to file: URL? = nil,
        configuration: URLSessionConfiguration = .ephemeral
    ) async throws -> Data {
        let transfer = BoundedTransfer(limit: limit, file: file, configuration: configuration)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in transfer.start(request, continuation)
            }
        } onCancel: {
            transfer.cancel()
        }
    }
    private func start(_ request: URLRequest, _ continuation: CheckedContinuation<Data, Error>) {
        do {
            if let file {
                guard !FileManager.default.fileExists(atPath: file.path),
                    FileManager.default.createFile(atPath: file.path, contents: nil)
                else {
                    throw CocoaError(.fileWriteUnknown)
                }
                handle = try FileHandle(forWritingTo: file)
            }
        } catch {
            continuation.resume(throwing: error)
            return
        }
        completion = continuation
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        lock.lock()
        let task = session.dataTask(with: request)
        self.task = task
        let shouldCancel = cancelled
        lock.unlock()
        task.resume()
        if shouldCancel { task.cancel() }
    }
    private func cancel() {
        lock.lock()
        cancelled = true
        let active = task
        lock.unlock()
        active?.cancel()
    }
    static func fits(received: Int, incoming: Int, limit: Int) -> Bool {
        received >= 0 && incoming >= 0 && received <= limit && incoming <= limit - received
    }
    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            failure = failure ?? CloudError.response((response as? HTTPURLResponse)?.statusCode ?? 0)
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= Int64(limit) else {
            failure = Failure.tooLarge
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard failure == nil else { return }
        guard Self.fits(received: count, incoming: chunk.count, limit: limit) else {
            failure = Failure.tooLarge
            dataTask.cancel()
            return
        }
        do {
            count += chunk.count
            if let handle { try handle.write(contentsOf: chunk) } else { data.append(chunk) }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        failure = Failure.redirect
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        if let error = failure ?? error {
            if let file { try? FileManager.default.removeItem(at: file) }
            completion?.resume(throwing: error)
        } else {
            completion?.resume(returning: data)
        }
        completion = nil
        self.session = nil
        session.finishTasksAndInvalidate()
    }
}
