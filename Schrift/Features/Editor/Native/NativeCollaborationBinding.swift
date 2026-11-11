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
///   it builds on, the binding sends a fresh SyncStep1 once the in-flight ones
///   are answered, and the server's step2 brings what was skipped.
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

    nonisolated let outbox = Outbox()
    private let replica: DocumentReplicaSession
    private(set) var session: DocumentCollaborationSession?
    private var inFlight = 0
    private var synced = false
    private var needsSync = false
    private(set) var isStopped = false
    private var consumer: Task<Void, Never>?

    init(replica: DocumentReplicaSession) {
        self.replica = replica
        consumer = Task { [weak self, outbox] in
            for await message in outbox.messages { await self?.session?.send(message) }
        }
    }

    /// A socket is open or opening.
    var isConnected: Bool {
        switch session?.state {
        case .connecting?, .live?: true
        case .reconnecting?, .ended?, nil: false
        }
    }

    /// Joins the room over `transport` unless a socket is already up. The
    /// handshake offers the replica's state vector; the server's own SyncStep1
    /// is answered with everything it lacks, unsent outbox edits included.
    func connect(transport: CollaborationTransport, wireProtocol: CollaborationWireProtocol, documentName: String) {
        guard !isStopped, !isConnected else { return }
        session?.stop()
        synced = false
        needsSync = false
        let replica = self.replica
        let outbox = self.outbox
        let session = DocumentCollaborationSession(
            documentName: documentName, transport: transport, wireProtocol: wireProtocol, canUpdate: true,
            onSyncUpdate: { [weak self] in self?.receive($0) },
            initialSyncStep1: { await Self.stateVector(of: replica) },
            onStateRequest: { vector in
                // Answered in mailbox order, into the stream journaled updates use.
                replica.mailbox.post(
                    .liveSync(peerVector: vector, reply: { _, missing in missing.map(outbox.reply) }))
                return nil
            },
            onInitialSync: { [weak self] in self?.synced = true })
        self.session = session
        session.start()
    }

    /// Closes the socket for good (the replica closed or the open went away).
    func stop() {
        isStopped = true
        session?.stop()
        session = nil
        outbox.finish()
    }

    private func receive(_ update: Data) {
        guard inFlight < Self.inboundBound else {
            // Skipped: the next SyncStep1 asks the server for it again.
            needsSync = true
            return
        }
        inFlight += 1
        replica.mailbox.post(
            .integrate(
                update,
                reply: { result in
                    Task { @MainActor [weak self] in self?.integrated(result) }
                }))
    }

    private func integrated(_ result: Result<Void, any Error>) {
        inFlight -= 1
        if case .failure(let error) = result {
            switch error {
            case NativeLiveError.missingDependencies:
                // Before the first step2 that reply brings it anyway.
                if synced { needsSync = true }
            case DocumentEngineError.detached:
                // A full mailbox dropped it (or the replica closed, and stop follows).
                needsSync = true
            default:
                // A malformed frame, a frozen replica or a failed append: live
                // ends here and HTTP keeps saving what is journaled.
                stop()
                return
            }
        }
        guard inFlight == 0, needsSync, let session else { return }
        needsSync = false
        let replica = self.replica
        Task { await session.send(SyncMessage(step: .step1, data: await Self.stateVector(of: replica))) }
    }

    private static func stateVector(of replica: DocumentReplicaSession) async -> Data {
        await withCheckedContinuation { done in
            // A post that cannot be handled is answered with the empty vector.
            replica.mailbox.post(.liveSync(peerVector: nil, reply: { vector, _ in done.resume(returning: vector) }))
        }
    }

    isolated deinit {
        consumer?.cancel()
        session?.stop()
    }
}
