import XCTest

@testable import Schrift

/// Records every socket the manager builds, and the request used, so tests can
/// inspect handshakes and reconnects. Lock-guarded because the factory is
/// `@Sendable`.
private final class SocketFactorySpy: @unchecked Sendable {
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

@MainActor
final class DocumentCollaborationManagerTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let docID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    private func makeManager(
        feature: Bool = true, offline: Bool = false, server: Bool = true,
        cookies: [HTTPCookie] = [], linger: Double = 0.05, spy: SocketFactorySpy
    ) -> DocumentCollaborationManager {
        let manager = DocumentCollaborationManager(
            serverBaseURL: baseURL,
            cookieProvider: { cookies },
            featureEnabled: { feature },
            isOffline: { offline },
            socketFactory: spy.factory,
            lingerSeconds: linger)
        manager.serverSupportsLiveCollaboration = server
        return manager
    }

    // MARK: availability gating

    func testNoSessionWhenFeatureDisabled() {
        let spy = SocketFactorySpy()
        let manager = makeManager(feature: false, spy: spy)
        XCTAssertNil(manager.session(for: docID))
        XCTAssertEqual(manager.availability, .featureDisabled)
        XCTAssertTrue(spy.sockets.isEmpty)
    }

    func testNoSessionWhenOffline() {
        let spy = SocketFactorySpy()
        XCTAssertNil(makeManager(offline: true, spy: spy).session(for: docID))
        XCTAssertTrue(spy.sockets.isEmpty)
    }

    func testNoSessionWhenServerUnsupported() {
        let spy = SocketFactorySpy()
        XCTAssertNil(makeManager(server: false, spy: spy).session(for: docID))
        XCTAssertTrue(spy.sockets.isEmpty)
    }

    // MARK: creation, reuse, refcount

    func testCreatesAndConnectsSessionWhenAvailable() async {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        XCTAssertNotNil(session)
        XCTAssertEqual(manager.activeDocumentCount, 1)
        // The session sent its handshake through the one socket the manager built.
        await waitUntil { spy.sockets.count == 1 && spy.sockets[0].sentFrames.count == 1 }
        session?.stop()
    }

    func testDialsOriginPinnedURLWithHeaders() async {
        let spy = SocketFactorySpy()
        let cookie = HTTPCookie(properties: [
            .domain: "docs.example.org", .path: "/", .name: "sessionid", .value: "abc",
        ])!
        let manager = makeManager(cookies: [cookie], spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.requests.count == 1 }
        let request = spy.requests[0]
        XCTAssertEqual(
            request.url?.absoluteString,
            "wss://docs.example.org/collaboration/ws/?room=11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://docs.example.org")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "sessionid=abc")
        session?.stop()
    }

    func testReopenSameDocumentReusesOneSocket() {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        let first = manager.session(for: docID)
        let second = manager.session(for: docID)
        XCTAssertTrue(first === second)
        XCTAssertEqual(spy.sockets.count, 1)
        XCTAssertEqual(manager.activeDocumentCount, 1)
    }

    // MARK: release + linger teardown

    func testReleaseLingersThenTearsDown() async {
        let spy = SocketFactorySpy()
        let manager = makeManager(linger: 0.05, spy: spy)
        _ = manager.session(for: docID)
        manager.release(docID)
        // Still present during the linger window, gone after it.
        await waitUntil { manager.activeDocumentCount == 0 }
        await waitUntil { spy.sockets[0].cancelCloseCode == .goingAway }
    }

    func testOutstandingReferenceKeepsSession() async {
        let spy = SocketFactorySpy()
        let manager = makeManager(linger: 0.05, spy: spy)
        _ = manager.session(for: docID)
        _ = manager.session(for: docID)  // refCount 2
        manager.release(docID)  // refCount 1
        await waitAndConfirmNever { manager.activeDocumentCount == 0 }
        manager.release(docID)
        await waitUntil { manager.activeDocumentCount == 0 }
    }

    func testReopenDuringLingerCancelsTeardown() async {
        let spy = SocketFactorySpy()
        let manager = makeManager(linger: 0.2, spy: spy)
        let first = manager.session(for: docID)
        manager.release(docID)  // schedules teardown in 0.2s
        let reopened = manager.session(for: docID)  // cancels it
        XCTAssertTrue(first === reopened)
        XCTAssertEqual(spy.sockets.count, 1)
        await waitAndConfirmNever(timeout: 0.4) { manager.activeDocumentCount == 0 }
    }

    // MARK: suspend / resume / reconnect

    func testSuspendClosesSocketAndResumeRebuilds() async {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        _ = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        manager.suspend()
        await waitUntil { spy.sockets[0].cancelCloseCode == .goingAway }

        manager.resume()
        // A fresh socket for the still-referenced document.
        await waitUntil { spy.sockets.count == 2 }
        XCTAssertEqual(manager.activeDocumentCount, 1)
        manager.session(for: docID).map { $0.stop() }
    }

    func testReconnectRebuildsSession() async {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        _ = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        manager.reconnect()
        await waitUntil { spy.sockets.count == 2 }
        await waitUntil { spy.sockets[0].cancelCloseCode == .goingAway }
    }
}
