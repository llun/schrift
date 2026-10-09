import XCTest

@testable import Schrift

/// Records every socket the manager builds, and the request used, so tests can
/// inspect handshakes and reconnects. Lock-guarded because the factory is
/// `@Sendable`.
final class ManagerSocketFactorySpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _sockets: [FakeWebSocket] = []
    private var _requests: [URLRequest] = []

    var factory: WebSocketFactory {
        { request in
            let socket = FakeWebSocket()
            self.lock.withLock {
                self._sockets.append(socket)
                self._requests.append(request)
            }
            return socket
        }
    }

    var sockets: [FakeWebSocket] { lock.withLock { _sockets } }
    var requests: [URLRequest] { lock.withLock { _requests } }
}

/// Shared manager builders, frame builders and block fixtures for the
/// `DocumentCollaborationManager…Tests` classes. Holds no tests.
@MainActor
class DocumentCollaborationManagerTestCase: XCTestCase {
    let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    let docID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    func makeManager(
        feature: Bool = true, offline: Bool = false, server: Bool = true,
        cookies: [HTTPCookie] = [], linger: Double = 0.05,
        config: ServerConfig? = nil, replicaClientID: UInt32 = 42, spy: ManagerSocketFactorySpy
    ) -> DocumentCollaborationManager {
        let manager = DocumentCollaborationManager(
            serverBaseURL: baseURL,
            cookieProvider: { cookies },
            featureEnabled: { feature },
            isOffline: { offline },
            serverConfigProvider: { config },
            socketFactory: spy.factory,
            lingerSeconds: linger,
            replicaClientIDProvider: { replicaClientID })
        manager.serverSupportsLiveCollaboration = server
        return manager
    }

    func makeAwarenessManager(
        provider: @escaping @Sendable () async -> LocalAwarenessState?,
        spy: ManagerSocketFactorySpy,
        linger: Double = 0.05
    ) -> DocumentCollaborationManager {
        let manager = DocumentCollaborationManager(
            serverBaseURL: baseURL,
            cookieProvider: { [] },
            featureEnabled: { true },
            isOffline: { false },
            serverConfigProvider: { nil },
            localStateProvider: provider,
            socketFactory: spy.factory,
            lingerSeconds: linger)
        manager.serverSupportsLiveCollaboration = true
        return manager
    }

    func syncFrame() -> Data {
        let payload = SyncMessage(step: .update, data: Data([0x00])).encodedPayload()
        return HocuspocusMessage(documentName: docID.uuidString.lowercased(), type: .sync, payload: payload).encoded()
    }

    /// A `.sync`/`.update` frame wrapping real (or malformed) update bytes — the
    /// same wire shape `syncFrame()` above uses, but carrying payload the
    /// session's `onSyncUpdate` actually decodes, so these tests drive
    /// `applyReplicaUpdate` through the real socket → session → manager path
    /// rather than calling manager internals directly.
    func syncUpdateFrame(data: Data) -> Data {
        let payload = SyncMessage(step: .update, data: data).encodedPayload()
        return HocuspocusMessage(documentName: docID.uuidString.lowercased(), type: .sync, payload: payload).encoded()
    }

    /// A `.sync`/`.step2` frame — the reply to our own SyncStep1 handshake. It
    /// fires the session's `onInitialSync`, which is the *sole* authority for
    /// `initialSyncApplied` (Task 6's authority move): a replica is only
    /// writable/projectable/snapshottable once the room's full initial state has
    /// landed. This is the realistic first inbound content frame in every session
    /// (step1 out → step2 in), so seeding a healthy replica goes through it rather
    /// than through a bare `.update`.
    func syncStep2Frame(data: Data) -> Data {
        let payload = SyncMessage(step: .step2, data: data).encodedPayload()
        return HocuspocusMessage(documentName: docID.uuidString.lowercased(), type: .sync, payload: payload).encoded()
    }

    /// A `SyncReply`(4)/`.step2` frame — what a *real* Hocuspocus server sends in
    /// answer to our `Sync`(0)+SyncStep1 handshake (the app only ever *sends*
    /// `Sync`(0)). It must drive the identical path as `syncStep2Frame`: fire
    /// `onInitialSync`, mark the replica synced, and make it writable.
    func syncReplyStep2Frame(data: Data) -> Data {
        let payload = SyncMessage(step: .step2, data: data).encodedPayload()
        return HocuspocusMessage(documentName: docID.uuidString.lowercased(), type: .syncReply, payload: payload)
            .encoded()
    }

    /// A `.sync`/`.step1` frame carrying a peer's state vector — a peer/relay
    /// asking us for our state. The session routes it to `onStateRequest` →
    /// `stateReply`, and a non-nil reply is sent back as a `.step2` diff.
    func step1Frame(stateVector: Data) -> Data {
        let payload = SyncMessage(step: .step1, data: stateVector).encodedPayload()
        return HocuspocusMessage(documentName: docID.uuidString.lowercased(), type: .sync, payload: payload).encoded()
    }

    /// The three base props every text block carries, in BlockNote order (mirrors
    /// `BlockNoteWriteOracleTests`).
    var baseProps: [(key: String, value: YAnyValue)] {
        [
            ("backgroundColor", .string("default")), ("textColor", .string("default")),
            ("textAlignment", .string("left")),
        ]
    }

    /// A one-run paragraph with the base props (empty text ⇒ no runs).
    func para(_ text: String, id: String) -> BlockNoteBlock {
        BlockNoteBlock(node: "paragraph", props: baseProps, runs: text.isEmpty ? [] : [InlineRun(text)], id: id)
    }

    /// A BlockNote block id (a distinct namespace from the document id).
    let blockID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

    /// Seed the manager's replica from a known block list by delivering it as an
    /// inbound `.sync`/`.update` frame through the real socket → session → manager
    /// path (so the replica goes through the same `applyReplicaUpdate` the C1 tests
    /// exercise), then wait until it is writable. Returns the wire seed bytes so a
    /// second replica can be built from the same base for a convergence check.
    @discardableResult
    func seedWritableReplica(
        _ manager: DocumentCollaborationManager, socket: FakeWebSocket, blocks: [BlockNoteBlock]
    ) async -> Data {
        let seed = BlockNoteYjs.encode(blocks, clientID: 1)
        // Deliver the seed as the `.step2` sync reply so `onInitialSync` marks the
        // replica synced — a bare `.update` would build the replica but leave it
        // un-writable (Task 6's authority move).
        socket.deliver(message: syncStep2Frame(data: seed))
        await waitUntil { manager.replicaVersion(for: docID) == 1 }
        return seed
    }
}
