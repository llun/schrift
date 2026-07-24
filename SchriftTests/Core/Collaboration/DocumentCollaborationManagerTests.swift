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
        cookies: [HTTPCookie] = [], linger: Double = 0.05,
        config: ServerConfig? = nil, replicaClientID: UInt32 = 42, spy: SocketFactorySpy
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

    private func makeAwarenessManager(
        provider: @escaping @Sendable () async -> LocalAwarenessState?, spy: SocketFactorySpy, linger: Double = 0.05
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

    // MARK: - local awareness (presence identity)

    func testRefreshedLocalAwarenessIsBroadcastByNewSessions() async throws {
        let spy = SocketFactorySpy()
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
        let spy = SocketFactorySpy()
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
        let spy = SocketFactorySpy()
        // refreshLocalAwareness() runs but the current-user fetch fails (nil).
        let manager = makeAwarenessManager(provider: { nil }, spy: spy)
        await manager.refreshLocalAwareness()

        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }
        await waitAndConfirmNever { spy.sockets[0].sentFrames.count > 1 }
        session?.stop()
    }

    func testResolvingAwarenessLateRebuildsSilentSessionsToBroadcast() async throws {
        let spy = SocketFactorySpy()
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
        let spy = SocketFactorySpy()
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
        let spy = SocketFactorySpy()
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

    // MARK: - peers accessor

    func testPeersForReflectsTheSessionsPeers() async {
        let spy = SocketFactorySpy()
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
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        XCTAssertTrue(manager.peers(for: docID).isEmpty)
    }

    // MARK: - remote change token (live refresh)

    private func syncFrame() -> Data {
        let payload = SyncMessage(step: .update, data: Data([0x00])).encodedPayload()
        return HocuspocusMessage(documentName: docID.uuidString.lowercased(), type: .sync, payload: payload).encoded()
    }

    func testRemoteChangeTokenIncrementsOnEachSyncSignal() async {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }
        XCTAssertEqual(manager.remoteChangeToken(for: docID), 0)

        spy.sockets[0].deliver(message: syncFrame())
        await waitUntil { manager.remoteChangeToken(for: docID) == 1 }
        spy.sockets[0].deliver(message: syncFrame())
        await waitUntil { manager.remoteChangeToken(for: docID) == 2 }
        session?.stop()
    }

    func testRemoteChangeTokenResetsWhenTheDocumentIsTornDown() async {
        let spy = SocketFactorySpy()
        let manager = makeManager(linger: 0.05, spy: spy)
        _ = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }
        spy.sockets[0].deliver(message: syncFrame())
        await waitUntil { manager.remoteChangeToken(for: docID) == 1 }

        manager.release(docID)
        await waitUntil { manager.activeDocumentCount == 0 }
        XCTAssertEqual(manager.remoteChangeToken(for: docID), 0)
    }

    // MARK: - per-document replica (C1: apply, version, projection)

    /// A `.sync`/`.update` frame wrapping real (or malformed) update bytes — the
    /// same wire shape `syncFrame()` above uses, but carrying payload the
    /// session's `onSyncUpdate` actually decodes, so these tests drive
    /// `applyReplicaUpdate` through the real socket → session → manager path
    /// rather than calling manager internals directly.
    private func syncUpdateFrame(data: Data) -> Data {
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
    private func syncStep2Frame(data: Data) -> Data {
        let payload = SyncMessage(step: .step2, data: data).encodedPayload()
        return HocuspocusMessage(documentName: docID.uuidString.lowercased(), type: .sync, payload: payload).encoded()
    }

    /// A `SyncReply`(4)/`.step2` frame — what a *real* Hocuspocus server sends in
    /// answer to our `Sync`(0)+SyncStep1 handshake (the app only ever *sends*
    /// `Sync`(0)). It must drive the identical path as `syncStep2Frame`: fire
    /// `onInitialSync`, mark the replica synced, and make it writable.
    private func syncReplyStep2Frame(data: Data) -> Data {
        let payload = SyncMessage(step: .step2, data: data).encodedPayload()
        return HocuspocusMessage(documentName: docID.uuidString.lowercased(), type: .syncReply, payload: payload)
            .encoded()
    }

    /// A `.sync`/`.step1` frame carrying a peer's state vector — a peer/relay
    /// asking us for our state. The session routes it to `onStateRequest` →
    /// `stateReply`, and a non-nil reply is sent back as a `.step2` diff.
    private func step1Frame(stateVector: Data) -> Data {
        let payload = SyncMessage(step: .step1, data: stateVector).encodedPayload()
        return HocuspocusMessage(documentName: docID.uuidString.lowercased(), type: .sync, payload: payload).encoded()
    }

    func testAppliesInitialSyncBumpsReplicaVersionAndProjects() async throws {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }
        XCTAssertEqual(manager.replicaVersion(for: docID), 0)
        XCTAssertNil(manager.projectedReplica(for: docID, interlinkingOrigin: nil))

        // The initial full state arrives as the `.step2` reply to our SyncStep1 —
        // which fires `onInitialSync` and marks the replica synced (writable/
        // projectable). A bare `.update` would build the replica but leave it
        // un-synced (see `testInboundUpdateBeforeInitialSyncBuildsReplicaButRefusesWrites`).
        let update = MarkdownYjs.encode(markdown: "# Title\n\nBody", clientID: 1)
        spy.sockets[0].deliver(message: syncStep2Frame(data: update))

        await waitUntil { manager.replicaVersion(for: docID) == 1 }
        let projected = try XCTUnwrap(manager.projectedReplica(for: docID, interlinkingOrigin: nil))
        XCTAssertEqual(projected.blocks.map(\.node), ["heading", "paragraph"])
        XCTAssertEqual(projected.blocks[1].runs, [InlineRun("Body")])
        XCTAssertTrue(projected.isFullyRenderable)
        XCTAssertFalse(manager.replicaIsFailSafe(for: docID))
        session?.stop()
    }

    /// C2c: a registered replica observer fires **synchronously, in the same main-actor
    /// turn** an inbound update integrates and bumps `replicaVersion` — this is what lets
    /// the editor bridge re-sync its write baseline before any keystroke can race in. The
    /// observer records the version it *sees* when fired; requiring it to already equal the
    /// post-integrate value (never a stale `0`) pins the "same turn as the bump" contract,
    /// since a deferred fire could only ever observe a value set in an earlier turn.
    func testInboundIntegrateFiresTheReplicaObserverSynchronouslyAfterTheVersionBump() async throws {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        var fireCount = 0
        var versionsSeenAtFire: [Int] = []
        // `[weak manager]` avoids a retain cycle (the manager stores this closure).
        manager.setReplicaObserver(
            { [weak manager] in
                fireCount += 1
                versionsSeenAtFire.append(manager?.replicaVersion(for: self.docID) ?? -1)
            }, for: docID)

        let update = MarkdownYjs.encode(markdown: "# Title\n\nBody", clientID: 1)
        spy.sockets[0].deliver(message: syncStep2Frame(data: update))
        await waitUntil { manager.replicaVersion(for: docID) == 1 }

        XCTAssertEqual(fireCount, 1, "the observer fires exactly once per integrated update")
        XCTAssertEqual(
            versionsSeenAtFire, [1],
            "it fires AFTER the version bump, in the same turn — never a deferred stale read")
        session?.stop()
    }

    /// The observer is strictly the *integrated-cleanly* edge: a malformed update
    /// fail-safes the replica and does **not** bump `replicaVersion`, so there is no
    /// trustworthy state to hand the editor and the observer must stay silent (the
    /// change-signal fallback via `remoteChangeToken` still fires — tested separately).
    func testMalformedInboundUpdateDoesNotFireTheReplicaObserver() async {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        var fireCount = 0
        manager.setReplicaObserver({ fireCount += 1 }, for: docID)

        let garbage = Data([0x00, 0x01, 0x02, 0x99])
        spy.sockets[0].deliver(message: syncUpdateFrame(data: garbage))
        await waitUntil { manager.replicaIsFailSafe(for: docID) }
        XCTAssertEqual(fireCount, 0, "a fail-safed (non-integrated) update never fires the read-apply observer")
        session?.stop()
    }

    /// C3: the Profile toggle writes `LiveCollaborationPreference.key` and nothing else —
    /// the manager must observe the flip mid-session because `featureEnabled` is a live
    /// closure evaluated on every `availability` read, not a captured value. If someone
    /// "optimizes" it into a stored Bool, this fails and the toggle silently stops working
    /// until the next app launch.
    func testAvailabilityTracksTheLivePreferenceFlagMidSession() {
        let suiteName = "DocumentCollaborationManagerTests.pref.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let spy = SocketFactorySpy()
        let manager = DocumentCollaborationManager(
            serverBaseURL: baseURL,
            cookieProvider: { [] },
            featureEnabled: { LiveCollaborationPreference.isEnabled(defaults) },
            isOffline: { false },
            serverConfigProvider: { nil },
            socketFactory: spy.factory)
        manager.serverSupportsLiveCollaboration = true

        XCTAssertEqual(manager.availability, .featureDisabled, "unset flag ⇒ off (the default)")
        defaults.set(true, forKey: LiveCollaborationPreference.key)
        XCTAssertEqual(manager.availability, .available, "the flip is visible with no manager rebuild")
        defaults.set(false, forKey: LiveCollaborationPreference.key)
        XCTAssertEqual(manager.availability, .featureDisabled, "and turning it off is too")
    }

    /// The observer's lifecycle is tied to the per-document ENTRY, not the bridge: it is
    /// dropped when the document is torn down after linger and must be RE-REGISTERED when the
    /// document is reopened. The `LiveEditingBridge` (held in `EditorView.@State`) outlives a
    /// teardown, and its init does NOT register — the view re-registers on every session
    /// (re)acquisition. This pins that contract: teardown clears the observer, a bare reopen
    /// therefore fires nothing (the stale-baseline race the synchronous observer exists to
    /// close), and re-registration on reopen restores the synchronous read-apply.
    func testReplicaObserverIsClearedOnTeardownAndRestoredByReRegistrationOnReopen() async {
        let spy = SocketFactorySpy()
        let manager = makeManager(linger: 0.05, spy: spy)
        _ = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        var fireCount = 0
        manager.setReplicaObserver({ fireCount += 1 }, for: docID)
        let update = MarkdownYjs.encode(markdown: "# Title\n\nBody", clientID: 1)
        spy.sockets[0].deliver(message: syncStep2Frame(data: update))
        await waitUntil { manager.replicaVersion(for: docID) == 1 }
        XCTAssertEqual(fireCount, 1, "the observer fires while registered and the entry is live")

        // Tear the document down after linger — the entry (and its observer) is dropped.
        manager.release(docID)
        await waitUntil { manager.activeDocumentCount == 0 }

        // Reopen: a fresh entry+session is acquired for the SAME document, but WITHOUT the view
        // re-registering the observer. An inbound update integrates and bumps the version, yet
        // fires nothing — this is exactly the gap that reopened the race before the fix.
        _ = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 2 }
        spy.sockets[1].deliver(message: syncStep2Frame(data: update))
        await waitUntil { manager.replicaVersion(for: docID) == 1 }
        XCTAssertEqual(fireCount, 1, "teardown cleared the observer; a bare reopen fires nothing")

        // The view re-registers on acquisition (`LiveEditingBridge.registerReplicaObserver`) —
        // model that, and the synchronous read-apply is restored for the reopened document.
        manager.setReplicaObserver({ fireCount += 1 }, for: docID)
        spy.sockets[1].deliver(message: syncStep2Frame(data: update))
        await waitUntil { manager.replicaVersion(for: docID) == 2 }
        XCTAssertEqual(fireCount, 2, "re-registering on reopen restores the synchronous observer")

        manager.release(docID)
    }

    func testMalformedUpdateSetsFailSafeStopsProjectingButStillSignals() async {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        // Truncated mid-varint: 0x00 clients of structs, then a delete-set client
        // count (1) and client id (2) whose range count (0x99) demands a
        // continuation byte the buffer never supplies — decode throws.
        let garbage = Data([0x00, 0x01, 0x02, 0x99])
        spy.sockets[0].deliver(message: syncUpdateFrame(data: garbage))

        await waitUntil { manager.remoteChangeToken(for: docID) == 1 }
        await waitUntil { manager.replicaIsFailSafe(for: docID) }
        XCTAssertNil(manager.projectedReplica(for: docID, interlinkingOrigin: nil))

        // A second, real update after failSafe must NOT resurrect projection.
        let update = MarkdownYjs.encode(markdown: "# Title\n\nBody", clientID: 1)
        spy.sockets[0].deliver(message: syncUpdateFrame(data: update))
        await waitUntil { manager.remoteChangeToken(for: docID) == 2 }
        XCTAssertTrue(manager.replicaIsFailSafe(for: docID))
        XCTAssertNil(manager.projectedReplica(for: docID, interlinkingOrigin: nil))
        session?.stop()
    }

    func testDeeplyNestedAnyUpdateFailsSafeInsteadOfCrashingTheProcess() async {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        // A hostile peer's frame: one ContentAny value that is 20k nested
        // single-element arrays. `readAny` recurses per level, so without its
        // depth cap this overflows the stack — and a stack overflow is a machine
        // fault, not an error, so `applyReplicaUpdate`'s fail-safe `catch` could
        // not contain it and the whole app would die on a peer's say-so. Reaching
        // the assertions below at all is the regression test; fail-safe latching
        // proves the throw lands where every other malformed frame lands. A
        // regression reads as "Restarting after unexpected exit" (a process
        // crash), NOT a normal failure — don't misfile it as the worktree flake.
        spy.sockets[0].deliver(message: syncUpdateFrame(data: NestedAnyFixtures.contentAnyUpdate(depth: 20_000)))

        await waitUntil { manager.remoteChangeToken(for: docID) == 1 }
        await waitUntil { manager.replicaIsFailSafe(for: docID) }
        XCTAssertNil(manager.projectedReplica(for: docID, interlinkingOrigin: nil))
        session?.stop()
    }

    func testPendingStructsSuppressProjection() async throws {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        // `Y.mergeUpdates` output where a dropped middle update leaves a `Skip`
        // (the only realistic source of Skips, per docs/architecture.md): the
        // third block's container item has its `origin` inside the gap and can
        // never integrate, so it stays in `pendingStructs` forever. Copied from
        // `YBlockProjectionOracleTests.mergedWithDroppedMiddleHex` (Fixture 4;
        // see that file's header comment for the regeneration script).
        let mergedWithDroppedMiddleHex =
            "0112010007010e646f63756d656e742d73746f7265030a626c6f636b47726f757007000100030e626c6f636b436f6e7461696e6572070001010309706172616772617068070001020604000103056669727374280001020f6261636b67726f756e64436f6c6f7201770764656661756c74280001020974657874436f6c6f7201770764656661756c74280001020d74657874416c69676e6d656e740177046c6566742800010102696401772431313131313131312d313131312d343131312d383131312d3131313131313131313131310a1787010d030e626c6f636b436f6e7461696e6572070001240309706172616772617068070001250604000126057468697264280001250f6261636b67726f756e64436f6c6f7201770764656661756c74280001250974657874436f6c6f7201770764656661756c74280001250d74657874416c69676e6d656e740177046c6566742800012402696401772433333333333333332d333333332d343333332d383333332d33333333333333333333333300"
        // As a `.step2`, `onInitialSync` fires ⇒ `initialSyncApplied` is set, so the
        // *only* thing suppressing projection here is the unintegrated pending struct.
        spy.sockets[0].deliver(message: syncStep2Frame(data: Data(hex: mergedWithDroppedMiddleHex)))

        await waitUntil { manager.replicaVersion(for: docID) == 1 }
        XCTAssertFalse(manager.replicaIsFailSafe(for: docID))
        XCTAssertNil(
            manager.projectedReplica(for: docID, interlinkingOrigin: nil), "pendingStructs must suppress projection")
        session?.stop()
    }

    // MARK: - write-eligibility gate (C2a: hasPendingStructs + canWriteReplica)

    func testHasPendingStructsTrueForUnknownDocument() {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        // No entry at all for this document — nothing writable.
        XCTAssertTrue(manager.hasPendingStructs(for: docID))
    }

    func testHasPendingStructsFalseAfterCleanInitialSync() async throws {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }
        XCTAssertTrue(manager.hasPendingStructs(for: docID), "no replica yet")

        let update = MarkdownYjs.encode(markdown: "# Title\n\nBody", clientID: 1)
        spy.sockets[0].deliver(message: syncStep2Frame(data: update))

        await waitUntil { manager.replicaVersion(for: docID) == 1 }
        XCTAssertFalse(manager.hasPendingStructs(for: docID))
        session?.stop()
    }

    func testHasPendingStructsTrueWhilePendingStructsExist() async throws {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        // Same `Y.mergeUpdates`-with-a-dropped-middle-update fixture as
        // `testPendingStructsSuppressProjection`: the third block's container
        // item can never integrate and stays in `pendingStructs` forever.
        let mergedWithDroppedMiddleHex =
            "0112010007010e646f63756d656e742d73746f7265030a626c6f636b47726f757007000100030e626c6f636b436f6e7461696e6572070001010309706172616772617068070001020604000103056669727374280001020f6261636b67726f756e64436f6c6f7201770764656661756c74280001020974657874436f6c6f7201770764656661756c74280001020d74657874416c69676e6d656e740177046c6566742800010102696401772431313131313131312d313131312d343131312d383131312d3131313131313131313131310a1787010d030e626c6f636b436f6e7461696e6572070001240309706172616772617068070001250604000126057468697264280001250f6261636b67726f756e64436f6c6f7201770764656661756c74280001250974657874436f6c6f7201770764656661756c74280001250d74657874416c69676e6d656e740177046c6566742800012402696401772433333333333333332d333333332d343333332d383333332d33333333333333333333333300"
        spy.sockets[0].deliver(message: syncStep2Frame(data: Data(hex: mergedWithDroppedMiddleHex)))

        await waitUntil { manager.replicaVersion(for: docID) == 1 }
        XCTAssertFalse(manager.replicaIsFailSafe(for: docID))
        XCTAssertTrue(manager.hasPendingStructs(for: docID), "an unintegrated dependency must read as pending")
        session?.stop()
    }

    func testHasPendingStructsTrueAfterFailSafeLatches() async {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        let garbage = Data([0x00, 0x01, 0x02, 0x99])
        spy.sockets[0].deliver(message: syncUpdateFrame(data: garbage))
        await waitUntil { manager.replicaIsFailSafe(for: docID) }

        // A failed decode/apply destroys the replica — nothing writable.
        XCTAssertTrue(manager.hasPendingStructs(for: docID))
        session?.stop()
    }

    func testHasPendingStructsTrueAfterTeardown() async {
        let spy = SocketFactorySpy()
        let manager = makeManager(linger: 0.05, spy: spy)
        _ = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        let update = MarkdownYjs.encode(markdown: "# Title\n\nBody", clientID: 1)
        spy.sockets[0].deliver(message: syncStep2Frame(data: update))
        await waitUntil { manager.replicaVersion(for: docID) == 1 }
        XCTAssertFalse(manager.hasPendingStructs(for: docID))

        manager.release(docID)
        await waitUntil { manager.activeDocumentCount == 0 }
        XCTAssertTrue(manager.hasPendingStructs(for: docID))
    }

    func testTeardownDestroysReplicaAndResetsVersion() async {
        let spy = SocketFactorySpy()
        let manager = makeManager(linger: 0.05, spy: spy)
        _ = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        let update = MarkdownYjs.encode(markdown: "# Title\n\nBody", clientID: 1)
        spy.sockets[0].deliver(message: syncStep2Frame(data: update))
        await waitUntil { manager.replicaVersion(for: docID) == 1 }

        manager.release(docID)
        await waitUntil { manager.activeDocumentCount == 0 }
        XCTAssertEqual(manager.replicaVersion(for: docID), 0)
        XCTAssertFalse(manager.replicaIsFailSafe(for: docID))
        XCTAssertNil(manager.projectedReplica(for: docID, interlinkingOrigin: nil))
    }

    // MARK: - local edit write path (C2a: applyLocalEdit + broadcast + echo suppression)

    /// The three base props every text block carries, in BlockNote order (mirrors
    /// `BlockNoteWriteOracleTests`).
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

    /// Seed the manager's replica from a known block list by delivering it as an
    /// inbound `.sync`/`.update` frame through the real socket → session → manager
    /// path (so the replica goes through the same `applyReplicaUpdate` the C1 tests
    /// exercise), then wait until it is writable. Returns the wire seed bytes so a
    /// second replica can be built from the same base for a convergence check.
    @discardableResult
    private func seedWritableReplica(
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

    func testApplyLocalEditReturnsUpdateBroadcastsAndConverges() async throws {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        let base = [para("hello", id: blockID)]
        let seed = await seedWritableReplica(manager, socket: spy.sockets[0], blocks: base)
        XCTAssertNotNil(manager.projectedReplica(for: docID, interlinkingOrigin: nil))
        let framesBefore = spy.sockets[0].sentFrames.count

        let edited = [para("heXllo", id: blockID)]
        let update = try manager.applyLocalEdit(old: base, new: edited, for: docID)
        XCTAssertFalse(update.isEmpty, "a local edit must produce non-empty update bytes")

        // Convergence: a second fresh replica seeded from the same base + our update
        // must project to `edited` at the document level.
        let second = YDoc(clientID: 7)
        try second.applyUpdate(try YUpdateDecoder.decode(seed))
        try second.applyUpdate(try YUpdateDecoder.decode(update))
        let projected = YBlockProjection.project(second).blocks
        XCTAssertEqual(projected.map(\.id), edited.map(\.id))
        XCTAssertEqual(projected.map(\.node), edited.map(\.node))
        XCTAssertEqual(projected.map(\.runs), edited.map(\.runs))
        second.destroy()

        // The session broadcast exactly those bytes as a `.sync`/`.update` frame.
        await waitUntil { spy.sockets[0].sentFrames.count == framesBefore + 1 }
        let frame = try HocuspocusMessage(decoding: spy.sockets[0].sentFrames.last!)
        XCTAssertEqual(frame.knownType, .sync)
        let sync = try SyncMessage(decodingPayload: frame.payload)
        XCTAssertEqual(sync.step, .update)
        XCTAssertEqual(sync.data, update, "the broadcast frame must carry exactly the returned update bytes")
        session?.stop()
    }

    func testApplyLocalEditSuppressesLocalEcho() async throws {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        let base = [para("hello", id: blockID)]
        _ = await seedWritableReplica(manager, socket: spy.sockets[0], blocks: base)

        // The inbound remote-change signals the editor observes must NOT move for a
        // local edit — otherwise the editor would try to read-apply its own keystroke.
        let replicaVersion = manager.replicaVersion(for: docID)
        let remoteChange = manager.remoteChangeToken(for: docID)
        XCTAssertEqual(manager.localEditVersion(for: docID), 0)

        _ = try manager.applyLocalEdit(old: base, new: [para("heXllo", id: blockID)], for: docID)

        XCTAssertEqual(manager.replicaVersion(for: docID), replicaVersion, "a local edit must not bump replicaVersion")
        XCTAssertEqual(
            manager.remoteChangeToken(for: docID), remoteChange, "a local edit must not bump remoteChangeToken")
        XCTAssertEqual(manager.localEditVersion(for: docID), 1, "a local edit bumps only localEditVersion")
        session?.stop()
    }

    func testApplyLocalEditThrowsWhenNoReplica() throws {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        // No session, no entry, no replica at all — nothing writable.
        do {
            _ = try manager.applyLocalEdit(old: [], new: [para("x", id: blockID)], for: docID)
            XCTFail("expected notWritable when there is no replica")
        } catch CollaborationWriteError.notWritable {
            // expected
        }
        XCTAssertEqual(manager.localEditVersion(for: docID), 0)
        XCTAssertTrue(spy.sockets.isEmpty)
    }

    func testApplyLocalEditThrowsBeforeInitialSync() async throws {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }
        // Wait for the handshake (the only expected send) to land so the later
        // "no broadcast" check isn't racing it — the handshake goes out
        // asynchronously after the socket is created.
        await waitUntil { spy.sockets[0].sentFrames.count == 1 }
        // A socket is open, but no inbound update has arrived ⇒ no replica ⇒ not writable.
        do {
            _ = try manager.applyLocalEdit(old: [], new: [para("x", id: blockID)], for: docID)
            XCTFail("expected notWritable before the initial sync")
        } catch CollaborationWriteError.notWritable {
            // expected
        }
        XCTAssertEqual(manager.localEditVersion(for: docID), 0)
        await waitAndConfirmNever { spy.sockets[0].sentFrames.count > 1 }
        session?.stop()
    }

    func testApplyLocalEditThrowsAfterFailSafe() async throws {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        // A malformed inbound update latches fail-safe and destroys the replica.
        spy.sockets[0].deliver(message: syncUpdateFrame(data: Data([0x00, 0x01, 0x02, 0x99])))
        await waitUntil { manager.replicaIsFailSafe(for: docID) }

        do {
            _ = try manager.applyLocalEdit(old: [], new: [para("x", id: blockID)], for: docID)
            XCTFail("expected notWritable after fail-safe")
        } catch CollaborationWriteError.notWritable {
            // expected
        }
        XCTAssertEqual(manager.localEditVersion(for: docID), 0)
        session?.stop()
    }

    func testApplyLocalEditWithMismatchedOldLatchesFailSafeAndDoesNotCrash() async throws {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        let base = [para("hi", id: blockID)]  // the real replica text is 2 UTF-16 units
        _ = await seedWritableReplica(manager, socket: spy.sockets[0], blocks: base)
        XCTAssertFalse(manager.replicaIsFailSafe(for: docID))
        let framesBefore = spy.sockets[0].sentFrames.count

        // `old` lies: it over-claims a 20-unit text with no common prefix/suffix vs
        // `new`, so the in-place text replace deletes past the real 2-unit text and
        // `BlockNoteWrite.applyEdit` throws `YIntegrationError` (never traps).
        let lyingOld = [para("zzzzzzzzzzzzzzzzzzzz", id: blockID)]
        let new = [para("q", id: blockID)]
        do {
            _ = try manager.applyLocalEdit(old: lyingOld, new: new, for: docID)
            XCTFail("expected the mismatched old to make BlockNoteWrite.applyEdit throw")
        } catch is CollaborationWriteError {
            XCTFail("expected the underlying integration error to propagate, not notWritable")
        } catch {
            // expected: the underlying YIntegrationError propagated.
        }

        // Fail-safe latched: the replica is torn down and refuses all further writes.
        XCTAssertTrue(manager.replicaIsFailSafe(for: docID))
        XCTAssertNil(manager.projectedReplica(for: docID, interlinkingOrigin: nil))
        XCTAssertTrue(manager.hasPendingStructs(for: docID))
        XCTAssertEqual(manager.localEditVersion(for: docID), 0, "a failed edit must not bump the local-edit counter")
        await waitAndConfirmNever { spy.sockets[0].sentFrames.count > framesBefore }

        // A subsequent edit now refuses with notWritable (the replica is gone).
        do {
            _ = try manager.applyLocalEdit(old: [], new: new, for: docID)
            XCTFail("expected notWritable after the fail-safe latch")
        } catch CollaborationWriteError.notWritable {
            // expected
        }
        session?.stop()
    }

    // MARK: - initial-sync authority move (C2a)

    /// The load-bearing authority move: an inbound `.update` that arrives BEFORE
    /// our own SyncStep1 reply (a peer's incremental edit interleaved ahead of the
    /// initial sync) builds the replica and bumps `replicaVersion`, but must NOT
    /// mark it synced — a replica assembled from a partial update is not the room's
    /// full state, so it stays un-projectable/un-writable/un-snapshottable until the
    /// first `.step2` fires `onInitialSync`.
    func testInboundUpdateBeforeInitialSyncBuildsReplicaButRefusesWrites() async throws {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        let blocks = [para("hi", id: blockID)]
        let update = BlockNoteYjs.encode(blocks, clientID: 1)
        spy.sockets[0].deliver(message: syncUpdateFrame(data: update))
        await waitUntil { manager.replicaVersion(for: docID) == 1 }

        // The replica exists and integrated cleanly (no fail-safe, no pending), but
        // the initial sync has not landed ⇒ every write-eligibility surface refuses.
        XCTAssertFalse(manager.replicaIsFailSafe(for: docID))
        XCTAssertFalse(manager.hasPendingStructs(for: docID), "the early update integrated cleanly")
        XCTAssertNil(manager.projectedReplica(for: docID, interlinkingOrigin: nil), "no projection before the step2")
        XCTAssertNil(manager.encodeSnapshotForSave(for: docID), "no snapshot before the step2")
        do {
            _ = try manager.applyLocalEdit(old: blocks, new: [para("hiX", id: blockID)], for: docID)
            XCTFail("expected notWritable before the initial sync")
        } catch CollaborationWriteError.notWritable {
            // expected
        }

        // The `.step2` reply to our SyncStep1 marks the initial sync applied ⇒ the
        // same replica is now writable/projectable/snapshottable.
        spy.sockets[0].deliver(message: syncStep2Frame(data: update))
        await waitUntil { manager.projectedReplica(for: docID, interlinkingOrigin: nil) != nil }
        XCTAssertNotNil(manager.encodeSnapshotForSave(for: docID))
        session?.stop()
    }

    /// The impact of the SyncReply(4) routing fix, end to end: a production
    /// Hocuspocus server answers our `Sync`(0)+SyncStep1 with a `SyncReply`(4)+
    /// SyncStep2, not a `Sync`(0)+SyncStep2. Delivering that real reply through the
    /// socket → session → manager path must fire `onInitialSync` and mark the
    /// replica synced, so `canWriteReplica` flips true — projection, the save
    /// snapshot, and `applyLocalEdit` all become available. Before the fix the
    /// type-4 frame was dropped, so the replica never became writable.
    func testSyncReplyStep2SeedsWritableReplicaLikeSyncStep2() async throws {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }
        XCTAssertNil(manager.projectedReplica(for: docID, interlinkingOrigin: nil))
        XCTAssertNil(manager.encodeSnapshotForSave(for: docID))

        let base = [para("hello", id: blockID)]
        spy.sockets[0].deliver(message: syncReplyStep2Frame(data: BlockNoteYjs.encode(base, clientID: 1)))
        await waitUntil { manager.replicaVersion(for: docID) == 1 }

        // canWriteReplica is now true across every write-eligibility surface.
        XCTAssertNotNil(
            manager.projectedReplica(for: docID, interlinkingOrigin: nil),
            "the SyncReply(4) initial sync makes the replica projectable")
        XCTAssertNotNil(
            manager.encodeSnapshotForSave(for: docID), "the SyncReply(4) initial sync makes the save snapshot available"
        )
        let update = try manager.applyLocalEdit(old: base, new: [para("heXllo", id: blockID)], for: docID)
        XCTAssertFalse(update.isEmpty, "applyLocalEdit succeeds once the SyncReply-seeded replica is writable")
        XCTAssertEqual(manager.localEditVersion(for: docID), 1)
        session?.stop()
    }

    // MARK: - snapshot for save (C2a: encodeSnapshotForSave gate)

    func testEncodeSnapshotForSaveNilForUnknownDocumentAndBeforeInitialSync() async {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        // An unknown document has no entry at all.
        XCTAssertNil(manager.encodeSnapshotForSave(for: docID))

        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }
        // A socket is open, but no inbound frame has arrived ⇒ no replica ⇒ no snapshot.
        XCTAssertNil(manager.encodeSnapshotForSave(for: docID), "no replica yet ⇒ no snapshot")
        session?.stop()
    }

    func testEncodeSnapshotForSaveNilWhilePendingStructs() async throws {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        // Same `Y.mergeUpdates`-with-a-dropped-middle fixture: an unintegrated
        // dependency stays in `pendingStructs`, so the replica is not safe to
        // snapshot even though the initial sync (a `.step2`) landed.
        let mergedWithDroppedMiddleHex =
            "0112010007010e646f63756d656e742d73746f7265030a626c6f636b47726f757007000100030e626c6f636b436f6e7461696e6572070001010309706172616772617068070001020604000103056669727374280001020f6261636b67726f756e64436f6c6f7201770764656661756c74280001020974657874436f6c6f7201770764656661756c74280001020d74657874416c69676e6d656e740177046c6566742800010102696401772431313131313131312d313131312d343131312d383131312d3131313131313131313131310a1787010d030e626c6f636b436f6e7461696e6572070001240309706172616772617068070001250604000126057468697264280001250f6261636b67726f756e64436f6c6f7201770764656661756c74280001250974657874436f6c6f7201770764656661756c74280001250d74657874416c69676e6d656e740177046c6566742800012402696401772433333333333333332d333333332d343333332d383333332d33333333333333333333333300"
        spy.sockets[0].deliver(message: syncStep2Frame(data: Data(hex: mergedWithDroppedMiddleHex)))

        await waitUntil { manager.replicaVersion(for: docID) == 1 }
        XCTAssertTrue(manager.hasPendingStructs(for: docID))
        XCTAssertNil(manager.encodeSnapshotForSave(for: docID), "pending structs must suppress the snapshot")
        session?.stop()
    }

    func testEncodeSnapshotForSaveNilAfterFailSafe() async {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        spy.sockets[0].deliver(message: syncStep2Frame(data: Data([0x00, 0x01, 0x02, 0x99])))
        await waitUntil { manager.replicaIsFailSafe(for: docID) }
        XCTAssertNil(manager.encodeSnapshotForSave(for: docID), "a fail-safed replica must not be snapshotted")
        session?.stop()
    }

    func testEncodeSnapshotForSaveReturnsFullSnapshotThatReproducesTheDocument() async throws {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        let blocks = [para("hello", id: blockID)]
        spy.sockets[0].deliver(message: syncStep2Frame(data: BlockNoteYjs.encode(blocks, clientID: 1)))
        await waitUntil { manager.projectedReplica(for: docID, interlinkingOrigin: nil) != nil }

        let snapshot = try XCTUnwrap(manager.encodeSnapshotForSave(for: docID))
        XCTAssertFalse(snapshot.isEmpty, "a synced replica must produce a non-empty full snapshot")

        // The full snapshot applied to a fresh replica reproduces the document.
        let fresh = YDoc(clientID: 99)
        try fresh.applyUpdate(try YUpdateDecoder.decode(snapshot))
        let projected = YBlockProjection.project(fresh).blocks
        XCTAssertEqual(projected.map(\.id), blocks.map(\.id))
        XCTAssertEqual(projected.map(\.node), blocks.map(\.node))
        XCTAssertEqual(projected.map(\.runs), blocks.map(\.runs))
        fresh.destroy()
        session?.stop()
    }

    // MARK: - state reply + handshake re-offer (C2a: stateReply, currentStateVector)

    /// A peer's SyncStep1 (their state vector) is answered with a `.step2` diff of
    /// exactly what they lack, and applying that reply converges the peer onto our
    /// state — this is how our local edits are re-offered on (re)connect.
    func testStateReplyReturnsOnlyWhatPeerLacksAndConverges() async throws {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        // Seed A (the manager's replica) and B (a plain oracle YDoc) from the SAME
        // base, so they share those structs exactly.
        let secondBlockID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let base = [para("shared", id: blockID)]
        let seed = await seedWritableReplica(manager, socket: spy.sockets[0], blocks: base)
        let peer = YDoc(clientID: 9)
        try peer.applyUpdate(try YUpdateDecoder.decode(seed))

        // A diverges by a local edit B does not have yet (a pure block insert,
        // authored by A's replica client id).
        let edited = [para("shared", id: blockID), para("added", id: secondBlockID)]
        _ = try manager.applyLocalEdit(old: base, new: edited, for: docID)

        // B asks A for its state (a SyncStep1 carrying B's state vector); A replies
        // with a `.step2` diff of only what B lacks (A's insert).
        let framesBefore = spy.sockets[0].sentFrames.count
        spy.sockets[0].deliver(message: step1Frame(stateVector: YStateEncoder.encodeStateVector(peer)))
        await waitUntil { spy.sockets[0].sentFrames.count > framesBefore }
        let reply = try XCTUnwrap(
            spy.sockets[0].sentFrames.compactMap { frame -> Data? in
                guard let message = try? HocuspocusMessage(decoding: frame), message.knownType == .sync,
                    let sync = try? SyncMessage(decodingPayload: message.payload), sync.step == .step2
                else { return nil }
                return sync.data
            }.last, "A must answer B's step1 with a step2 diff")

        // The reply is a genuine diff, not a whole snapshot: it is smaller than A's
        // full snapshot of the same document.
        let fullSnapshot = try XCTUnwrap(manager.encodeSnapshotForSave(for: docID))
        XCTAssertLessThan(reply.count, fullSnapshot.count, "a step2 diff carries less than the full state")

        // Applying the reply to B converges B onto A's document.
        try peer.applyUpdate(try YUpdateDecoder.decode(reply))
        let converged = YBlockProjection.project(peer).blocks
        XCTAssertEqual(converged.map(\.id), edited.map(\.id))
        XCTAssertEqual(converged.map(\.node), edited.map(\.node))
        XCTAssertEqual(converged.map(\.runs), edited.map(\.runs))
        peer.destroy()
        session?.stop()
    }

    /// The first session handshakes with the empty state vector (no replica yet),
    /// but after an initial sync a reconnect rebuilds the session whose SyncStep1
    /// now carries the replica's real state vector — so the relay replies with only
    /// what we lack and we re-offer our own accumulated state.
    func testReconnectHandshakeReOffersReplicaStateVector() async throws {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        _ = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 && spy.sockets[0].sentFrames.count == 1 }

        // First handshake: the signal-only empty state vector (no replica yet).
        let firstHandshake = try SyncMessage(
            decodingPayload: HocuspocusMessage(decoding: spy.sockets[0].sentFrames[0]).payload)
        XCTAssertEqual(firstHandshake.step, .step1)
        XCTAssertEqual(firstHandshake.data, Data([0x00]), "no replica yet ⇒ empty state vector")

        // Land an initial sync.
        let blocks = [para("hello", id: blockID)]
        spy.sockets[0].deliver(message: syncStep2Frame(data: BlockNoteYjs.encode(blocks, clientID: 1)))
        await waitUntil { manager.projectedReplica(for: docID, interlinkingOrigin: nil) != nil }

        // Reconnect rebuilds the session; its handshake re-offers the replica's
        // state vector, which equals a fresh mirror of the replica's snapshot.
        manager.reconnect()
        await waitUntil { spy.sockets.count == 2 && spy.sockets[1].sentFrames.count >= 1 }
        let reconnectHandshake = try SyncMessage(
            decodingPayload: HocuspocusMessage(decoding: spy.sockets[1].sentFrames[0]).payload)
        XCTAssertEqual(reconnectHandshake.step, .step1)
        XCTAssertNotEqual(
            reconnectHandshake.data, Data([0x00]), "the rebuilt session offers the replica's state vector")

        let snapshot = try XCTUnwrap(manager.encodeSnapshotForSave(for: docID))
        let mirror = YDoc(clientID: 5)
        try mirror.applyUpdate(try YUpdateDecoder.decode(snapshot))
        XCTAssertEqual(
            reconnectHandshake.data, YStateEncoder.encodeStateVector(mirror),
            "the handshake state vector is exactly the replica's")
        mirror.destroy()
    }

    // MARK: - server-support learning

    func testRefreshServerSupportReadsCollaborationWsUrl() async {
        let spy = SocketFactorySpy()
        let manager = makeManager(
            server: false, config: ServerConfig(collaborationWsUrl: "wss://docs.example.org/collaboration/ws/"),
            spy: spy)
        await manager.refreshServerSupport()
        XCTAssertTrue(manager.serverSupportsLiveCollaboration)
    }

    func testRefreshServerSupportFalseWhenConfigAbsent() async {
        let spy = SocketFactorySpy()
        let manager = makeManager(server: true, config: nil, spy: spy)
        await manager.refreshServerSupport()
        XCTAssertFalse(manager.serverSupportsLiveCollaboration)
    }

    // MARK: - availability gating

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

    // MARK: - creation, reuse, refcount

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

    // MARK: - release + linger teardown

    func testReleaseLingersThenTearsDown() async {
        let spy = SocketFactorySpy()
        let manager = makeManager(linger: 0.05, spy: spy)
        _ = manager.session(for: docID)
        manager.release(docID)
        // Still present immediately after release (retained through the linger),
        // gone once the linger elapses.
        XCTAssertEqual(manager.activeDocumentCount, 1)
        await waitUntil { manager.activeDocumentCount == 0 }
        await waitUntil { spy.sockets[0].cancelCloseCode == .goingAway }
    }

    func testSessionRequestWhileSuspendedDoesNotOpenSocket() async {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        _ = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }
        manager.suspend()
        await waitUntil { spy.sockets[0].cancelCloseCode == .goingAway }

        // A request while backgrounded must not reopen a socket.
        XCTAssertNil(manager.session(for: docID))
        await waitAndConfirmNever { spy.sockets.count > 1 }
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

    // MARK: - suspend / resume / reconnect

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

    func testSuspendDuringLingerDropsIdleEntry() async {
        let spy = SocketFactorySpy()
        let manager = makeManager(linger: 0.5, spy: spy)
        _ = manager.session(for: docID)  // refCount 1
        manager.release(docID)  // refCount 0, linger scheduled (0.5s)
        manager.suspend()  // within the linger window
        await waitUntil { spy.sockets[0].cancelCloseCode == .goingAway }
        // The idle entry is dropped, not stranded as a zombie.
        XCTAssertEqual(manager.activeDocumentCount, 0)
        manager.resume()
        await waitAndConfirmNever { manager.activeDocumentCount > 0 || spy.sockets.count > 1 }
    }

    func testReconnectIgnoredWhileSuspended() async {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        _ = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }
        manager.suspend()
        await waitUntil { spy.sockets[0].cancelCloseCode == .goingAway }

        manager.reconnect()  // backgrounded — must not reopen a socket
        await waitAndConfirmNever { spy.sockets.count > 1 }
    }

    func testRebuildWhileNoLongerAvailableTearsDownWithoutReopening() async {
        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        _ = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        manager.serverSupportsLiveCollaboration = false  // availability dropped
        manager.reconnect()
        await waitUntil { spy.sockets[0].cancelCloseCode == .goingAway }
        await waitAndConfirmNever { spy.sockets.count > 1 }
    }
}
