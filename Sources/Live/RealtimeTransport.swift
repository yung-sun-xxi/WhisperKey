import Foundation

// A WebSocket, not WebRTC. WebRTC and ephemeral client secrets exist so that a browser never
// holds the API key; this native app reads the key from the user's own Keychain and connects
// directly, which is the server-to-server path of the Realtime WebSocket guide
// (https://developers.openai.com/api/docs/guides/realtime-websocket).
//
// Live is OpenAI-only — see LiveAvailability.swift for why the transcription-provider choice
// does not apply here.

/// A text-message socket to the Realtime API. The app layer owns one per session; tests and
/// LiveSession never touch it.
public protocol RealtimeTransporting: AnyObject, Sendable {
    /// Opens the socket and returns once the handshake succeeded. Server messages arrive on
    /// the stream until the socket closes; a close the caller did not ask for ends the stream
    /// with a `RealtimeTransportError`.
    func connect() async throws -> AsyncThrowingStream<String, Error>
    func send(text: String) async throws
    func send(data: Data) async throws
    /// Closes the socket. Safe to call more than once, and before `connect` finished.
    func close()
}

public enum RealtimeTransportError: Error, Equatable, Sendable {
    case apiKeyRejected
    case handshakeFailed(statusCode: Int)
    case connectionLost(String)
    case closed(code: Int, reason: String?)
    case notConnected

    /// A failed WebSocket upgrade, by its HTTP status.
    public static func handshake(statusCode: Int) -> RealtimeTransportError {
        statusCode == 401 ? .apiKeyRejected : .handshakeFailed(statusCode: statusCode)
    }

    /// A close frame the caller did not ask for.
    public static func close(code: Int, reason: String?) -> RealtimeTransportError {
        if let reason, reason.localizedCaseInsensitiveContains("api key") || reason.contains("invalid_api_key") {
            return .apiKeyRejected
        }
        return .closed(code: code, reason: reason)
    }

    /// The text for the island and the error toast.
    public var message: String {
        switch self {
        case .apiKeyRejected:
            return "OpenAI rejected the API key"
        case .handshakeFailed(let statusCode):
            return "OpenAI refused the Live connection (HTTP \(statusCode))"
        case .connectionLost(let detail):
            return "Live connection lost: \(detail)"
        case .closed(let code, let reason):
            if let reason, !reason.isEmpty { return "OpenAI closed the Live connection: \(reason)" }
            return "OpenAI closed the Live connection (code \(code))"
        case .notConnected:
            return "Live is not connected"
        }
    }
}

extension RealtimeTransportError: LocalizedError {
    public var errorDescription: String? { message }
}

public final class RealtimeTransport: NSObject, RealtimeTransporting, URLSessionWebSocketDelegate, @unchecked Sendable {
    public static let endpoint = "wss://api.openai.com/v1/realtime"

    /// The upgrade request: the model in the query, the key as a bearer token, and no
    /// `OpenAI-Beta` header, which would select the beta interface.
    public static func makeRequest(apiKey: String, model: String) -> URLRequest {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: allowed) ?? model
        // The endpoint is a constant and the model is percent-encoded: this cannot fail.
        let url = URL(string: "\(endpoint)?model=\(encodedModel)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private let request: URLRequest
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var stream: AsyncThrowingStream<String, Error>.Continuation?
    private var closedByCaller = false

    public init(apiKey: String, model: String = RealtimeSessionConfig.defaultModel) {
        self.request = Self.makeRequest(apiKey: apiKey, model: model)
        super.init()
    }

    public func connect() async throws -> AsyncThrowingStream<String, Error> {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if closedByCaller {
                lock.unlock()
                continuation.resume(throwing: RealtimeTransportError.notConnected)
                return
            }
            self.session = session
            self.task = task
            self.openContinuation = continuation
            lock.unlock()
            task.resume()
        }

        let messages = AsyncThrowingStream<String, Error> { continuation in
            lock.lock()
            self.stream = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.close() }
        }
        receiveNext(on: task)
        return messages
    }

    public func send(text: String) async throws {
        guard let task = currentTask() else { throw RealtimeTransportError.notConnected }
        try await task.send(.string(text))
    }

    public func send(data: Data) async throws {
        guard let task = currentTask() else { throw RealtimeTransportError.notConnected }
        try await task.send(.data(data))
    }

    public func close() {
        lock.lock()
        closedByCaller = true
        let task = self.task
        let session = self.session
        let stream = self.stream
        let opening = self.openContinuation
        self.task = nil
        self.session = nil
        self.stream = nil
        self.openContinuation = nil
        lock.unlock()

        opening?.resume(throwing: RealtimeTransportError.notConnected)
        task?.cancel(with: .normalClosure, reason: nil)
        stream?.finish()
        // The session holds its delegate strongly until it is invalidated.
        session?.invalidateAndCancel()
    }

    // MARK: - Receiving

    private func currentTask() -> URLSessionWebSocketTask? {
        lock.lock()
        defer { lock.unlock() }
        return task
    }

    private func receiveNext(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                let text: String
                switch message {
                case .string(let string): text = string
                case .data(let data): text = String(decoding: data, as: UTF8.self)
                @unknown default: text = ""
                }
                self.yield(text)
                self.receiveNext(on: task)
            case .failure(let error):
                // A close frame or a task error reaches the delegate too; whichever comes
                // first ends the stream, and only once.
                self.finish(throwing: .connectionLost(error.localizedDescription), statusCode: Self.status(of: task))
            }
        }
    }

    private func yield(_ text: String) {
        lock.lock()
        let stream = self.stream
        lock.unlock()
        stream?.yield(text)
    }

    /// Ends the open handshake or the message stream with `error`, unless the caller closed.
    private func finish(throwing error: RealtimeTransportError, statusCode: Int?) {
        lock.lock()
        if closedByCaller {
            lock.unlock()
            return
        }
        let opening = openContinuation
        let stream = self.stream
        openContinuation = nil
        self.stream = nil
        lock.unlock()

        if let opening {
            let handshakeError = statusCode.map { RealtimeTransportError.handshake(statusCode: $0) } ?? error
            opening.resume(throwing: handshakeError)
        }
        stream?.finish(throwing: error)
    }

    private static func status(of task: URLSessionTask) -> Int? {
        guard let response = task.response as? HTTPURLResponse, response.statusCode != 101 else { return nil }
        return response.statusCode
    }

    // MARK: - URLSessionWebSocketDelegate

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        lock.lock()
        let opening = openContinuation
        openContinuation = nil
        lock.unlock()
        opening?.resume()
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let text = reason.map { String(decoding: $0, as: UTF8.self) }
        finish(throwing: .close(code: closeCode.rawValue, reason: text), statusCode: nil)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let detail = error?.localizedDescription ?? "the connection ended"
        finish(throwing: .connectionLost(detail), statusCode: Self.status(of: task))
    }
}
