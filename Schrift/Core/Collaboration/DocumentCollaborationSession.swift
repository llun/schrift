import Foundation

/// The live-collaboration session for one document.
///
/// **Signal-only in this milestone.** It joins the Hocuspocus room, performs the
/// empty-state-vector handshake (send SyncStep1 with a one-byte empty state
/// vector, so the peer replies with everything), and reports that a peer touched
/// the document — it does **not** apply a CRDT (that is Milestone B/C). A change
/// signal is what a later PR turns into a refresh; presence (awareness) is a
/// later PR too. Disconnects are classified into terminal vs. reconnect-eligible
/// states so the manager can decide whether to retry.
///
/// `@MainActor @Observable` like every view-adjacent store: a screen observes
/// `state`, and `onRemoteChange` is delivered on the main actor.
@MainActor
@Observable
final class DocumentCollaborationSession {
    enum State: Equatable, Sendable {
        /// The socket is being established and the handshake sent.
        case connecting
        /// Handshake sent; the session is live and listening for peer signals.
        case live
        /// A transient disconnect; the manager may reconnect (a fresh session).
        case reconnecting
        /// Terminal — the session ended and this instance will not reconnect.
        case ended(EndReason)
    }

    enum EndReason: Equatable, Sendable {
        /// Server closed with 1000 (a permission reset): refetch doc + abilities.
        case permissionsReset
        /// We closed the socket ourselves (suspend / teardown).
        case closed
    }

    private(set) var state: State = .connecting

    /// The room UUID (lowercase v4), which is also the Hocuspocus `documentName`.
    private let documentName: String
    private let transport: CollaborationTransport
    /// Fired on the main actor when a peer's change signal (a sync update)
    /// arrives. Signal-only: the payload is not applied, only noted.
    private let onRemoteChange: @MainActor () -> Void
    private var pumpTask: Task<Void, Never>?

    init(
        documentName: String,
        transport: CollaborationTransport,
        onRemoteChange: @escaping @MainActor () -> Void = {}
    ) {
        self.documentName = documentName
        self.transport = transport
        self.onRemoteChange = onRemoteChange
    }

    /// Resumes the socket, sends the handshake, and pumps inbound events.
    /// Idempotent. Always end with `stop()` — the manager owns the lifecycle and
    /// the pump only unwinds once the transport disconnects.
    func start() {
        guard pumpTask == nil else { return }
        let transport = self.transport
        let documentName = self.documentName
        pumpTask = Task { [weak self] in
            let events = await transport.start()
            // SyncStep1 with an empty state vector (`Data([0x00])`): the peer
            // replies with the full update, which we treat as a change signal.
            let payload = SyncMessage(step: .step1, data: Data([0x00])).encodedPayload()
            let frame = HocuspocusMessage(documentName: documentName, type: .sync, payload: payload)
            // A send failure means the socket is already broken; the pump's
            // disconnect event reclassifies the state, so ignore it here.
            try? await transport.send(frame)
            self?.markLiveIfConnecting()
            // Weak per iteration so a session dropped without stop() does not keep
            // itself alive; the loop unwinds on the next event or the disconnect.
            for await event in events {
                guard let self else { break }
                self.handle(event)
            }
        }
    }

    /// Closes the socket ourselves (1001). The pump then observes `.selfClosed`
    /// and settles into `.ended(.closed)`, which unwinds the pump.
    func stop() {
        let transport = self.transport
        Task { await transport.close() }
    }

    /// Best-effort transition to `.live` after the handshake is sent: there is no
    /// distinct socket-open event, and a real failure surfaces as the pump's
    /// disconnect.
    private func markLiveIfConnecting() {
        if state == .connecting || state == .reconnecting { state = .live }
    }

    private func handle(_ event: CollaborationEvent) {
        switch event {
        case .message(let message):
            // Frames for another room, or awareness/presence (a later PR), are
            // ignored here; only a sync update is a document-change signal.
            guard message.documentName == documentName, message.knownType == .sync else { return }
            if state == .connecting || state == .reconnecting { state = .live }
            onRemoteChange()
        case .disconnected(let reason):
            switch reason {
            case .permissionsReset: state = .ended(.permissionsReset)
            case .selfClosed: state = .ended(.closed)
            case .transient: state = .reconnecting
            }
        }
    }
}
