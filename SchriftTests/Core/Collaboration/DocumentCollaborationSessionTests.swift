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

    private func awarenessFrame() -> Data {
        let payload = AwarenessCodec.encodePayload([AwarenessEntry(clientID: 1, clock: 1, stateJSON: "{}")])
        return HocuspocusMessage(documentName: doc, type: .awareness, payload: payload).encoded()
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
        // Confirm no change signal ever fires (awareness is a later PR).
        await waitAndConfirmNever { counter.count > 0 }

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
