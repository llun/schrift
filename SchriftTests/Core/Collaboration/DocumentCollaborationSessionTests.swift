import XCTest

@testable import Schrift

/// Counts main-actor change signals for the session under test.
@MainActor
private final class ChangeCounter {
    var count = 0
}

/// Captures the most recent main-actor sync-update payload for the session
/// under test.
@MainActor
private final class UpdateCapture {
    var data: Data?
    var count = 0
}

/// Captures a peer's step1 state-vector request and hands back a scripted
/// reply (or nil for "no diff to send").
@MainActor
private final class StateRequestCapture {
    var received: Data?
    var count = 0
    var reply: Data?
}

/// Counts `onInitialSync` firings and records the interleaving with
/// `onSyncUpdate` so the ordering guarantee is checked, not just the count.
@MainActor
private final class InitialSyncRecorder {
    var count = 0
    var callOrder: [String] = []
}

@MainActor
final class DocumentCollaborationSessionTests: XCTestCase {
    private let doc = "11111111-1111-4111-8111-111111111111"

    private func syncFrame(step: SyncStep = .update, data: Data = Data([0x00])) -> Data {
        let payload = SyncMessage(step: step, data: data).encodedPayload()
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

    private func makeSession(_ fake: FakeWebSocket, _ counter: ChangeCounter, _ capture: UpdateCapture)
        -> DocumentCollaborationSession
    {
        DocumentCollaborationSession(
            documentName: doc, transport: CollaborationTransport(socket: fake),
            onRemoteChange: { counter.count += 1 },
            onSyncUpdate: { data in
                capture.data = data
                capture.count += 1
            })
    }

    private func makeSession(_ fake: FakeWebSocket, _ counter: ChangeCounter, stateRequest: StateRequestCapture)
        -> DocumentCollaborationSession
    {
        DocumentCollaborationSession(
            documentName: doc, transport: CollaborationTransport(socket: fake),
            onRemoteChange: { counter.count += 1 },
            onStateRequest: { data in
                stateRequest.received = data
                stateRequest.count += 1
                return stateRequest.reply
            })
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

    // MARK: - inbound sync update bytes (C1)

    // MARK: - outbound write path (C2a)

    func testStartUsesInjectedInitialSyncStep1() async throws {
        let fake = FakeWebSocket()
        let counter = ChangeCounter()
        let session = DocumentCollaborationSession(
            documentName: doc, transport: CollaborationTransport(socket: fake),
            onRemoteChange: { counter.count += 1 }, initialSyncStep1: { Data([0xAA, 0xBB]) })
        session.start()

        await waitUntil { fake.sentFrames.count == 1 }
        let sent = try HocuspocusMessage(decoding: fake.sentFrames[0])
        XCTAssertEqual(sent.documentName, doc)
        XCTAssertEqual(sent.knownType, .sync)
        let sync = try SyncMessage(decodingPayload: sent.payload)
        XCTAssertEqual(sync.step, .step1)
        XCTAssertEqual(sync.data, Data([0xAA, 0xBB]))

        session.stop()
        await waitUntil { session.state == .ended(.closed) }
    }

    func testBroadcastSendsSyncUpdateFrame() async throws {
        let fake = FakeWebSocket()
        let counter = ChangeCounter()
        let session = makeSession(fake, counter)
        session.start()
        await waitUntil { fake.sentFrames.count == 1 }

        await session.broadcast(update: Data([0x01, 0x02]))
        await waitUntil { fake.sentFrames.count == 2 }
        let sent = try HocuspocusMessage(decoding: fake.sentFrames[1])
        XCTAssertEqual(sent.documentName, doc)
        XCTAssertEqual(sent.knownType, .sync)
        let sync = try SyncMessage(decodingPayload: sent.payload)
        XCTAssertEqual(sync.step, .update)
        XCTAssertEqual(sync.data, Data([0x01, 0x02]))

        session.stop()
        await waitUntil { session.state == .ended(.closed) }
    }

    func testDeliversStep2UpdateBytesToOnSyncUpdate() async {
        let fake = FakeWebSocket()
        let counter = ChangeCounter()
        let capture = UpdateCapture()
        let session = makeSession(fake, counter, capture)
        session.start()
        await waitUntil { fake.sentFrames.count == 1 }

        let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        fake.deliver(message: syncFrame(step: .step2, data: bytes))
        await waitUntil { capture.count == 1 }
        XCTAssertEqual(capture.data, bytes)
        XCTAssertEqual(counter.count, 1)

        session.stop()
        await waitUntil { session.state == .ended(.closed) }
    }

    func testDeliversUpdateStepBytesToOnSyncUpdate() async {
        let fake = FakeWebSocket()
        let counter = ChangeCounter()
        let capture = UpdateCapture()
        let session = makeSession(fake, counter, capture)
        session.start()
        await waitUntil { fake.sentFrames.count == 1 }

        let bytes = Data([0x01, 0x02, 0x03])
        fake.deliver(message: syncFrame(step: .update, data: bytes))
        await waitUntil { capture.count == 1 }
        XCTAssertEqual(capture.data, bytes)
        XCTAssertEqual(counter.count, 1)

        session.stop()
        await waitUntil { session.state == .ended(.closed) }
    }

    func testStep1FrameSignalsButDeliversNoBytes() async {
        let fake = FakeWebSocket()
        let counter = ChangeCounter()
        let capture = UpdateCapture()
        let session = makeSession(fake, counter, capture)
        session.start()
        await waitUntil { fake.sentFrames.count == 1 }

        fake.deliver(message: syncFrame(step: .step1, data: Data([0x00])))
        await waitUntil { counter.count == 1 }
        XCTAssertNil(capture.data)
        XCTAssertEqual(capture.count, 0)

        session.stop()
        await waitUntil { session.state == .ended(.closed) }
    }

    func testMalformedSyncPayloadSignalsButDeliversNoBytes() async {
        let fake = FakeWebSocket()
        let counter = ChangeCounter()
        let capture = UpdateCapture()
        let session = makeSession(fake, counter, capture)
        session.start()
        await waitUntil { fake.sentFrames.count == 1 }

        let garbage = HocuspocusMessage(documentName: doc, type: .sync, payload: Data([0xFF, 0xFF])).encoded()
        fake.deliver(message: garbage)
        await waitUntil { counter.count == 1 }
        XCTAssertNil(capture.data)
        XCTAssertEqual(capture.count, 0)

        session.stop()
        await waitUntil { session.state == .ended(.closed) }
    }

    // MARK: - inbound peer step1 + first-sync signal (C2a)

    func testStep1FrameInvokesOnStateRequestAndSendsStep2Reply() async throws {
        let fake = FakeWebSocket()
        let counter = ChangeCounter()
        let stateRequest = StateRequestCapture()
        stateRequest.reply = Data([0xDD])
        let session = makeSession(fake, counter, stateRequest: stateRequest)
        session.start()
        await waitUntil { fake.sentFrames.count == 1 }

        fake.deliver(message: syncFrame(step: .step1, data: Data([0xCC])))
        await waitUntil { fake.sentFrames.count == 2 }
        XCTAssertEqual(stateRequest.received, Data([0xCC]))
        XCTAssertEqual(stateRequest.count, 1)
        let sent = try HocuspocusMessage(decoding: fake.sentFrames[1])
        XCTAssertEqual(sent.documentName, doc)
        XCTAssertEqual(sent.knownType, .sync)
        let sync = try SyncMessage(decodingPayload: sent.payload)
        XCTAssertEqual(sync.step, .step2)
        XCTAssertEqual(sync.data, Data([0xDD]))

        session.stop()
        await waitUntil { session.state == .ended(.closed) }
    }

    func testStep1FrameWithNilReplySendsNoFrame() async {
        let fake = FakeWebSocket()
        let counter = ChangeCounter()
        let stateRequest = StateRequestCapture()  // reply stays nil
        let session = makeSession(fake, counter, stateRequest: stateRequest)
        session.start()
        await waitUntil { fake.sentFrames.count == 1 }

        fake.deliver(message: syncFrame(step: .step1, data: Data([0xCC])))
        await waitUntil { stateRequest.count == 1 }
        XCTAssertEqual(stateRequest.received, Data([0xCC]))
        await waitAndConfirmNever { fake.sentFrames.count > 1 }

        session.stop()
        await waitUntil { session.state == .ended(.closed) }
    }

    func testFirstStep2FrameFiresOnInitialSyncOnceAfterOnSyncUpdate() async {
        let fake = FakeWebSocket()
        let counter = ChangeCounter()
        let capture = UpdateCapture()
        let initialSync = InitialSyncRecorder()
        let session = DocumentCollaborationSession(
            documentName: doc, transport: CollaborationTransport(socket: fake),
            onRemoteChange: { counter.count += 1 },
            onSyncUpdate: { data in
                capture.data = data
                capture.count += 1
                initialSync.callOrder.append("onSyncUpdate")
            },
            onInitialSync: {
                initialSync.count += 1
                initialSync.callOrder.append("onInitialSync")
            })
        session.start()
        await waitUntil { fake.sentFrames.count == 1 }

        let bytes = Data([0x01, 0x02])
        fake.deliver(message: syncFrame(step: .step2, data: bytes))
        await waitUntil { initialSync.count == 1 }
        XCTAssertEqual(capture.count, 1)
        XCTAssertEqual(capture.data, bytes)
        // onSyncUpdate (bytes integrated) must run before onInitialSync (the
        // manager's "initial sync applied" latch) — never the reverse.
        XCTAssertEqual(initialSync.callOrder, ["onSyncUpdate", "onInitialSync"])

        session.stop()
        await waitUntil { session.state == .ended(.closed) }
    }

    func testOnInitialSyncDoesNotFireAgainOnSubsequentStep2OrUpdate() async {
        let fake = FakeWebSocket()
        let counter = ChangeCounter()
        let capture = UpdateCapture()
        let initialSync = InitialSyncRecorder()
        let session = DocumentCollaborationSession(
            documentName: doc, transport: CollaborationTransport(socket: fake),
            onRemoteChange: { counter.count += 1 },
            onSyncUpdate: { data in
                capture.data = data
                capture.count += 1
            },
            onInitialSync: { initialSync.count += 1 })
        session.start()
        await waitUntil { fake.sentFrames.count == 1 }

        fake.deliver(message: syncFrame(step: .step2, data: Data([0x01])))
        await waitUntil { initialSync.count == 1 }

        fake.deliver(message: syncFrame(step: .step2, data: Data([0x02])))
        await waitUntil { capture.count == 2 }
        fake.deliver(message: syncFrame(step: .update, data: Data([0x03])))
        await waitUntil { capture.count == 3 }
        XCTAssertEqual(initialSync.count, 1)

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

    func testPeersAccumulateAcrossSeparateFrames() async {
        let fake = FakeWebSocket()
        let session = makePresenceSession(fake, clientID: 42)
        session.start()
        await waitUntil { fake.sentFrames.count == 2 }

        // Two independent frames — the second must not drop the first peer
        // (y-awareness updates are incremental).
        fake.deliver(message: awarenessFrame([peerEntry(1, "Ada")]))
        await waitUntil { session.peers.map(\.clientID) == [1] }
        fake.deliver(message: awarenessFrame([peerEntry(2, "Bo")]))
        await waitUntil { session.peers.map(\.clientID) == [1, 2] }

        session.stop()
        await waitUntil { session.state == .ended(.closed) }
    }

    func testIgnoresFramesForADifferentDocument() async {
        let fake = FakeWebSocket()
        let counter = ChangeCounter()
        let session = DocumentCollaborationSession(
            documentName: doc, transport: CollaborationTransport(socket: fake),
            clientID: 42, localState: LocalAwarenessState(name: "Me", color: "#abcdef"),
            onRemoteChange: { counter.count += 1 })
        session.start()
        await waitUntil { fake.sentFrames.count == 2 }

        // A frame for the wrong room must inject no peer and fire no change signal.
        let otherDoc = "22222222-2222-4222-8222-222222222222"
        let otherAwareness = AwarenessCodec.encodePayload([peerEntry(1, "Ada")])
        fake.deliver(
            message: HocuspocusMessage(documentName: otherDoc, type: .awareness, payload: otherAwareness).encoded())
        let otherSync = SyncMessage(step: .update, data: Data([0x00])).encodedPayload()
        fake.deliver(message: HocuspocusMessage(documentName: otherDoc, type: .sync, payload: otherSync).encoded())
        await waitAndConfirmNever { !session.peers.isEmpty || counter.count > 0 }

        session.stop()
        await waitUntil { session.state == .ended(.closed) }
    }

    func testDisconnectClearsPeers() async {
        let fake = FakeWebSocket()
        let session = makePresenceSession(fake, clientID: 42)
        session.start()
        await waitUntil { fake.sentFrames.count == 2 }

        fake.deliver(message: awarenessFrame([peerEntry(1, "Ada")]))
        await waitUntil { session.peers.count == 1 }

        // A transient drop leaves no live presence info — peers clear.
        fake.failTransport()
        await waitUntil { session.state == .reconnecting }
        XCTAssertTrue(session.peers.isEmpty)
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
