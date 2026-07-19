import Foundation

/// The live-collaboration session for one document.
///
/// **Pure transport/state machine — the manager owns the replica (C2a).** This
/// class never decodes or applies a CRDT itself; it carries the real Yjs sync
/// protocol over the wire and hands the manager everything it needs to do so.
/// It joins the Hocuspocus room, sends SyncStep1 with the state vector the
/// manager supplies (`initialSyncStep1` — the real replica's state once one
/// exists, else the signal-only one-byte empty vector), answers a peer's own
/// SyncStep1 with a SyncStep2 diff the manager computes (`onStateRequest`), and
/// signals initial sync completion (`onInitialSync`) on the first inbound
/// SyncStep2. Inbound sync bytes (`.step2`/`.update`) are handed to the manager
/// via `onSyncUpdate`, and `broadcast(update:)` sends the manager's own local
/// edits (encoded upstream by B6) out to the room. `onRemoteChange` also still
/// fires on every inbound sync frame, as a change-signal fallback independent of
/// whether the replica integrates it. **Presence is real:** it broadcasts our
/// `{name, color}` awareness and tracks peers' awareness into `peers`.
/// Disconnects are classified into terminal vs. reconnect-eligible states so the
/// manager can decide whether to retry.
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
    /// Fired on the main actor with the raw Yjs update bytes (`SyncMessage.data`)
    /// for an inbound `.step2`/`.update` sync frame. A peer's `.step1` (a
    /// request for our state) carries no content of its own and is routed to
    /// `onStateRequest` instead.
    private let onSyncUpdate: @MainActor (Data) -> Void
    /// Produces the state vector for the initial SyncStep1 handshake. Defaults
    /// to the signal-only empty state vector (`Data([0x00])`), so a caller with
    /// no replica wired keeps today's behavior; C2 passes the real replica's
    /// state vector instead so the peer's step2 reply is an actual diff.
    private let initialSyncStep1: @MainActor () -> Data
    /// Called on the main actor with a peer's step1 state-vector payload
    /// (`SyncMessage.data`) when they request our state. A non-nil return is
    /// sent back as a `.sync` `.step2` frame carrying the diff; `nil` (the
    /// default — no replica wired) sends nothing, matching today's read-only
    /// behavior.
    private let onStateRequest: @MainActor (Data) -> Data?
    /// Fired on the main actor exactly once, on the first inbound `.step2`
    /// frame — the reply to our own SyncStep1, i.e. the peer has sent us
    /// everything we were missing. Runs *after* `onSyncUpdate` has delivered
    /// that frame's bytes, so the manager can integrate them before marking
    /// the initial sync applied.
    private let onInitialSync: @MainActor () -> Void
    /// Latches `onInitialSync` to a single firing per session.
    private var didInitialSync = false
    private var pumpTask: Task<Void, Never>?

    init(
        documentName: String,
        transport: CollaborationTransport,
        clientID: UInt = UInt(UInt32.random(in: 1..<UInt32.max)),
        localState: LocalAwarenessState? = nil,
        onRemoteChange: @escaping @MainActor () -> Void = {},
        onSyncUpdate: @escaping @MainActor (Data) -> Void = { _ in },
        initialSyncStep1: @escaping @MainActor () -> Data = { Data([0x00]) },
        onStateRequest: @escaping @MainActor (Data) -> Data? = { _ in nil },
        onInitialSync: @escaping @MainActor () -> Void = {}
    ) {
        self.documentName = documentName
        self.transport = transport
        self.clientID = clientID
        self.localState = localState
        self.onRemoteChange = onRemoteChange
        self.onSyncUpdate = onSyncUpdate
        self.initialSyncStep1 = initialSyncStep1
        self.onStateRequest = onStateRequest
        self.onInitialSync = onInitialSync
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
        let initialSyncStep1 = self.initialSyncStep1
        pumpTask = Task { [weak self] in
            let events = await transport.start()
            // SyncStep1 with our state vector (the signal-only default is the
            // one-byte empty vector, `Data([0x00])`, so the peer replies with
            // its full update — which we treat as a change signal until a real
            // replica is wired in via `initialSyncStep1`).
            let payload = SyncMessage(step: .step1, data: initialSyncStep1()).encodedPayload()
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

    /// Broadcasts a local Yjs update to the room as an unsolicited `.sync`
    /// `.update` frame (the write side of C2: our own edits, encoded upstream
    /// into `update`, reach the other peers). A send failure is tolerated the
    /// same way the handshake's is — the pump's disconnect event reclassifies
    /// the state, so there is nothing more to do here.
    func broadcast(update: Data) async {
        let payload = SyncMessage(step: .update, data: update).encodedPayload()
        let frame = HocuspocusMessage(documentName: documentName, type: .sync, payload: payload)
        try? await transport.send(frame)
    }

    /// Best-effort transition to `.live` after the handshake is sent: there is no
    /// distinct socket-open event, and a real failure surfaces as the pump's
    /// disconnect.
    private func markLiveIfConnecting() {
        if state == .connecting || state == .reconnecting { state = .live }
    }

    /// Replies to a peer's `.step1` state-vector request with a `.step2` diff.
    /// `handle` is synchronous (called inline from the event pump loop), so —
    /// like `stop()` — the actual send is an unstructured `Task`; a failure is
    /// tolerated the same way every other send here is, via the pump's
    /// disconnect event.
    private func sendStep2(_ data: Data) {
        let payload = SyncMessage(step: .step2, data: data).encodedPayload()
        let frame = HocuspocusMessage(documentName: documentName, type: .sync, payload: payload)
        let transport = self.transport
        Task { try? await transport.send(frame) }
    }

    private func handle(_ event: CollaborationEvent) {
        switch event {
        case .message(let message):
            guard message.documentName == documentName else { return }
            switch message.knownType {
            case .sync, .syncReply:
                // A `Sync`(0) frame (a peer's own edit / SyncStep1) or a
                // `SyncReply`(4) frame (a real Hocuspocus server's answer to our
                // Sync+SyncStep1 handshake, carrying the initial document). Both
                // wrap a y-sync payload whose *subtype* — step1/step2/update —
                // decides the behavior, so they are handled identically on receive
                // (y-provider 3.4.4 does the same). We only ever *send* `Sync`(0);
                // `SyncReply` is server-originated.
                // A peer touched the document — a change signal (not applied here).
                if state == .connecting || state == .reconnecting { state = .live }
                onRemoteChange()
                // A malformed payload is tolerated (onRemoteChange already fired,
                // so the fallback refresh still happens).
                guard let sync = try? SyncMessage(decodingPayload: message.payload) else { return }
                switch sync.step {
                case .step1:
                    // A peer requesting our state; reply with a diff only if the
                    // caller can produce one (a replica is wired in) — nil keeps
                    // today's read-only behavior of sending nothing back.
                    if let reply = onStateRequest(sync.data) {
                        sendStep2(reply)
                    }
                case .step2:
                    // Deliver the bytes first so the manager integrates them, THEN
                    // signal "initial sync applied" — never the other order.
                    onSyncUpdate(sync.data)
                    if !didInitialSync {
                        didInitialSync = true
                        onInitialSync()
                    }
                case .update:
                    onSyncUpdate(sync.data)
                }
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
