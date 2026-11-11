import Foundation

enum NativeLiveError: Error, Equatable {
    /// An inbound update builds on structs the replica lacks; nothing was
    /// written (`DocumentReplicaSession`'s integrate refuses it untouched).
    case missingDependencies
}

/// PR09: native live content runs only when the native editor switch, the
/// Live collaboration preference, the server's Docs 6 collaboration socket and
/// the document's `abilities.update` all hold. It never reads
/// `ServerConfig.yWebSocketLiveCollaborationEnabled`, the current editor's
/// release capability (A5).
func nativeLiveCollaborationEligible(
    nativeEnabled: Bool, liveEnabled: Bool, serverSupports: Bool, canUpdate: Bool
) -> Bool {
    nativeEnabled && liveEnabled && serverSupports && canUpdate
}

/// One live socket for one native replica scope (PR09a), owned by
/// `NativeSessionRegistry` beside the scope's journal and save scheduler.
///
/// - **Inbound** sync bytes go into the replica through the mailbox
///   (`.integrate`), journaled before any surface shows them. At most
///   `inboundBound` wait there, so a burst from the socket never fills the
///   mailbox a keystroke needs; past it, and after an update that overtook what
///   it builds on, the binding redials once the in-flight ones are answered,
///   and the fresh handshake's step2 brings what was skipped. A step2 the
///   replica refuses stops live instead (every handshake would repeat it).
/// - **Outbound** is only what the replica journaled: the scope's journal
///   publishes each local update into `outbox` after its append succeeded, and
///   a peer's SyncStep1 is answered by the replica in mailbox order into the
///   same stream, so every frame leaves in journal order, once. HTTP saving
///   keeps sending the same outbox; the server takes both idempotently.
/// - A disconnect ends the socket; HTTP keeps saving. Reconnect, background
///   and permission refetch are PR09b.
@MainActor
final class NativeCollaborationBinding {
    /// Frames in the order the replica produced them. Unbounded but always
    /// drained: without a socket they are dropped (the replica and the HTTP
    /// outbox still hold them; the next handshake offers them again).
    final class Outbox: Sendable {
        let messages: AsyncStream<SyncMessage>
        private let continuation: AsyncStream<SyncMessage>.Continuation

        init() { (messages, continuation) = AsyncStream.makeStream() }

        /// Called by the journal, on the replica session, after the append.
        func publish(_ update: Data) { continuation.yield(SyncMessage(step: .update, data: update)) }

        func reply(_ missing: Data) { continuation.yield(SyncMessage(step: .step2, data: missing)) }

        func finish() { continuation.finish() }
    }

    static let inboundBound = 64
    /// Recovery redials in a row; past it a peer that keeps sending frames the
    /// replica must refuse cannot make it reconnect forever. A socket whose
    /// step2 integrates starts the count again, so separate stalls in one open
    /// each get their own.
    static let redialLimit = 3

    /// How to reach the room again: a redial is a fresh handshake.
    private struct Dialer {
        let dial: @MainActor () -> CollaborationTransport?
        let wireProtocol: CollaborationWireProtocol
        let documentName: String
        /// The open and its account still hold: nothing is dialed or sent otherwise.
        let isCurrent: @MainActor () -> Bool
    }

    nonisolated let outbox = Outbox()
    private let replica: DocumentReplicaSession
    private(set) var session: DocumentCollaborationSession?
    private var dialer: Dialer?
    private var dialing = false
    /// Bumped per socket: answers for an older socket's frames ask nothing.
    private var generation = 0
    private var inFlight = 0
    /// This socket's step2 arrived: an update refused after it is a real gap.
    private var synced = false
    private var needsRedial = false
    private var redials = 0
    /// A peer's SyncStep1 being answered, and the latest one that came in
    /// meanwhile: at most one waits in the mailbox, so a burst cannot fill it.
    private var answering = false
    private var nextStateRequest: Data?
    private(set) var isStopped = false
    private var consumer: Task<Void, Never>?

    init(replica: DocumentReplicaSession) {
        self.replica = replica
        consumer = Task { [weak self, outbox] in
            for await message in outbox.messages {
                // Rechecked per frame: an account change stops content leaving
                // even before the binding itself is stopped.
                guard let self, self.dialer?.isCurrent() == true else { continue }
                await self.session?.send(message)
            }
        }
    }

    /// A socket is open, opening or being dialed.
    var isConnected: Bool {
        if dialing { return true }
        switch session?.state {
        case .connecting?, .live?: return true
        case .reconnecting?, .ended?, nil: return false
        }
    }

    /// Joins the room unless a socket is already up. The handshake offers the
    /// replica's state vector, read before dialing; the server's own
    /// SyncStep1 is answered with everything it lacks, unsent outbox edits
    /// included.
    func connect(
        dial: @escaping @MainActor () -> CollaborationTransport?, wireProtocol: CollaborationWireProtocol,
        documentName: String, isCurrent: @escaping @MainActor () -> Bool
    ) {
        dialer = Dialer(dial: dial, wireProtocol: wireProtocol, documentName: documentName, isCurrent: isCurrent)
        open()
    }

    /// Closes the socket for good (the replica closed or the open went away).
    func stop() {
        isStopped = true
        session?.stop()
        session = nil
        outbox.finish()
    }

    private func open() {
        guard !isStopped, !isConnected, let dialer else { return }
        dialing = true
        Task { [weak self, replica] in
            // A full mailbox answers nil: no handshake, rather than one asking
            // for the whole document.
            let vector = await Self.stateVector(of: replica)
            guard let self else { return }
            self.dialing = false
            guard let vector, !self.isStopped, dialer.isCurrent(), let transport = dialer.dial() else { return }
            self.start(transport: transport, dialer: dialer, stateVector: vector)
        }
    }

    private func start(transport: CollaborationTransport, dialer: Dialer, stateVector: Data) {
        generation += 1
        needsRedial = false
        synced = false
        let generation = self.generation
        let session = DocumentCollaborationSession(
            documentName: dialer.documentName, transport: transport, wireProtocol: dialer.wireProtocol,
            canUpdate: true, initialSyncStep1: { stateVector },
            onStateRequest: { [weak self] vector in
                self?.answer(vector)
                return nil
            },
            onSync: { [weak self] in self?.receive($0, generation: generation) })
        self.session = session
        session.start()
    }

    /// A refused frame is recovered by a fresh handshake, whose step2 is the
    /// server's whole diff: that works whether or not the server answers a
    /// SyncStep1 later in a session.
    private func redial() {
        guard redials < Self.redialLimit else { return stop() }
        redials += 1
        needsRedial = false
        // Answers still due from the old socket's frames ask nothing more.
        generation += 1
        session?.stop()
        session = nil
        open()
    }

    /// Answered in mailbox order, into the stream journaled updates use. A
    /// later request supersedes one not yet posted (its vector is newer).
    private func answer(_ vector: Data) {
        guard !answering else {
            nextStateRequest = vector
            return
        }
        answering = true
        let outbox = self.outbox
        replica.mailbox.post(
            .liveSync(
                peerVector: vector,
                reply: { _, missing in
                    missing.map(outbox.reply)
                    Task { @MainActor [weak self] in self?.answered() }
                }))
    }

    private func answered() {
        answering = false
        if let next = nextStateRequest {
            nextStateRequest = nil
            answer(next)
        }
    }

    private func receive(_ sync: SyncMessage, generation: Int) {
        let step2 = sync.step == .step2
        // An update ahead of the handshake's step2 is in that step2.
        let early = !step2 && !synced
        if step2 { synced = true }
        guard inFlight < Self.inboundBound else {
            // Skipped: the next handshake brings it again.
            if generation == self.generation { needsRedial = true }
            return
        }
        inFlight += 1
        replica.mailbox.post(
            .integrate(
                sync.data,
                reply: { result in
                    Task { @MainActor [weak self] in
                        self?.integrated(result, step2: step2, early: early, generation: generation)
                    }
                }))
    }

    private func integrated(_ result: Result<Void, any Error>, step2: Bool, early: Bool, generation: Int) {
        inFlight -= 1
        if case .success = result, step2, generation == self.generation { redials = 0 }
        if case .failure(let error) = result, generation == self.generation {
            switch error {
            case NativeLiveError.missingDependencies where !step2:
                // An update that overtook what it builds on: the next
                // handshake's step2 has both.
                if !early { needsRedial = true }
            case DocumentEngineError.detached:
                // A full mailbox dropped it (or the replica closed, and stop follows).
                needsRedial = true
            default:
                // A step2 the replica cannot take would be sent again by every
                // handshake; a malformed frame, a frozen replica or a failed
                // append end live too. HTTP keeps saving what is journaled.
                return stop()
            }
        }
        guard inFlight == 0, needsRedial, !isStopped else { return }
        redial()
    }

    private static func stateVector(of replica: DocumentReplicaSession) async -> Data? {
        await withCheckedContinuation { done in
            replica.mailbox.post(.liveSync(peerVector: nil, reply: { vector, _ in done.resume(returning: vector) }))
        }
    }

    isolated deinit {
        consumer?.cancel()
        session?.stop()
    }
}
