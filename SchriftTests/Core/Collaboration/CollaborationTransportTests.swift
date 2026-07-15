import XCTest

@testable import Schrift

/// Collects the transport's event stream on the main actor so `waitUntil` can
/// poll it (its condition closure is `@MainActor`).
@MainActor
private final class EventLog {
    var events: [CollaborationEvent] = []
    var finished = false
    var disconnect: CollaborationDisconnect? {
        for event in events { if case .disconnected(let reason) = event { return reason } }
        return nil
    }
    var messages: [HocuspocusMessage] {
        events.compactMap { if case .message(let m) = $0 { return m } else { return nil } }
    }
}

@MainActor
final class CollaborationTransportTests: XCTestCase {
    private func frame(_ type: HocuspocusMessageType, _ payload: Data = Data()) -> HocuspocusMessage {
        HocuspocusMessage(documentName: "11111111-1111-4111-8111-111111111111", type: type, payload: payload)
    }

    /// Starts the transport, wiring its stream into a main-actor `EventLog`.
    private func startLogging(_ transport: CollaborationTransport) async -> (EventLog, Task<Void, Never>) {
        let log = EventLog()
        let stream = await transport.start()
        let consume = Task { @MainActor in
            for await event in stream { log.events.append(event) }
        }
        return (log, consume)
    }

    func testForwardsDecodedInboundFrames() async {
        let fake = FakeWebSocket()
        let transport = CollaborationTransport(socket: fake)
        let (log, consume) = await startLogging(transport)
        XCTAssertTrue(fake.didResume)

        fake.deliver(message: frame(.awareness, Data([0x00])).encoded())
        await waitUntil { log.messages.count == 1 }
        XCTAssertEqual(log.messages.first, frame(.awareness, Data([0x00])))

        await transport.close()
        await waitUntil { log.disconnect != nil }
        consume.cancel()
    }

    func testDropsUndecodableFrames() async {
        let fake = FakeWebSocket()
        let transport = CollaborationTransport(socket: fake)
        let (log, consume) = await startLogging(transport)

        // A lone continuation byte can't be decoded as a frame — it is dropped,
        // not fatal — and the next valid frame still arrives.
        fake.deliver(message: Data([0x80]))
        fake.deliver(message: frame(.sync, Data([0x00, 0x01, 0x00])).encoded())
        await waitUntil { log.messages.count == 1 }
        XCTAssertEqual(log.messages, [frame(.sync, Data([0x00, 0x01, 0x00]))])

        await transport.close()
        await waitUntil { log.disconnect != nil }
        consume.cancel()
    }

    func testSendEncodesAndForwardsFrame() async throws {
        let fake = FakeWebSocket()
        let transport = CollaborationTransport(socket: fake)
        let (log, consume) = await startLogging(transport)

        let message = frame(.sync, Data([0x00, 0x01, 0x00]))
        try await transport.send(message)
        await waitUntil { fake.sentFrames.count == 1 }
        XCTAssertEqual(fake.sentFrames.first, message.encoded())

        await transport.close()
        await waitUntil { log.disconnect != nil }
        consume.cancel()
    }

    func testPingForwards() async throws {
        let fake = FakeWebSocket()
        let transport = CollaborationTransport(socket: fake)
        let (log, consume) = await startLogging(transport)

        try await transport.ping()
        await waitUntil { fake.pingCount == 1 }

        await transport.close()
        await waitUntil { log.disconnect != nil }
        consume.cancel()
    }

    func testServerClose1000ReportsPermissionsReset() async {
        let fake = FakeWebSocket()
        let transport = CollaborationTransport(socket: fake)
        let (log, consume) = await startLogging(transport)

        fake.serverClose(code: .normalClosure)
        await waitUntil { log.disconnect == .permissionsReset }
        consume.cancel()
    }

    func testTransportErrorReportsTransient() async {
        let fake = FakeWebSocket()
        let transport = CollaborationTransport(socket: fake)
        let (log, consume) = await startLogging(transport)

        fake.failTransport()
        await waitUntil { log.disconnect == .transient }
        consume.cancel()
    }

    func testSelfCloseUses1001AndReportsSelfClosed() async {
        let fake = FakeWebSocket()
        let transport = CollaborationTransport(socket: fake)
        let (log, consume) = await startLogging(transport)

        await transport.close()
        await waitUntil { log.disconnect == .selfClosed }
        XCTAssertEqual(fake.cancelCloseCode, .goingAway)
        consume.cancel()
    }

    func testStreamFinishesAfterDisconnect() async {
        let fake = FakeWebSocket()
        let transport = CollaborationTransport(socket: fake)
        let log = EventLog()
        let stream = await transport.start()
        let consume = Task { @MainActor in
            for await event in stream { log.events.append(event) }
            log.finished = true
        }

        fake.serverClose(code: .normalClosure)
        await waitUntil { log.finished }
        XCTAssertEqual(log.events.count, 1)
        XCTAssertEqual(log.disconnect, .permissionsReset)
        consume.cancel()
    }
}
