import XCTest

@testable import Schrift

@MainActor
final class DocumentCollaborationManagerAwarenessTests: DocumentCollaborationManagerTestCase {
    func testRefreshedLocalAwarenessIsBroadcastByNewSessions() async throws {
        let spy = ManagerSocketFactorySpy()
        let manager = makeAwarenessManager(
            provider: { LocalAwarenessState(name: "Ada", color: "#30bced") }, spy: spy)
        await manager.refreshLocalAwareness()

        let session = manager.session(for: docID)
        // Frame 0 is the handshake; frame 1 announces our presence.
        await waitUntil { spy.sockets.count == 1 && spy.sockets[0].sentFrames.count == 2 }
        let awareness = try HocuspocusMessage(decoding: spy.sockets[0].sentFrames[1])
        XCTAssertEqual(awareness.knownType, .awareness)
        let entries = try AwarenessCodec.decodePayload(awareness.payload)
        XCTAssertEqual(CollaborationPeer(clientID: entries[0].clientID, stateJSON: entries[0].stateJSON)?.name, "Ada")
        session?.stop()
    }

    func testWithoutRefreshSessionsJoinAsSilentObservers() async {
        let spy = ManagerSocketFactorySpy()
        // A provider exists, but refreshLocalAwareness() is never called.
        let manager = makeAwarenessManager(
            provider: { LocalAwarenessState(name: "Ada", color: "#30bced") }, spy: spy)

        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }
        // Only the handshake — no presence announced.
        await waitAndConfirmNever { spy.sockets[0].sentFrames.count > 1 }
        session?.stop()
    }

    func testRefreshWithNilProviderLeavesSessionsSilent() async {
        let spy = ManagerSocketFactorySpy()
        // refreshLocalAwareness() runs but the current-user fetch fails (nil).
        let manager = makeAwarenessManager(provider: { nil }, spy: spy)
        await manager.refreshLocalAwareness()

        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }
        await waitAndConfirmNever { spy.sockets[0].sentFrames.count > 1 }
        session?.stop()
    }

    func testResolvingAwarenessLateRebuildsSilentSessionsToBroadcast() async throws {
        let spy = ManagerSocketFactorySpy()
        // The provider can produce awareness, but a document opens *before* the
        // launch refresh runs, so the first session is a silent observer.
        let manager = makeAwarenessManager(
            provider: { LocalAwarenessState(name: "Ada", color: "#30bced") }, spy: spy)
        _ = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }
        await waitAndConfirmNever { spy.sockets[0].sentFrames.count > 1 }  // silent

        // Awareness resolving rebuilds the live session so it announces us.
        await manager.refreshLocalAwareness()
        await waitUntil { spy.sockets.count == 2 && spy.sockets[1].sentFrames.count == 2 }
        let awareness = try HocuspocusMessage(decoding: spy.sockets[1].sentFrames[1])
        XCTAssertEqual(awareness.knownType, .awareness)
        let entries = try AwarenessCodec.decodePayload(awareness.payload)
        XCTAssertEqual(CollaborationPeer(clientID: entries[0].clientID, stateJSON: entries[0].stateJSON)?.name, "Ada")
        manager.release(docID)
    }

    func testResolvingAwarenessDropsALingeringSilentSessionSoAReopenBroadcasts() async throws {
        let spy = ManagerSocketFactorySpy()
        // Long linger so the reopen lands inside the window.
        let manager = makeAwarenessManager(
            provider: { LocalAwarenessState(name: "Ada", color: "#30bced") }, spy: spy, linger: 5)
        _ = manager.session(for: docID)  // silent observer (awareness not yet refreshed)
        await waitUntil { spy.sockets.count == 1 }
        await waitAndConfirmNever { spy.sockets[0].sentFrames.count > 1 }
        manager.release(docID)  // refCount 0, lingering

        await manager.refreshLocalAwareness()  // drops the lingering silent session

        // Reopen within the linger window rebuilds a fresh session that announces us,
        // rather than reusing the retained silent one.
        _ = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 2 && spy.sockets[1].sentFrames.count == 2 }
        let awareness = try HocuspocusMessage(decoding: spy.sockets[1].sentFrames[1])
        XCTAssertEqual(awareness.knownType, .awareness)
        manager.release(docID)
    }

    func testRefreshWithUnchangedAwarenessDoesNotRebuild() async {
        let spy = ManagerSocketFactorySpy()
        let manager = makeAwarenessManager(
            provider: { LocalAwarenessState(name: "Ada", color: "#30bced") }, spy: spy)
        await manager.refreshLocalAwareness()  // localAwareness set
        _ = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        // A second identical refresh must not tear the session down and reopen it.
        await manager.refreshLocalAwareness()
        await waitAndConfirmNever { spy.sockets.count > 1 }
        manager.release(docID)
    }

    func testPeersForReflectsTheSessionsPeers() async {
        let spy = ManagerSocketFactorySpy()
        let manager = makeAwarenessManager(provider: { nil }, spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        let payload = AwarenessCodec.encodePayload([
            AwarenessEntry(clientID: 7, clock: 1, stateJSON: ##"{"name":"Bo","color":"#111111"}"##)
        ])
        let frame = HocuspocusMessage(
            documentName: docID.uuidString.lowercased(), type: .awareness, payload: payload
        ).encoded()
        spy.sockets[0].deliver(message: frame)

        await waitUntil { manager.peers(for: docID).map(\.name) == ["Bo"] }
        // An unknown document has no session, hence no peers.
        XCTAssertTrue(manager.peers(for: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!).isEmpty)
        session?.stop()
    }

    func testPeersForIsEmptyWhenNoSession() {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(spy: spy)
        XCTAssertTrue(manager.peers(for: docID).isEmpty)
    }
}
