import Foundation

@testable import Schrift

/// In-memory `WebSocketConnecting` double. `MockURLProtocol` can't fake a
/// WebSocket, so transport tests drive this instead: enqueue inbound frames,
/// inspect what was sent, and simulate the socket closing. A lock-guarded queue
/// pairs each `receiveData()` with a delivered result (buffering when a frame
/// arrives before the pump asks), so tests never sleep to synchronise.
final class FakeWebSocket: WebSocketConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Result<Data, Error>] = []
    private var waiter: CheckedContinuation<Data, Error>?

    private var _sentFrames: [Data] = []
    private var _didResume = false
    private var _pingCount = 0
    private var _cancelCloseCode: URLSessionWebSocketTask.CloseCode?
    private var _closeCode: URLSessionWebSocketTask.CloseCode = .invalid

    // MARK: WebSocketConnecting

    func resume() { lock.withLock { _didResume = true } }

    func send(_ data: Data) async throws { lock.withLock { _sentFrames.append(data) } }

    func sendPing() async throws { lock.withLock { _pingCount += 1 } }

    func receiveData() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if pending.isEmpty {
                waiter = continuation
                lock.unlock()
            } else {
                let next = pending.removeFirst()
                lock.unlock()
                continuation.resume(with: next)
            }
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.withLock {
            _cancelCloseCode = closeCode
            _closeCode = closeCode
        }
        deliver(.failure(URLError(.cancelled)))
    }

    var closeCode: URLSessionWebSocketTask.CloseCode { lock.withLock { _closeCode } }

    // MARK: test inspection

    var sentFrames: [Data] { lock.withLock { _sentFrames } }
    var didResume: Bool { lock.withLock { _didResume } }
    var pingCount: Int { lock.withLock { _pingCount } }
    var cancelCloseCode: URLSessionWebSocketTask.CloseCode? { lock.withLock { _cancelCloseCode } }

    // MARK: test controls

    /// Deliver one inbound binary frame to the pump.
    func deliver(message data: Data) { deliver(.success(data)) }

    /// Simulate the server closing with `code` (sets `closeCode`, unblocks the pump).
    func serverClose(code: URLSessionWebSocketTask.CloseCode, error: Error = URLError(.networkConnectionLost)) {
        lock.withLock { _closeCode = code }
        deliver(.failure(error))
    }

    /// Simulate a transport error with no close code (stays `.invalid`).
    func failTransport(_ error: Error = URLError(.networkConnectionLost)) { deliver(.failure(error)) }

    private func deliver(_ result: Result<Data, Error>) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(with: result)
        } else {
            pending.append(result)
            lock.unlock()
        }
    }
}
