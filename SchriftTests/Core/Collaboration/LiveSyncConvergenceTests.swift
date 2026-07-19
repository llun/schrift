import XCTest

@testable import Schrift

/// Records every socket a manager builds, so a peer's handshake/broadcast frames
/// can be captured and relayed. A minimal, file-scoped copy of
/// `DocumentCollaborationManagerTests`' own spy (top-level `private` is
/// file-scoped in Swift, so it isn't reachable across files) — each peer opens
/// exactly one document's socket here.
private final class SocketFactorySpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _sockets: [FakeWebSocket] = []

    var factory: WebSocketFactory {
        { _ in
            let socket = FakeWebSocket()
            self.lock.withLock { self._sockets.append(socket) }
            return socket
        }
    }

    var sockets: [FakeWebSocket] { lock.withLock { _sockets } }
}

/// A bidirectional frame relay between two peers' sockets: every frame one peer
/// *sends* is delivered into the other peer's *inbound*, and vice-versa — the
/// paired-fake-socket wiring that makes A and B a real end-to-end pair instead
/// of two isolated fakes.
///
/// A forwarded-frame index per direction means each captured frame is relayed
/// exactly once, so `pump()` is idempotent (re-pumping forwards only what is
/// new). `settle(until:)` pumps repeatedly, yielding between rounds, until a
/// convergence predicate holds — the deterministic driver for the async settle:
/// each delivered frame is processed on the receiver's own transport-pump Task
/// and may itself produce a reply (a `SyncStep2`), which the next pump forwards.
/// This mirrors `waitUntil`'s poll-and-yield (never `Thread.sleep`) and, like
/// it, fails the test on timeout.
@MainActor
private final class PeerRelay {
    private let a: FakeWebSocket
    private let b: FakeWebSocket
    private var forwardedFromA = 0
    private var forwardedFromB = 0

    init(a: FakeWebSocket, b: FakeWebSocket) {
        self.a = a
        self.b = b
    }

    /// Ignore every frame already sent by either peer — used when the relay is
    /// only meant to carry frames that come *after* it is installed (the
    /// concurrent-edit test seeds both peers directly and does not want their
    /// pre-existing handshake step1 frames replayed).
    func skipExisting() {
        forwardedFromA = a.sentFrames.count
        forwardedFromB = b.sentFrames.count
    }

    /// Forward every not-yet-forwarded frame in both directions (A→B first, then
    /// B→A). Idempotent: only frames past each direction's index are delivered.
    func pump() {
        let aFrames = a.sentFrames
        while forwardedFromA < aFrames.count {
            b.deliver(message: aFrames[forwardedFromA])
            forwardedFromA += 1
        }
        let bFrames = b.sentFrames
        while forwardedFromB < bFrames.count {
            a.deliver(message: bFrames[forwardedFromB])
            forwardedFromB += 1
        }
    }

    /// Pump both directions, yield, and repeat until `condition` holds. Fails the
    /// test on timeout, like `waitUntil`.
    func settle(
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line,
        until condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            pump()
            if condition() { return }
            if Date() >= deadline { break }
            try? await Task.sleep(for: .milliseconds(15))
        }
        pump()
        if !condition() {
            XCTFail("relay settle timed out after \(timeout)s", file: file, line: line)
        }
    }
}

/// Two-peer live-sync convergence, end to end (C2a). Two independent
/// `DocumentCollaborationManager`s — each with its own `FakeWebSocket` — for the
/// **same** document id, wired by a `PeerRelay` that pumps each peer's sent
/// frames into the other's inbound. This exercises the whole C2a stack the unit
/// tests cover piecemeal (the session handshake `initialSyncStep1`/
/// `onStateRequest`/`onInitialSync`/`broadcast`, and the manager's
/// `applyReplicaUpdate`/`currentStateVector`/`stateReply`/`applyLocalEdit`) as
/// one real exchange, and asserts convergence at the **document level**
/// (`YBlockProjection.project` — id/node/runs), never on store bytes.
///
/// Peer A and B are given **fixed, distinct replica client ids** (100 and 200,
/// neither equal to the seed's client 1) so their locally-minted structs never
/// collide — a client-id collision is silent CRDT corruption.
@MainActor
final class LiveSyncConvergenceTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "5c5c5c5c-5c5c-4c5c-8c5c-5c5c5c5c5c5c")!
    private var documentName: String { documentID.uuidString.lowercased() }

    private let aReplicaClientID: UInt32 = 100
    private let bReplicaClientID: UInt32 = 200

    // MARK: - Block builders (mirror DocumentCollaborationManagerTests)

    /// The three base props every text block carries, in BlockNote order.
    private var baseProps: [(key: String, value: YAnyValue)] {
        [
            ("backgroundColor", .string("default")), ("textColor", .string("default")),
            ("textAlignment", .string("left")),
        ]
    }

    /// A one-run paragraph with the base props (empty text ⇒ no runs).
    private func para(_ text: String, id: String) -> BlockNoteBlock {
        BlockNoteBlock(node: "paragraph", props: baseProps, runs: text.isEmpty ? [] : [InlineRun(text)], id: id)
    }

    /// A BlockNote block id (a distinct namespace from the document id).
    private let blockID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

    // MARK: - Peer harness

    private struct Peer {
        let manager: DocumentCollaborationManager
        let spy: SocketFactorySpy
        let session: DocumentCollaborationSession?
        /// The one socket this peer opened — the endpoint the relay pumps.
        var socket: FakeWebSocket { spy.sockets[0] }
    }

    private func makeManager(replicaClientID: UInt32, spy: SocketFactorySpy) -> DocumentCollaborationManager {
        let manager = DocumentCollaborationManager(
            serverBaseURL: baseURL,
            cookieProvider: { [] },
            featureEnabled: { true },
            isOffline: { false },
            serverConfigProvider: { nil },
            socketFactory: spy.factory,
            lingerSeconds: 0.05,
            replicaClientIDProvider: { replicaClientID })
        manager.serverSupportsLiveCollaboration = true
        return manager
    }

    /// Build a manager, acquire its session, and wait for the socket + its
    /// SyncStep1 handshake to land — the point from which the relay can carry a
    /// real exchange.
    private func connectPeer(replicaClientID: UInt32) async -> Peer {
        let spy = SocketFactorySpy()
        let manager = makeManager(replicaClientID: replicaClientID, spy: spy)
        let session = manager.session(for: documentID)
        XCTAssertNotNil(session, "live collaboration must be available for the harness")
        await waitUntil { spy.sockets.count == 1 && spy.sockets[0].sentFrames.count >= 1 }
        return Peer(manager: manager, spy: spy, session: session)
    }

    /// A `.sync`/`.step2` frame — an initial-sync reply landing on a peer's
    /// inbound. Delivered directly to *seed* a peer's replica (it also fires
    /// `onInitialSync`, so the replica is marked synced and becomes
    /// writable/projectable — a bare `.update` would not).
    private func step2Frame(data: Data) -> Data {
        let payload = SyncMessage(step: .step2, data: data).encodedPayload()
        return HocuspocusMessage(documentName: documentName, type: .sync, payload: payload).encoded()
    }

    private func projectedDocument(_ manager: DocumentCollaborationManager) -> ProjectedDocument? {
        manager.projectedReplica(for: documentID, interlinkingOrigin: nil)
    }

    /// Deterministic replica teardown via the manager's own API: `release`
    /// drops the last reference; `suspend` then destroys the now-idle replica
    /// (and closes the socket) synchronously — the manager owns every `YDoc`,
    /// so there is no test-owned replica to `destroy()` directly.
    private func teardown(_ peers: Peer...) {
        for peer in peers {
            peer.manager.release(documentID)
            peer.manager.suspend()
        }
    }

    // MARK: - 1. Handshake convergence

    /// A is seeded from a known initial document; B is empty. Connecting both and
    /// relaying the SyncStep1/SyncStep2 handshake both ways must converge B onto
    /// A's document — B's step1 (empty state vector) reaches A, A answers with a
    /// step2 diff of everything B lacks (its full state), and B integrates it.
    func testHandshakeConvergesEmptyPeerOntoSeededPeer() async throws {
        let peerA = await connectPeer(replicaClientID: aReplicaClientID)
        let peerB = await connectPeer(replicaClientID: bReplicaClientID)
        defer { teardown(peerA, peerB) }

        // Seed A's replica from a known initial update; B stays empty.
        let base = [para("hello", id: blockID)]
        let seed = BlockNoteYjs.encode(base, clientID: 1)
        peerA.socket.deliver(message: step2Frame(data: seed))
        await waitUntil { peerA.manager.replicaVersion(for: self.documentID) == 1 }
        XCTAssertNotNil(projectedDocument(peerA.manager), "A is synced and projectable after seeding")
        XCTAssertNil(projectedDocument(peerB.manager), "B holds no replica before the handshake")

        // Relay the handshake both ways until B has converged.
        let relay = PeerRelay(a: peerA.socket, b: peerB.socket)
        await relay.settle { self.projectedDocument(peerB.manager) != nil }

        // Both peers project to the SAME document (id/node/runs — document level).
        let projA = try XCTUnwrap(projectedDocument(peerA.manager))
        let projB = try XCTUnwrap(projectedDocument(peerB.manager))
        XCTAssertEqual(projA, projB, "A and B project to the identical document after the handshake")
        XCTAssertEqual(projB.blocks.map(\.id), base.map(\.id))
        XCTAssertEqual(projB.blocks.map(\.node), base.map(\.node))
        XCTAssertEqual(projB.blocks.map(\.runs), base.map(\.runs))
    }

    // MARK: - 2. Local-edit propagation

    /// After both peers converge on the base, A types a character locally; the
    /// write path (`applyLocalEdit`) mutates A's replica and broadcasts the
    /// incremental `.update`. Relaying it to B must converge B onto A's new
    /// document — and A's own edit must never register as an inbound remote
    /// change on A (local-echo suppression).
    func testLocalEditOnAPropagatesToB() async throws {
        let peerA = await connectPeer(replicaClientID: aReplicaClientID)
        let peerB = await connectPeer(replicaClientID: bReplicaClientID)
        defer { teardown(peerA, peerB) }

        let base = [para("hello", id: blockID)]
        peerA.socket.deliver(message: step2Frame(data: BlockNoteYjs.encode(base, clientID: 1)))
        await waitUntil { peerA.manager.replicaVersion(for: self.documentID) == 1 }

        let relay = PeerRelay(a: peerA.socket, b: peerB.socket)
        await relay.settle { self.projectedDocument(peerB.manager) != nil }  // B converges on the base
        let bReplicaVersionBefore = peerB.manager.replicaVersion(for: documentID)

        // A types a character. `applyLocalEdit` bumps the local-edit counter and
        // returns/broadcasts the incremental update synchronously (the echo
        // checks below read the counters right after it returns).
        let aReplicaVersionBefore = peerA.manager.replicaVersion(for: documentID)
        let aRemoteChangeBefore = peerA.manager.remoteChangeToken(for: documentID)
        let edited = [para("heXllo", id: blockID)]
        let update = try peerA.manager.applyLocalEdit(old: base, new: edited, for: documentID)
        XCTAssertFalse(update.isEmpty, "a local edit must produce non-empty update bytes")

        // Local-echo suppression: A's own keystroke is a LOCAL edit, never an
        // inbound remote change on A.
        XCTAssertEqual(peerA.manager.localEditVersion(for: documentID), 1, "the edit bumps A's local-edit counter")
        XCTAssertEqual(
            peerA.manager.replicaVersion(for: documentID), aReplicaVersionBefore,
            "a local edit must not bump A's replicaVersion")
        XCTAssertEqual(
            peerA.manager.remoteChangeToken(for: documentID), aRemoteChangeBefore,
            "a local edit must not bump A's remoteChangeToken")

        // Relay the broadcast update to B; B integrates it and converges.
        await relay.settle {
            self.projectedDocument(peerB.manager)?.blocks.map(\.runs) == edited.map(\.runs)
        }
        XCTAssertGreaterThan(
            peerB.manager.replicaVersion(for: documentID), bReplicaVersionBefore,
            "B received the edit as an inbound remote change")

        let projA = try XCTUnwrap(projectedDocument(peerA.manager))
        let projB = try XCTUnwrap(projectedDocument(peerB.manager))
        XCTAssertEqual(projA, projB, "A and B project to A's edited document")
        XCTAssertEqual(projB.blocks.map(\.id), edited.map(\.id))
        XCTAssertEqual(projB.blocks.map(\.runs), edited.map(\.runs))
    }

    // MARK: - 3. Concurrent convergence

    /// Both peers start from the same base, then each inserts a *different* new
    /// block concurrently (neither has seen the other's). Exchanging both updates
    /// both ways must leave both peers on the identical document — order
    /// independent: whatever YATA order the two concurrent inserts settle into,
    /// both peers run the same integration and agree.
    func testConcurrentEditsConvergeOrderIndependently() async throws {
        let peerA = await connectPeer(replicaClientID: aReplicaClientID)
        let peerB = await connectPeer(replicaClientID: bReplicaClientID)
        defer { teardown(peerA, peerB) }

        // Seed BOTH peers from the same base so both start writable and identical.
        let base = [para("hello", id: blockID)]
        let seed = BlockNoteYjs.encode(base, clientID: 1)
        peerA.socket.deliver(message: step2Frame(data: seed))
        peerB.socket.deliver(message: step2Frame(data: seed))
        await waitUntil {
            self.projectedDocument(peerA.manager) != nil && self.projectedDocument(peerB.manager) != nil
        }
        XCTAssertEqual(
            projectedDocument(peerA.manager), projectedDocument(peerB.manager),
            "both peers start from the identical seeded document")

        // The relay carries only frames produced from here on — the pre-existing
        // handshake step1 frames are not part of the concurrent exchange.
        let relay = PeerRelay(a: peerA.socket, b: peerB.socket)
        relay.skipExisting()

        // Concurrent, independent inserts (distinct block ids, authored by each
        // peer's own replica client id ⇒ no struct collision).
        let idA = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let idB = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
        let aEdit = [para("hello", id: blockID), para("from A", id: idA)]
        let bEdit = [para("hello", id: blockID), para("from B", id: idB)]
        _ = try peerA.manager.applyLocalEdit(old: base, new: aEdit, for: documentID)
        _ = try peerB.manager.applyLocalEdit(old: base, new: bEdit, for: documentID)

        // Exchange both updates both ways; both peers integrate both inserts.
        await relay.settle {
            self.projectedDocument(peerA.manager)?.blocks.count == 3
                && self.projectedDocument(peerB.manager)?.blocks.count == 3
        }

        let projA = try XCTUnwrap(projectedDocument(peerA.manager))
        let projB = try XCTUnwrap(projectedDocument(peerB.manager))
        XCTAssertEqual(projA, projB, "both peers converge to the identical document, order-independently")
        XCTAssertEqual(
            Set(projA.blocks.map(\.id)), [blockID, idA, idB], "both concurrent inserts survive on both peers")
        XCTAssertEqual(projA.blocks.count, 3)
    }
}
