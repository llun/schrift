import XCTest

@testable import Schrift

/// Counts main-actor change signals for the session under test.
@MainActor
private final class ChangeCounter {
    var count = 0
}

@MainActor
final class DocumentCollaborationSessionTests: XCTestCase {
    private let doc = "11111111-1111-4111-8111-111111111111"

    private func syncFrame(step: SyncStep = .update) -> Data {
        let payload = SyncMessage(step: step, data: Data([0x00])).encodedPayload()
        return HocuspocusMessage(documentName: doc, type: .sync, payload: payload).encoded()
    }

    private func awarenessFrame(_ entries: [AwarenessEntry] = [AwarenessEntry(clientID: 1, clock: 1, stateJSON: "{}")])
        -> Data
    {
        let payload = AwarenessCodec.encodePayload(entries)
        return HocuspocusMessage(documentName: doc, type: .awareness, payload: payload).encoded()
    }

    private func peerEntry(_ clientID: UInt, _ name: String) -> AwarenessEntry {
        AwarenessEntry(clientID: clientID, clock: 1, stateJSON: ##"{"name":"\##(name)","color":"#111111"}"##)
    }

    private func makeSession(_ fake: FakeWebSocket, _ counter: ChangeCounter) -> DocumentCollaborationSession {
        DocumentCollaborationSession(
            documentName: doc, transport: CollaborationTransport(socket: fake),
            onRemoteChange: { counter.count += 1 })
    }

    func testStartSendsEmptyStateVectorHandshakeAndGoesLive() async throws {
        let fake = FakeWebSocket()
        let counter = ChangeCounter()
        let session = makeSession(fake, counter)
        session.start()

        await waitUntil { fake.sentFrames.count == 1 }
        let sent = try HocuspocusMessage(decoding: fake.sentFrames[0])
        XCTAssertEqual(sent.documentName, doc)
        XCTAssertEqual(sent.knownType, .sync)
        let sync = try SyncMessage(decodingPayload: sent.payload)
        XCTAssertEqual(sync.step, .step1)
        XCTAssertEqual(sync.data, Data([0x00]))
        await waitUntil { session.state == .live }

        session.stop()
        await waitUntil { session.state == .ended(.closed) }
    }

    func testRemoteSyncFrameFiresChangeSignal() async {
        let fake = FakeWebSocket()
        let counter = ChangeCounter()
        let session = makeSession(fake, counter)
        session.start()
        await waitUntil { fake.sentFrames.count == 1 }

        fake.deliver(message: syncFrame())
        await waitUntil { counter.count == 1 }
        XCTAssertEqual(session.state, .live)

        fake.deliver(message: syncFrame())
        await waitUntil { counter.count == 2 }

        session.stop()
        await waitUntil { session.state == .ended(.closed) }
    }

    func testAwarenessFrameDoesNotFireChangeSignal() async {
        let fake = FakeWebSocket()
        let counter = ChangeCounter()
        let session = makeSession(fake, counter)
        session.start()
        await waitUntil { fake.sentFrames.count == 1 }

        fake.deliver(message: awarenessFrame())
        // Presence updates peers, but is not a content change — no signal fires.
        await waitAndConfirmNever { counter.count > 0 }

        session.stop()
        await waitUntil { session.state == .ended(.closed) }
    }

    // MARK: - presence (awareness in/out)

    private func makePresenceSession(_ fake: FakeWebSocket, clientID: UInt = 42, name: String = "Me")
        -> DocumentCollaborationSession
    {
        DocumentCollaborationSession(
            documentName: doc, transport: CollaborationTransport(socket: fake),
            clientID: clientID, localState: LocalAwarenessState(name: name, color: "#abcdef"))
    }

    func testBroadcastsLocalAwarenessAfterHandshake() async throws {
        let fake = FakeWebSocket()
        let session = makePresenceSession(fake, clientID: 42, name: "Me")
        session.start()

        // Frame 0 is the sync handshake; frame 1 is our awareness announcement.
        await waitUntil { fake.sentFrames.count == 2 }
        let awareness = try HocuspocusMessage(decoding: fake.sentFrames[1])
        XCTAssertEqual(awareness.knownType, .awareness)
        let entries = try AwarenessCodec.decodePayload(awareness.payload)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].clientID, 42)
        XCTAssertEqual(entries[0].clock, 1)
        let state = try XCTUnwrap(CollaborationPeer(clientID: 42, stateJSON: entries[0].stateJSON))
        XCTAssertEqual(state.name, "Me")
        XCTAssertEqual(state.color, "#abcdef")

        session.stop()
        await waitUntil { session.state == .ended(.closed) }
    }

    func testWithoutLocalStateSendsOnlyTheHandshake() async {
        let fake = FakeWebSocket()
        let counter = ChangeCounter()
        let session = makeSession(fake, counter)  // no localState
        session.start()
        await waitUntil { fake.sentFrames.count == 1 }
        // No awareness announcement follows when joining as an observer.
        await waitAndConfirmNever { fake.sentFrames.count > 1 }
        session.stop()
        await waitUntil { session.state == .ended(.closed) }
    }

    func testTracksPeersFromAwarenessFrames() async {
        let fake = FakeWebSocket()
        let session = makePresenceSession(fake, clientID: 42)
        session.start()
        await waitUntil { fake.sentFrames.count == 2 }

        fake.deliver(message: awarenessFrame([peerEntry(1, "Ada"), peerEntry(2, "Bo")]))
        await waitUntil { session.peers.count == 2 }
        XCTAssertEqual(session.peers.map(\.name), ["Ada", "Bo"])

        session.stop()
        await waitUntil { session.state == .ended(.closed) }
    }

    func testExcludesOwnClientIDFromPeers() async {
        let fake = FakeWebSocket()
        let session = makePresenceSession(fake, clientID: 42)
        session.start()
        await waitUntil { fake.sentFrames.count == 2 }

        // The server echoes our own awareness back — it must not appear as a peer.
        fake.deliver(message: awarenessFrame([peerEntry(42, "Me"), peerEntry(1, "Ada")]))
        await waitUntil { session.peers.count == 1 }
        XCTAssertEqual(session.peers.map(\.clientID), [1])

        session.stop()
        await waitUntil { session.state == .ended(.closed) }
    }

    func testNullAwarenessRemovesAPeer() async {
        let fake = FakeWebSocket()
        let session = makePresenceSession(fake, clientID: 42)
        session.start()
        await waitUntil { fake.sentFrames.count == 2 }

        fake.deliver(message: awarenessFrame([peerEntry(1, "Ada")]))
        await waitUntil { session.peers.count == 1 }

        fake.deliver(message: awarenessFrame([AwarenessEntry(clientID: 1, clock: 2, stateJSON: "null")]))
        await waitUntil { session.peers.isEmpty }

        session.stop()
        await waitUntil { session.state == .ended(.closed) }
    }

    func testServerCloseWith1000EndsWithPermissionsReset() async {
        let fake = FakeWebSocket()
        let counter = ChangeCounter()
        let session = makeSession(fake, counter)
        session.start()
        await waitUntil { fake.sentFrames.count == 1 }

        fake.serverClose(code: .normalClosure)
        await waitUntil { session.state == .ended(.permissionsReset) }
    }

    func testTransientDisconnectGoesReconnecting() async {
        let fake = FakeWebSocket()
        let counter = ChangeCounter()
        let session = makeSession(fake, counter)
        session.start()
        await waitUntil { fake.sentFrames.count == 1 }

        fake.failTransport()
        await waitUntil { session.state == .reconnecting }
    }

    func testStopSelfClosesWith1001() async {
        let fake = FakeWebSocket()
        let counter = ChangeCounter()
        let session = makeSession(fake, counter)
        session.start()
        await waitUntil { fake.sentFrames.count == 1 }

        session.stop()
        await waitUntil { session.state == .ended(.closed) }
        XCTAssertEqual(fake.cancelCloseCode, .goingAway)
    }
}
