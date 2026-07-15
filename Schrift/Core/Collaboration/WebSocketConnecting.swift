import Foundation

// MARK: - Transport seam

/// A minimal seam over `URLSessionWebSocketTask`. `MockURLProtocol` cannot fake a
/// WebSocket (URLSession never routes a `wss` upgrade through a custom protocol),
/// so the transport talks to this protocol instead and tests inject a
/// `FakeWebSocket`. All methods are the subset `CollaborationTransport` needs.
///
/// Conformers are reference types shared across the transport actor's isolation,
/// hence `Sendable`; the two concrete ones (`URLSessionWebSocket`, `FakeWebSocket`)
/// are each internally thread-safe.
protocol WebSocketConnecting: Sendable {
    /// Begins the connection (the handshake happens lazily on first traffic).
    func resume()
    /// Sends one binary message (a whole Hocuspocus frame).
    func send(_ data: Data) async throws
    /// Awaits the next inbound binary message; throws when the socket closes or
    /// errors. Non-binary (text) frames are a protocol violation and throw.
    func receiveData() async throws -> Data
    /// A keep-alive ping. The cadence is owned by the session layer.
    func sendPing() async throws
    /// Closes the socket with an explicit code (the transport self-closes with
    /// `.goingAway` = 1001 so a self-close is never read as a server reset).
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    /// The close code observed after the socket ends (`.invalid` until then).
    var closeCode: URLSessionWebSocketTask.CloseCode { get }
}

/// A binary frame was expected but the server sent a text frame — a Hocuspocus
/// protocol violation (all its framing is binary).
enum WebSocketProtocolError: Error, Equatable {
    case unexpectedTextFrame
}

/// Extracts the binary payload from a received message, rejecting text frames.
/// A free function so the `.data`/`.string` decision is unit-testable without a
/// live socket.
func webSocketData(from message: URLSessionWebSocketTask.Message) throws -> Data {
    switch message {
    case .data(let data): return data
    case .string: throw WebSocketProtocolError.unexpectedTextFrame
    @unknown default: throw WebSocketProtocolError.unexpectedTextFrame
    }
}

// MARK: - URLSession adapter

/// Production `WebSocketConnecting` backed by a `URLSessionWebSocketTask`.
/// `URLSessionWebSocketTask` is internally thread-safe, so this thin wrapper is
/// `@unchecked Sendable`. Not unit-tested (it needs a live server — see the
/// on-device probe in the roadmap); the transport's logic is tested via
/// `FakeWebSocket`.
final class URLSessionWebSocket: WebSocketConnecting, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func resume() { task.resume() }

    func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    func receiveData() async throws -> Data {
        try webSocketData(from: try await task.receive())
    }

    func sendPing() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        task.cancel(with: closeCode, reason: reason)
    }

    var closeCode: URLSessionWebSocketTask.CloseCode { task.closeCode }

    /// A `WebSocketFactory` backed by a real `URLSession` — the production way the
    /// manager opens sockets. Tests inject a factory that returns a `FakeWebSocket`.
    static func factory(session: URLSession = .shared) -> WebSocketFactory {
        { request in URLSessionWebSocket(task: session.webSocketTask(with: request)) }
    }
}

/// Builds a `WebSocketConnecting` for an upgrade request. Injected into the
/// manager so tests can substitute a `FakeWebSocket`.
typealias WebSocketFactory = @Sendable (URLRequest) -> WebSocketConnecting
