import Foundation

/// Owns one collaboration WebSocket for a single document: it resumes the
/// socket, pumps inbound frames into an `AsyncStream<CollaborationEvent>`,
/// decodes them, sends outbound frames, and classifies the disconnect. Higher
/// layers (the session/manager in a later PR) own reconnect, backoff, and the
/// Yjs sync/awareness logic; this actor is just the framed byte pipe.
///
/// An `actor` because the receive pump and the send/close calls race; isolation
/// serialises them and protects `didSelfClose`.
actor CollaborationTransport {
    private let socket: WebSocketConnecting
    private let wireProtocol: CollaborationWireProtocol
    private let documentName: String
    private var pumpTask: Task<Void, Never>?
    private var continuation: AsyncStream<CollaborationEvent>.Continuation?
    /// Set when *we* initiate the close, so the pump reports `.selfClosed`
    /// rather than trying to classify our own 1001 as a peer close.
    private var didSelfClose = false

    init(
        socket: WebSocketConnecting, wireProtocol: CollaborationWireProtocol = .hocuspocus,
        documentName: String = ""
    ) {
        self.socket = socket
        self.wireProtocol = wireProtocol
        self.documentName = documentName
    }

    /// Resumes the socket and returns the inbound event stream. Call once; the
    /// stream yields `.message` per decoded frame and a final `.disconnected`
    /// before finishing.
    func start() -> AsyncStream<CollaborationEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: CollaborationEvent.self)
        self.continuation = continuation
        socket.resume()
        pumpTask = Task { [weak self] in
            await self?.pump()
        }
        return stream
    }

    /// Sends one logical frame with the selected wire framing.
    func send(_ message: HocuspocusMessage) async throws {
        try await socket.send(wireProtocol.encode(message))
    }

    /// Sends a keep-alive ping.
    func ping() async throws {
        try await socket.sendPing()
    }

    /// Closes the socket ourselves with 1001, so the disconnect is reported as
    /// `.selfClosed` (never misread as a server permission reset).
    func close() {
        didSelfClose = true
        socket.cancel(with: .goingAway, reason: nil)
    }

    private func pump() async {
        while true {
            do {
                let data = try await socket.receiveData()
                // Tolerate an undecodable / unknown frame rather than tearing the
                // stream down — the protocol rule is to ignore what we don't model.
                if let message = try? wireProtocol.decode(data, documentName: documentName) {
                    continuation?.yield(.message(message))
                }
            } catch {
                let reason =
                    didSelfClose ? .selfClosed : CollaborationDisconnect.classify(closeCode: socket.closeCode)
                continuation?.yield(.disconnected(reason))
                continuation?.finish()
                return
            }
        }
    }
}
