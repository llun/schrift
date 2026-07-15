import Foundation

/// The live-collaboration session for one document.
///
/// **Signal-only for content in this milestone.** It joins the Hocuspocus room,
/// performs the empty-state-vector handshake (send SyncStep1 with a one-byte
/// empty state vector, so the peer replies with everything), and reports that a
/// peer touched the document — it does **not** apply a CRDT (that is Milestone
/// B/C); the change signal is what a later PR turns into a refresh. **Presence is
/// real:** it broadcasts our `{name, color}` awareness and tracks peers'
/// awareness into `peers`. Disconnects are classified into terminal vs.
/// reconnect-eligible states so the manager can decide whether to retry.
///
/// `@MainActor @Observable` like every view-adjacent store: a screen observes
/// `state`/`peers`, and `onRemoteChange` is delivered on the main actor.
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

    /// Other collaborators currently in the room, from their awareness state.
    /// Observed by the presence UI; never includes us (`clientID`).
    private(set) var peers: [CollaborationPeer] = []

    /// The room UUID (lowercase v4), which is also the Hocuspocus `documentName`.
    private let documentName: String
    private let transport: CollaborationTransport
    /// A fresh random client id for this session — never persisted (reuse risks
    /// duplicate ids = silent corruption), 32-bit to match yjs's clientID range.
    private let clientID: UInt
    /// Our awareness state (`{name, color}`) broadcast to peers, or nil to join
    /// as an observer without announcing presence.
    private let localState: LocalAwarenessState?
    /// Fired on the main actor when a peer's change signal (a sync update)
    /// arrives. Signal-only: the payload is not applied, only noted.
    private let onRemoteChange: @MainActor () -> Void
    private var pumpTask: Task<Void, Never>?

    init(
        documentName: String,
        transport: CollaborationTransport,
        clientID: UInt = UInt(UInt32.random(in: 1..<UInt32.max)),
        localState: LocalAwarenessState? = nil,
        onRemoteChange: @escaping @MainActor () -> Void = {}
    ) {
        self.documentName = documentName
        self.transport = transport
        self.clientID = clientID
        self.localState = localState
        self.onRemoteChange = onRemoteChange
    }

    /// Resumes the socket, sends the handshake, and pumps inbound events.
    /// Idempotent. Always end with `stop()` — the manager owns the lifecycle and
    /// the pump only unwinds once the transport disconnects.
    func start() {
        guard pumpTask == nil else { return }
        let transport = self.transport
        let documentName = self.documentName
        let clientID = self.clientID
        let localState = self.localState
        pumpTask = Task { [weak self] in
            let events = await transport.start()
            // SyncStep1 with an empty state vector (`Data([0x00])`): the peer
            // replies with the full update, which we treat as a change signal.
            let payload = SyncMessage(step: .step1, data: Data([0x00])).encodedPayload()
            let frame = HocuspocusMessage(documentName: documentName, type: .sync, payload: payload)
            // A send failure means the socket is already broken; the pump's
            // disconnect event reclassifies the state, so ignore it here.
            try? await transport.send(frame)
            // Announce our presence, so peers show our avatar.
            if let localState {
                let awareness = AwarenessCodec.encodePayload([
                    AwarenessEntry(clientID: clientID, clock: 1, stateJSON: localState.json())
                ])
                try? await transport.send(
                    HocuspocusMessage(documentName: documentName, type: .awareness, payload: awareness))
            }
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
            guard message.documentName == documentName else { return }
            switch message.knownType {
            case .sync:
                // A peer touched the document — a change signal (not applied here).
                if state == .connecting || state == .reconnecting { state = .live }
                onRemoteChange()
            case .awareness:
                // Peers' presence: fold it into `peers` (never including us).
                if let entries = try? AwarenessCodec.decodePayload(message.payload) {
                    peers = updatedPeers(peers, applying: entries, excludingLocalClientID: clientID)
                }
            default:
                return  // unknown / other types are tolerated
            }
        case .disconnected(let reason):
            // The socket is gone, so our knowledge of who is present is stale —
            // drop it. On reconnect the manager builds a fresh session that
            // repopulates `peers` from the new room's awareness.
            peers = []
            switch reason {
            case .permissionsReset: state = .ended(.permissionsReset)
            case .selfClosed: state = .ended(.closed)
            case .transient: state = .reconnecting
            }
        }
    }
}
