import XCTest

@testable import Schrift

/// Slice B: the production open route types into a durable replica behind the
/// default-off switch, saves through the coordinator and refuses stale accounts.
@MainActor
final class NativeEditorActivationTests: DocumentEngineTestCase {
    private let owner = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    // MARK: - Open

    func testSwitchOnSeedsAReplicaWritesTheMarkerAndEnablesTyping() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let server = ServerStub(owner: owner, state: seedState())
        server.install()
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
        guard case .native(let session) = open.route else { return XCTFail("expected a native session") }
        XCTAssertNotNil(session.input, "an eligible document must be typeable")
        let scope = ReplicaScope(
            serverOrigin: env.model.client.serverOrigin, ownerUserID: owner, org: "docs",
            documentID: env.model.documentID)
        XCTAssertEqual(session.scope, scope)
        XCTAssertEqual(env.model.saveCoordinator.nativeOwnership(documentID: env.model.documentID), .owned(scope))
        XCTAssertEqual(try env.replicaStore.manifest(for: scope)?.revision, 0)
        XCTAssertFalse(env.model.hasLoadedContent, "classic loading must not run")
        XCTAssertFalse(open.isPreservedReadOnly)
    }

    /// PR08b: the restore runs on the replica session, off the main actor. An
    /// open closed meanwhile drops (and closes) what it restored: the route
    /// never shows a session for a gone open.
    func testAnOpenClosedDuringTheRestoreDropsTheRestoredSession() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        _ = try seedReplica(env, typed: "x")
        let attach = Latch()
        let open = NativeEditorOpen(
            preference: { true }, replicaHooks: DocumentReplicaSession.Hooks(onReplicaWork: { attach.pass() }))
        let opening = Task { await open.open(viewModel: env.model, isOffline: true, canUpdate: true) }
        await waitUntil { attach.waiting == 1 }
        open.close()
        attach.open()
        await opening.value
        guard case .loading = open.route else { return XCTFail("a closed open shows nothing") }
        XCTAssertFalse(open.isPreservedReadOnly)
    }

    func testOwnedReplicaRestoresOfflineFirstThenIntegratesTheServerState() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let scope = try seedReplica(env, typed: "x")
        let peer = try makeDoc(clientID: 7)
        defer { peer.destroy() }
        _ = try BlockNoteWriter(doc: peer).replaceText(block: Self.thirdID, range: 0..<0, with: "server ")
        let server = ServerStub(owner: owner, state: try YStateEncoder.encodeStateAsUpdate(peer))
        let gate = MockURLProtocol.ResponseGate()
        server.stateGate = gate
        server.install()
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        let opening = Task { await open.open(viewModel: env.model, isOffline: false, canUpdate: true) }
        await waitUntil { server.log.count(ofMethod: "GET", urlContaining: "/collaboration/ydoc/") == 1 }
        // Before the server answers, the durable replica is already on screen and typeable.
        guard case .native(let session) = open.route else { return XCTFail("restore must not wait for the server") }
        XCTAssertNotNil(session.input)
        XCTAssertTrue(text(session, block: 0).hasPrefix("x"))
        gate.open()
        await opening.value
        XCTAssertTrue(text(session, block: 0).hasPrefix("x"), "the local edit survives integration")
        XCTAssertTrue(text(session, block: 2).hasPrefix("server "))
        let manifest = try XCTUnwrap(env.replicaStore.manifest(for: scope))
        XCTAssertEqual(manifest.revision, 2, "the server state is journaled into the same owner")
        XCTAssertEqual(manifest.outbox, [1], "a remote integration never enters the local outbox")
    }

    func testRichDocumentAndReaderStayInTheReadOnlyViewWithoutAReplica() async throws {
        for (rich, canUpdate) in [(true, true), (false, false)] {
            let env = makeEnvironment()
            defer { env.clean() }
            var blocks = Self.seedBlocks()
            if rich { blocks.insert(BlockNoteBlock(node: "table", props: [], runs: [], id: "table"), at: 1) }
            ServerStub(owner: owner, state: BlockNoteYjs.encode(blocks, clientID: Self.seedClientID)).install()
            let open = NativeEditorOpen(preference: { true })
            await open.open(viewModel: env.model, isOffline: false, canUpdate: canUpdate)
            guard case .native(let session) = open.route else { return XCTFail("expected the PR01 reader") }
            XCTAssertNil(session.input)
            XCTAssertNil(session.scope)
            XCTAssertEqual(env.model.saveCoordinator.nativeOwnership(documentID: env.model.documentID), .none)
            open.close()
        }
    }

    func testSwitchOffLeavesTheClassicRouteUnchanged() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        ServerStub(owner: owner, state: seedState()).install()
        let open = NativeEditorOpen(preference: { false })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
        guard case .classic = open.route else { return XCTFail("switch off must keep classic") }
        XCTAssertNil(MockURLProtocol.lastRequest, "switch off must not fetch")
        XCTAssertEqual(env.model.saveCoordinator.nativeOwnership(documentID: env.model.documentID), .none)
    }

    func testUnsyncedClassicDraftKeepsTheDocumentClassic() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        ServerStub(owner: owner, state: seedState()).install()
        PendingDraftStore(userDefaults: env.defaults).save(
            PendingDraft(documentID: env.model.documentID, title: "Local", markdown: "Unsynced", updatedAt: Date()))
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
        guard case .classic = open.route else { return XCTFail("a classic draft must stay classic until it syncs") }
        XCTAssertNil(MockURLProtocol.lastRequest)
        XCTAssertEqual(env.model.saveCoordinator.nativeOwnership(documentID: env.model.documentID), .none)
    }

    func testLiveOwnerKeepsTheRestoredReplicaReadOnly() async throws {
        let env = makeEnvironment(isLiveHeld: { _ in true })
        defer { env.clean() }
        try seedReplica(env, typed: "x")
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: true, canUpdate: true)
        guard case .native(let session) = open.route else { return XCTFail("owned document must restore") }
        XCTAssertNil(session.input, "a native session never authors while the live owner holds the document")
    }

    // MARK: - Saves

    func testTypingSchedulesADebouncedSaveThatIsSentAndAcknowledged() async throws {
        // PR08b: the save is scheduled when the append's result arrives, an await
        // away; a zero debounce would already have fired by the assertion below.
        let env = makeEnvironment(autosaveInterval: .milliseconds(300))
        defer { env.clean() }
        let server = ServerStub(owner: owner, state: seedState())
        server.install()
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
        guard case .native(let session) = open.route, let scope = session.scope else {
            return XCTFail("expected a typeable session")
        }
        XCTAssertTrue(try XCTUnwrap(session.input).replace(range: NSRange(location: 0, length: 0), with: "x"))
        await session.settle()
        XCTAssertTrue(session.hasPendingSave, "journaled but not handed over: saved on this device")
        let journaled = try XCTUnwrap(env.replicaStore.outbox(for: scope)).updates
        XCTAssertEqual(server.log.count(ofMethod: "PATCH"), 0, "no request before the debounce fires")
        await waitUntil { self.isSaved(env.model.saveCoordinator.state(for: env.model.documentID)) }
        XCTAssertFalse(session.hasPendingSave)
        XCTAssertEqual(server.patchedUpdates, journaled, "the journaled bytes are sent verbatim")
        XCTAssertNil(try env.replicaStore.outbox(for: scope), "the server's confirmation is acknowledged durably")
        XCTAssertNil(env.model.saveCoordinator.storedDraft(documentID: env.model.documentID))
        XCTAssertEqual(server.log.count(ofMethod: "PATCH", urlContaining: "/content/"), 0)
        XCTAssertEqual(server.titles, ["Fresh server title"], "the title native saves send is the server's")
    }

    func testCloseFlushesTheDebouncedSave() async throws {
        let env = makeEnvironment()  // the production 10 s cadence: only the close can send
        defer { env.clean() }
        let server = ServerStub(owner: owner, state: seedState())
        server.install()
        let open = NativeEditorOpen(preference: { true })
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
        guard case .native(let session) = open.route else { return XCTFail("expected a typeable session") }
        XCTAssertTrue(try XCTUnwrap(session.input).replace(range: NSRange(location: 0, length: 0), with: "x"))
        await session.settle()
        open.close()
        XCTAssertNotNil(env.model.saveCoordinator.pendingSave(documentID: env.model.documentID))
        await waitUntil { self.isSaved(env.model.saveCoordinator.state(for: env.model.documentID)) }
        XCTAssertEqual(server.patchedUpdates.count, 1)
    }

    func testOfflineTypingSurvivesRelaunchAndIsSentOnReconnect() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let server = ServerStub(owner: owner, state: seedState())
        server.install()
        let first = NativeEditorOpen(preference: { true })
        await first.open(viewModel: env.model, isOffline: false, canUpdate: true)
        first.close()
        let scope = try XCTUnwrap(env.model.saveCoordinator.nativeOwnership(documentID: env.model.documentID).scope)

        // Offline: the owned replica restores and types with no request at all.
        server.isOffline = true
        let requests = server.log.methods.count
        let offline = NativeEditorOpen(preference: { true })
        await offline.open(viewModel: env.model, isOffline: true, canUpdate: true)
        guard case .native(let session) = offline.route else { return XCTFail("owned replica must restore offline") }
        XCTAssertEqual(server.log.methods.count, requests, "an offline open never fetches")
        XCTAssertTrue(try XCTUnwrap(session.input).replace(range: NSRange(location: 0, length: 0), with: "off"))
        await session.settle()
        offline.close()
        await waitUntil { self.isPendingSync(env.model.saveCoordinator.state(for: env.model.documentID)) }
        XCTAssertNotNil(env.model.saveCoordinator.storedDraft(documentID: env.model.documentID)?.replica)

        // Relaunch: a new coordinator over the same disk restores the edit.
        let relaunched = env.relaunch()
        let reopened = NativeEditorOpen(preference: { true })
        defer { reopened.close() }
        await reopened.open(viewModel: relaunched, isOffline: true, canUpdate: true)
        guard case .native(let restored) = reopened.route else { return XCTFail("relaunch must restore") }
        XCTAssertTrue(text(restored, block: 0).hasPrefix("off"))
        XCTAssertNotNil(restored.input)

        // Reconnect: the replay pass sends the raw bytes and the fetch integrates.
        server.isOffline = false
        await relaunched.saveCoordinator.syncPendingDrafts()
        await waitUntil { self.isSaved(relaunched.saveCoordinator.state(for: relaunched.documentID)) }
        XCTAssertNil(try env.replicaStore.outbox(for: scope))
        XCTAssertNil(relaunched.saveCoordinator.storedDraft(documentID: relaunched.documentID))
        await reopened.refresh(viewModel: relaunched, isOffline: false)
        XCTAssertTrue(text(restored, block: 0).hasPrefix("off"))
        // The server holds nothing the replica lacks: integrating it journals nothing (PR09a).
        XCTAssertEqual(try XCTUnwrap(env.replicaStore.manifest(for: scope)).revision, 1)
    }

    func testOutboxLeftByAnEndedProcessIsHandedOverOnReopen() async throws {
        let env = makeEnvironment(autosaveInterval: .zero)
        defer { env.clean() }
        let scope = try seedReplica(env, typed: "x")  // journaled, never enqueued: no draft
        XCTAssertNil(env.model.saveCoordinator.storedDraft(documentID: env.model.documentID))
        let server = ServerStub(owner: owner, state: seedState())
        server.isOffline = true
        server.install()
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: true, canUpdate: true)
        await waitUntil { self.isPendingSync(env.model.saveCoordinator.state(for: env.model.documentID)) }
        XCTAssertNotNil(env.model.saveCoordinator.storedDraft(documentID: env.model.documentID)?.replica)
        XCTAssertEqual(try env.replicaStore.outbox(for: scope)?.updates.count, 1)
    }

    // MARK: - Sign-in generation guards

    func testAccountSwitchDuringTheRawFetchIsRefused() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let server = ServerStub(owner: owner, state: seedState())
        let gate = MockURLProtocol.ResponseGate()
        server.stateGate = gate
        server.install()
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        let opening = Task { await open.open(viewModel: env.model, isOffline: false, canUpdate: true) }
        await waitUntil { server.log.count(ofMethod: "GET", urlContaining: "/collaboration/ydoc/") == 1 }
        SignedInUserStore(userDefaults: env.defaults).remember(UUID())
        gate.open()
        await opening.value
        guard case .classic = open.route else { return XCTFail("a fetch for the previous account was applied") }
        XCTAssertEqual(env.model.saveCoordinator.nativeOwnership(documentID: env.model.documentID), .none)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.replicaDirectory.path), "no replica was seeded")
    }

    func testSignInChangeDuringIntegrationDropsTheServerState() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let scope = try seedReplica(env, typed: "x")
        let server = ServerStub(owner: owner, state: seedState())
        let gate = MockURLProtocol.ResponseGate()
        server.stateGate = gate
        server.install()
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        let opening = Task { await open.open(viewModel: env.model, isOffline: false, canUpdate: true) }
        await waitUntil { server.log.count(ofMethod: "GET", urlContaining: "/collaboration/ydoc/") == 1 }
        // The view's reaction to `SessionStore.signInGeneration`: close, then reopen.
        open.close()
        SignedInUserStore(userDefaults: env.defaults).remember(UUID())
        gate.open()
        await opening.value
        XCTAssertEqual(try env.replicaStore.manifest(for: scope)?.revision, 1, "nothing integrated after the change")
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
        guard case .preservedUnavailable = open.route else { return XCTFail("the new account must not see it") }
    }

    func testAccountChangeBeforeTheDebouncedSaveRefusesToSend() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let server = ServerStub(owner: owner, state: seedState())
        server.install()
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
        guard case .native(let session) = open.route, let scope = session.scope else {
            return XCTFail("expected a typeable session")
        }
        XCTAssertTrue(try XCTUnwrap(session.input).replace(range: NSRange(location: 0, length: 0), with: "x"))
        await session.settle()
        SignedInUserStore(userDefaults: env.defaults).remember(UUID())
        open.flushPendingSave()
        guard case .failed = env.model.saveCoordinator.state(for: env.model.documentID) else {
            return XCTFail("the refused capture must report a failure, not a save")
        }
        XCTAssertNotNil(session.input?.noticeKey, "authoring stops once the capture is refused")
        XCTAssertNil(env.model.saveCoordinator.pendingSave(documentID: env.model.documentID))
        XCTAssertEqual(server.log.count(ofMethod: "PATCH"), 0)
        XCTAssertEqual(try env.replicaStore.outbox(for: scope)?.updates.count, 1, "the edit stays durable")
    }

    func testCloseDuringReauthenticationKeepsTheJournalForTheReopen() async throws {
        let env = makeEnvironment()  // the production 10 s cadence: only the close flushes
        defer { env.clean() }
        let server = ServerStub(owner: owner, state: seedState())
        server.install()
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
        guard case .native(let session) = open.route, let scope = session.scope else {
            return XCTFail("expected a typeable session")
        }
        XCTAssertTrue(try XCTUnwrap(session.input).replace(range: NSRange(location: 0, length: 0), with: "x"))
        await session.settle()
        // `noteSessionCookiesReplaced`: the identity is forgotten and the view closes and reopens.
        let identity = SignedInUserStore(userDefaults: env.defaults)
        identity.clear()
        open.close()
        if case .failed = env.model.saveCoordinator.state(for: env.model.documentID) {
            XCTFail("an unknown account is not a refused capture")
        }
        XCTAssertEqual(try env.replicaStore.outbox(for: scope)?.updates.count, 1, "the edit stays durable")
        await open.open(viewModel: env.model, isOffline: true, canUpdate: true)
        guard case .preservedUnavailable = open.route else { return XCTFail("unknown account: read-only") }
        // `signIn` remembers the confirmed (same) account before its own bump.
        identity.remember(owner)
        open.close()
        await open.open(viewModel: env.model, isOffline: true, canUpdate: true)
        guard case .native(let reopened) = open.route else { return XCTFail("the same account types again") }
        XCTAssertNotNil(reopened.input)
        XCTAssertTrue(reopened.hasPendingSave, "the reopen hands the journaled edit over")
        open.flushPendingSave()
        XCTAssertNotNil(env.model.saveCoordinator.pendingSave(documentID: env.model.documentID))
    }

    func testAFlushWithTheAccountUnknownStaysSavedOnThisDevice() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        ServerStub(owner: owner, state: seedState()).install()
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
        guard case .native(let session) = open.route else { return XCTFail("expected a typeable session") }
        XCTAssertTrue(try XCTUnwrap(session.input).replace(range: NSRange(location: 0, length: 0), with: "x"))
        await session.settle()
        let identity = SignedInUserStore(userDefaults: env.defaults)
        identity.clear()  // a sign-out or cookie handover the view has not reacted to yet
        open.flushPendingSave()
        XCTAssertTrue(session.hasPendingSave, "nothing was handed over: still \"Saved on this device\"")
        XCTAssertNil(env.model.saveCoordinator.pendingSave(documentID: env.model.documentID))
        identity.remember(owner)
        open.saveNow(viewModel: env.model)  // the status tap hands it over once the account is known
        XCTAssertFalse(session.hasPendingSave)
        XCTAssertNotNil(env.model.saveCoordinator.storedDraft(documentID: env.model.documentID)?.replica)
    }

    func testAClosedOpenNeverRecachesTheServerCopy() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        try seedReplica(env, typed: "x")
        let server = ServerStub(owner: owner, state: seedState())
        let gate = MockURLProtocol.ResponseGate()
        server.contentGate = gate
        server.install()
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        // Not the view's `.task`: nothing cancels this one, as for a reopen task.
        let opening = Task { await open.open(viewModel: env.model, isOffline: false, canUpdate: true) }
        await waitUntil { server.log.count(ofMethod: "GET", urlContaining: "formatted-content") == 1 }
        open.close()  // a sign-out or sign-in change
        gate.open()
        await opening.value
        XCTAssertNil(env.model.contentCache.content(for: env.model.documentID))
    }

    func testADeletedDocumentNeverRecachesTheServerCopy() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        try seedReplica(env, typed: "x")
        let server = ServerStub(owner: owner, state: seedState())
        let gate = MockURLProtocol.ResponseGate()
        server.contentGate = gate
        server.install()
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        let opening = Task { await open.open(viewModel: env.model, isOffline: false, canUpdate: true) }
        await waitUntil { server.log.count(ofMethod: "GET", urlContaining: "formatted-content") == 1 }
        env.model.handleDidDelete()
        gate.open()
        await opening.value
        XCTAssertNil(env.model.contentCache.content(for: env.model.documentID))
    }

    // MARK: - Marker leftovers

    func testACorruptReplicaWithoutAMarkerNeverFallsBackToClassic() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let scope = try seedReplica(env, typed: "x")
        XCTAssertTrue(env.ownership.clear(scope), "a repair that skipped the folder dropped it")
        try Data("damaged".utf8).write(to: try manifestURL(env, scope))
        ServerStub(owner: owner, state: seedState()).install()
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
        guard case .preservedUnavailable = open.route else {
            return XCTFail("the classic writer must never open over replica data")
        }
    }

    func testMarkerWithoutReplicaIsReseededFromTheServer() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let scope = try seedReplica(env, typed: nil)
        try env.replicaStore.remove(for: scope)
        XCTAssertTrue(env.ownership.mark(scope), "a crash between the marker and the manifest")
        ServerStub(owner: owner, state: seedState()).install()
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
        guard case .native(let session) = open.route else { return XCTFail("the marker must be re-seeded") }
        XCTAssertNotNil(session.input)
        XCTAssertEqual(try env.replicaStore.manifest(for: scope)?.revision, 0)
        XCTAssertEqual(env.model.saveCoordinator.nativeOwnership(documentID: env.model.documentID), .owned(scope))
    }

    func testMarkerWithoutReplicaIsKeptWhileUnsyncedWorkExists() async throws {
        for switchOn in [true, false] {
            let env = makeEnvironment()
            defer { env.clean() }
            let scope = try seedReplica(env, typed: nil)
            try env.replicaStore.remove(for: scope)
            XCTAssertTrue(env.ownership.mark(scope))
            if switchOn {
                PendingDraftStore(userDefaults: env.defaults).save(
                    PendingDraft(
                        documentID: env.model.documentID, title: "Local", markdown: "Unsynced", updatedAt: Date()))
            }
            let open = NativeEditorOpen(preference: { switchOn })
            await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
            guard case .preservedUnavailable = open.route else { return XCTFail("the marker must stay read-only") }
            XCTAssertEqual(env.model.saveCoordinator.nativeOwnership(documentID: env.model.documentID), .owned(scope))
            XCTAssertNil(MockURLProtocol.lastRequest)
            open.close()
        }
    }

    func testRepairRebuildsCorruptMarkerDataFromTheManifests() throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let scope = try seedReplica(env, typed: "x")
        // A folder with no manifest never committed an edit and claims nothing.
        try FileManager.default.createDirectory(
            at: env.replicaDirectory.appendingPathComponent("interrupted-create"), withIntermediateDirectories: true)
        env.defaults.set(Data([0xff]), forKey: "dev.llun.Schrift.replicaOwnership")
        let coordinator = env.model.saveCoordinator
        XCTAssertTrue(coordinator.needsOwnershipRepair)
        XCTAssertEqual(coordinator.nativeOwnership(documentID: scope.documentID), .unreadable)
        XCTAssertTrue(coordinator.repairReplicaOwnership())
        XCTAssertFalse(coordinator.needsOwnershipRepair)
        XCTAssertEqual(coordinator.nativeOwnership(documentID: scope.documentID), .owned(scope))
        XCTAssertEqual(coordinator.nativeOwnership(documentID: UUID()), .none)
    }

    func testRepairRebuildsLostMarkerDataAndKeepsAReadableOwner() throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let scope = try seedReplica(env, typed: "x")
        env.defaults.removeObject(forKey: "dev.llun.Schrift.replicaOwnership")
        let coordinator = env.model.saveCoordinator
        XCTAssertTrue(coordinator.needsOwnershipRepair, "replica files without marker data")
        XCTAssertTrue(coordinator.repairReplicaOwnership())
        XCTAssertEqual(coordinator.nativeOwnership(documentID: scope.documentID), .owned(scope))
        // A readable marker for another account is never replaced by a repair.
        let other = ReplicaScope(
            serverOrigin: scope.serverOrigin, ownerUserID: UUID(), org: "docs", documentID: UUID())
        XCTAssertTrue(env.ownership.mark(other))
        XCTAssertTrue(
            env.ownership.repair(from: [
                ReplicaScope(
                    serverOrigin: scope.serverOrigin, ownerUserID: owner, org: "docs", documentID: other.documentID)
            ]))
        XCTAssertEqual(coordinator.nativeOwnership(documentID: other.documentID), .owned(other))
    }

    func testRepairKeepsADraftedDocumentWhoseFolderIsGone() throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let scope = try seedReplica(env, typed: "x")
        let coordinator = env.model.saveCoordinator
        try coordinator.enqueueReplica(adapter: ReplicaSaveAdapter(store: env.replicaStore, scope: scope), title: "T")
        try FileManager.default.removeItem(at: try manifestURL(env, scope).deletingLastPathComponent())
        env.defaults.set(Data([0xff]), forKey: "dev.llun.Schrift.replicaOwnership")
        XCTAssertTrue(coordinator.repairReplicaOwnership())
        XCTAssertEqual(
            env.ownership.owner(documentID: scope.documentID, serverOrigin: scope.serverOrigin), .owned(scope))
    }

    func testRepairRefusesWhileAFolderCannotBeRead() throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let scope = try seedReplica(env, typed: "x")
        try Data("damaged".utf8).write(to: try manifestURL(env, scope))
        XCTAssertThrowsError(try env.replicaStore.restore(for: scope)) {
            XCTAssertEqual($0 as? ReplicaStoreError, .corrupt)  // and quarantined
        }
        env.defaults.set(Data([0xff]), forKey: "dev.llun.Schrift.replicaOwnership")
        let coordinator = env.model.saveCoordinator
        XCTAssertFalse(coordinator.repairReplicaOwnership())
        XCTAssertEqual(coordinator.nativeOwnership(documentID: scope.documentID), .unreadable)
    }

    func testRepairChoosesTheScopeWithUnsentEditsWhateverTheFolderOrder() throws {
        // Folder order follows the scope digests, so a first-wins choice is wrong in about half.
        for typedOwner in [true, false, true, false, true, false, true, false] {
            let env = makeEnvironment()
            defer { env.clean() }
            let mine = try seedReplica(env, typed: typedOwner ? "x" : nil)
            let theirs = try seedForeignReplica(env, typed: !typedOwner)
            env.defaults.set(Data([0xff]), forKey: "dev.llun.Schrift.replicaOwnership")
            XCTAssertTrue(env.model.saveCoordinator.repairReplicaOwnership())
            XCTAssertEqual(
                env.model.saveCoordinator.nativeOwnership(documentID: mine.documentID),
                .owned(typedOwner ? mine : theirs))
        }
    }

    func testRepairLeavesAnAmbiguousDocumentUnreadable() throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let mine = try seedReplica(env, typed: nil)
        try seedForeignReplica(env, typed: false)
        env.defaults.set(Data([0xff]), forKey: "dev.llun.Schrift.replicaOwnership")
        XCTAssertFalse(env.model.saveCoordinator.repairReplicaOwnership())
        XCTAssertEqual(env.model.saveCoordinator.nativeOwnership(documentID: mine.documentID), .unreadable)
    }

    func testSettingAsideAnUnreadableFolderKeepsItsBytesAndRepairs() throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let scope = try seedReplica(env, typed: "x")
        let folder = try manifestURL(env, scope).deletingLastPathComponent()
        try Data("damaged".utf8).write(to: folder.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try env.replicaStore.restore(for: scope))  // quarantined
        env.defaults.set(Data([0xff]), forKey: "dev.llun.Schrift.replicaOwnership")
        let coordinator = env.model.saveCoordinator
        XCTAssertFalse(coordinator.repairReplicaOwnership())
        XCTAssertTrue(coordinator.hasUnreadableReplicaFolders)
        let files = try FileManager.default.subpathsOfDirectory(atPath: folder.path).sorted()

        XCTAssertTrue(coordinator.setAsideUnreadableReplicasAndRepair())

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "never read as a replica again")
        let setAside = env.directory.appendingPathComponent("ReplicaDraftsSetAside")
        let moved = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: setAside.path).first)
        XCTAssertEqual(
            try FileManager.default.subpathsOfDirectory(atPath: setAside.appendingPathComponent(moved).path).sorted(),
            files, "every byte is kept")
        XCTAssertFalse(coordinator.needsOwnershipRepair)
        XCTAssertFalse(coordinator.hasUnreadableReplicaFolders)
        XCTAssertEqual(coordinator.nativeOwnership(documentID: UUID()), .none, "other documents are editable again")
    }

    func testSettingAsideMovesNothingWhileTheDraftStoreIsUnreadable() throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let scope = try seedReplica(env, typed: "x")
        let folder = try manifestURL(env, scope).deletingLastPathComponent()
        try Data("damaged".utf8).write(to: folder.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try env.replicaStore.restore(for: scope))  // quarantined
        let coordinator = env.model.saveCoordinator
        XCTAssertTrue(coordinator.hasUnreadableReplicaFolders)
        env.defaults.set(Data("not json".utf8), forKey: "dev.llun.Schrift.pendingDrafts")
        XCTAssertTrue(coordinator.hasUnreadableDrafts)

        XCTAssertFalse(coordinator.setAsideUnreadableReplicasAndRepair())

        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "the one-way move never happened")
        XCTAssertTrue(coordinator.hasUnreadableReplicaFolders)
    }

    func testASetAsideDocumentWithADraftStaysReadOnly() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let scope = try seedReplica(env, typed: "x")
        let coordinator = env.model.saveCoordinator
        try coordinator.enqueueReplica(adapter: ReplicaSaveAdapter(store: env.replicaStore, scope: scope), title: "T")
        try Data("damaged".utf8).write(to: try manifestURL(env, scope))
        XCTAssertThrowsError(try env.replicaStore.restore(for: scope))
        env.defaults.set(Data([0xff]), forKey: "dev.llun.Schrift.replicaOwnership")
        XCTAssertTrue(coordinator.setAsideUnreadableReplicasAndRepair())
        XCTAssertEqual(coordinator.nativeOwnership(documentID: scope.documentID), .owned(scope))
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: true, canUpdate: true)
        guard case .preservedUnavailable = open.route else { return XCTFail("its draft keeps it read-only") }
    }

    // MARK: - Native live gate (PR09a)

    /// The socket opens only with the switch, the live preference, a Docs 6
    /// socket and `abilities.update`; the production journal then publishes a
    /// keystroke after its append, on both the seeded and the owned route.
    func testNativeLiveDialsOnlyWhenTheGateHoldsAndPublishesJournaledTyping() async throws {
        let cases: [(live: Bool, canUpdate: Bool, socket: Bool, owned: Bool, dials: Bool)] = [
            (true, true, true, false, true), (true, true, true, true, true), (false, true, true, false, false),
            (true, false, true, false, false), (true, true, false, false, false),
        ]
        for gate in cases {
            let env = makeEnvironment()
            let server = ServerStub(owner: owner, state: seedState())
            server.collaborationWsUrl = gate.socket ? "wss://docs.example.org/collaboration/ws/" : nil
            server.install()
            if gate.owned { try seedReplica(env, typed: nil) }
            let spy = ManagerSocketFactorySpy()
            let open = NativeEditorOpen(preference: { true }, livePreference: { gate.live })
            open.collaboration = DocumentCollaborationManager(
                serverBaseURL: URL(string: "https://docs.example.org/api/v1.0/")!, cookieProvider: { [] },
                featureEnabled: { true }, isOffline: { false }, serverConfigProvider: { nil },
                socketFactory: spy.factory)
            await open.open(viewModel: env.model, isOffline: false, canUpdate: gate.canUpdate)
            guard case .native(let session) = open.route else {
                return XCTFail("expected a native session \(gate) \(open.route)")
            }
            // The binding reads the replica's state vector before it dials.
            if gate.dials {
                await waitUntil { spy.sockets.count == 1 }
            } else {
                await waitAndConfirmNever { !spy.sockets.isEmpty }
            }
            if let socket = spy.sockets.first {
                XCTAssertEqual(
                    spy.requests.first?.url?.absoluteString,
                    "wss://docs.example.org/collaboration/ws/v1/docs/\(env.model.documentID.uuidString.lowercased())")
                session.textView.selectedRange = NSRange(location: 0, length: 0)
                session.input?.textViewDidChangeSelection(session.textView)
                session.textView.insertText("x")
                await session.settle()
                await waitUntil {
                    socket.sentFrames.contains { frame in
                        frame.first == 0
                            && (try? SyncMessage(decodingPayload: Data(frame.dropFirst())))?.step == .update
                    }
                }
                open.close()
                await waitUntil { socket.cancelCloseCode == .goingAway }
            } else {
                open.close()
            }
            env.clean()
        }
    }

    /// S4: the navigation row can be stale (an account switch, a cached row).
    /// An online open asks the server, so a row that still says writer for a
    /// document the account can now only read gets no typing and no socket,
    /// on both the seeded and the owned route.
    func testAStaleWritableRowIsCheckedWithTheServerBeforeTypingOrLive() async throws {
        for owned in [false, true] {
            let env = makeEnvironment()
            let server = ServerStub(owner: owner, state: seedState())
            server.collaborationWsUrl = "wss://docs.example.org/collaboration/ws/"
            server.canUpdate = false
            server.install()
            if owned { try seedReplica(env, typed: nil) }
            let spy = ManagerSocketFactorySpy()
            let open = NativeEditorOpen(preference: { true }, livePreference: { true })
            open.collaboration = DocumentCollaborationManager(
                serverBaseURL: URL(string: "https://docs.example.org/api/v1.0/")!, cookieProvider: { [] },
                featureEnabled: { true }, isOffline: { false }, serverConfigProvider: { nil },
                socketFactory: spy.factory)
            await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
            guard case .native(let session) = open.route else { return XCTFail("expected a native session") }
            if owned {
                // Typing started offline-first from the row; the answer downgrades it.
                await session.settle()
                XCTAssertFalse(session.state.writable, "the server says reader: the replica is read-only")
            } else {
                XCTAssertNil(session.input, "the server says reader: no typing")
                XCTAssertEqual(env.model.saveCoordinator.nativeOwnership(documentID: env.model.documentID), .none)
            }
            await waitAndConfirmNever { !spy.sockets.isEmpty }
            open.close()
            env.clean()
        }
    }

    /// A failed abilities request is not a reader answer: the open keeps the
    /// row's ability, types and saves, on both routes (the server still
    /// refuses a real reader's save).
    func testAFailedAbilitiesRequestKeepsTheRowsAbility() async throws {
        for owned in [false, true] {
            let env = makeEnvironment()
            let server = ServerStub(owner: owner, state: seedState())
            server.detailFails = true
            server.install()
            if owned { try seedReplica(env, typed: nil) }
            let open = NativeEditorOpen(preference: { true })
            await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
            guard case .native(let session) = open.route else { return XCTFail("expected a native session") }
            XCTAssertNotNil(session.input, "typing stays on (owned: \(owned))")
            await session.settle()
            XCTAssertTrue(session.state.writable, "the replica stays writable (owned: \(owned))")
            open.close()
            env.clean()
        }
    }

    /// PR13b review Z2c: a 403, a 404 or an answer naming another document is
    /// a reader answer: the owned route stops writing and dials no socket.
    func testAForbiddenMissingOrMismatchedAbilitiesAnswerIsAReader() async throws {
        for answer in ["403", "404", "mismatch"] {
            let env = makeEnvironment()
            let server = ServerStub(owner: owner, state: seedState())
            server.collaborationWsUrl = "wss://docs.example.org/collaboration/ws/"
            if answer == "mismatch" { server.detailID = UUID() } else { server.detailStatus = Int(answer)! }
            server.install()
            try seedReplica(env, typed: nil)
            let spy = ManagerSocketFactorySpy()
            let open = NativeEditorOpen(preference: { true }, livePreference: { true })
            open.collaboration = DocumentCollaborationManager(
                serverBaseURL: URL(string: "https://docs.example.org/api/v1.0/")!, cookieProvider: { [] },
                featureEnabled: { true }, isOffline: { false }, serverConfigProvider: { nil },
                socketFactory: spy.factory)
            await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
            guard case .native(let session) = open.route else { return XCTFail("expected a native session") }
            await session.settle()
            XCTAssertFalse(session.state.writable, answer)
            await waitAndConfirmNever { !spy.sockets.isEmpty }
            open.close()
            env.clean()
        }
    }

    /// PR13b review Z2c: a denial a headless media commit learned keeps the
    /// editor off the live socket while the server does not answer.
    func testARememberedMediaDenialKeepsTheOpenOffTheSocket() async throws {
        let env = makeEnvironment()
        let server = ServerStub(owner: owner, state: seedState())
        server.collaborationWsUrl = "wss://docs.example.org/collaboration/ws/"
        server.detailFails = true
        server.install()
        env.model.saveCoordinator.noteNativeReader(try seedReplica(env, typed: nil))
        let spy = ManagerSocketFactorySpy()
        let open = NativeEditorOpen(preference: { true }, livePreference: { true })
        open.collaboration = DocumentCollaborationManager(
            serverBaseURL: URL(string: "https://docs.example.org/api/v1.0/")!, cookieProvider: { [] },
            featureEnabled: { true }, isOffline: { false }, serverConfigProvider: { nil },
            socketFactory: spy.factory)
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
        guard case .native = open.route else { return XCTFail("expected a native session") }
        await waitAndConfirmNever { !spy.sockets.isEmpty }
        open.close()
        env.clean()
    }

    // MARK: - Mid-session changes (PR09b)

    private func liveOpen(
        _ env: Environment, server: ServerStub, live: Locked<Bool>, spy: ManagerSocketFactorySpy
    ) async throws -> (NativeEditorOpen, NativeEditorSession) {
        server.collaborationWsUrl = "wss://docs.example.org/collaboration/ws/"
        server.install()
        let open = NativeEditorOpen(preference: { true }, livePreference: { live.value })
        open.collaboration = DocumentCollaborationManager(
            serverBaseURL: URL(string: "https://docs.example.org/api/v1.0/")!, cookieProvider: { [] },
            featureEnabled: { true }, isOffline: { false }, serverConfigProvider: { nil },
            socketFactory: spy.factory)
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
        guard case .native(let session) = open.route else {
            XCTFail("expected a native session")
            throw CancellationError()
        }
        await waitUntil { spy.sockets.count == 1 }
        return (open, session)
    }

    /// A permission change closes the socket with 1000; the open asks the
    /// server again, and a reader answer makes every surface read-only through
    /// `setWritable(nil)` with no socket left.
    func testAPermissionResetToReaderMakesTheOpenReadOnlyWithoutASocket() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let server = ServerStub(owner: owner, state: seedState())
        let spy = ManagerSocketFactorySpy()
        let (open, session) = try await liveOpen(env, server: server, live: Locked(true), spy: spy)
        defer { open.close() }
        XCTAssertTrue(session.state.writable)
        server.canUpdate = false
        try XCTUnwrap(spy.sockets.first).serverClose(code: .normalClosure)
        await waitUntil { !session.state.writable }
        await waitAndConfirmNever(timeout: 1.5) { spy.sockets.count > 1 }
    }

    /// Turning Live collaboration off while open closes the socket and nothing
    /// dials; turning it on joins again. Typing and HTTP saving go on.
    func testTurningLiveOffAndOnMidSession() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let server = ServerStub(owner: owner, state: seedState())
        let spy = ManagerSocketFactorySpy()
        let live = Locked(true)
        let (open, session) = try await liveOpen(env, server: server, live: live, spy: spy)
        defer { open.close() }
        live.value = false
        open.liveSettingChanged(viewModel: env.model, isOffline: false)
        let first = try XCTUnwrap(spy.sockets.first)
        await waitUntil { first.cancelCloseCode == .goingAway }
        XCTAssertNotNil(session.input, "typing stays on")
        await waitAndConfirmNever(timeout: 1.5) { spy.sockets.count > 1 }
        live.value = true
        open.liveSettingChanged(viewModel: env.model, isOffline: false)
        await waitUntil { spy.sockets.count == 2 }
    }

    /// O2: a push of the same document opens a second editor before the
    /// first closes; once the first is gone, the second's typing still goes
    /// live (the binding takes the latest open's dialer).
    func testASecondOpenOfTheSameDocumentKeepsLiveAfterTheFirstCloses() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let server = ServerStub(owner: owner, state: seedState())
        let spy = ManagerSocketFactorySpy()
        let (first, _) = try await liveOpen(env, server: server, live: Locked(true), spy: spy)
        let second = NativeEditorOpen(preference: { true }, livePreference: { true })
        second.registry = first.registry
        second.collaboration = first.collaboration
        defer { second.close() }
        await second.open(viewModel: env.model, isOffline: false, canUpdate: true)
        guard case .native(let session) = second.route else { return XCTFail("expected a native session") }
        first.close()
        let socket = try XCTUnwrap(spy.sockets.first)
        session.textView.selectedRange = NSRange(location: 0, length: 0)
        session.input?.textViewDidChangeSelection(session.textView)
        session.textView.insertText("s")
        await session.settle()
        await waitUntil {
            socket.sentFrames.contains { frame in
                frame.first == 0 && (try? SyncMessage(decodingPayload: Data(frame.dropFirst())))?.step == .update
            }
        }
    }

    // MARK: - Fixture

    private func manifestURL(_ env: Environment, _ scope: ReplicaScope) throws -> URL {
        env.replicaDirectory.appendingPathComponent(try scope.directoryName()).appendingPathComponent("manifest.json")
    }

    /// Another account's folder for the same document, written past the marker
    /// (which refuses a second owner): what a lost marker can leave behind.
    @discardableResult
    private func seedForeignReplica(_ env: Environment, typed: Bool) throws -> ReplicaScope {
        let scope = ReplicaScope(
            serverOrigin: env.model.client.serverOrigin, ownerUserID: UUID(), org: "docs",
            documentID: env.model.documentID)
        let store = ReplicaStore(directory: env.replicaDirectory)
        let checkpoint = seedState()
        _ = try store.create(for: scope, checkpoint: checkpoint)
        guard typed else { return scope }
        let doc = YDoc(clientID: 3)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(checkpoint), origin: .remote)
        let update = try BlockNoteWriter(doc: doc).replaceText(block: Self.firstID, range: 0..<0, with: "y")
        try ReplicaSaveAdapter(store: store, scope: scope).record(
            NativeEditCommand(id: UUID(), baseRevision: 0, blockID: Self.firstID, range: 0..<0, replacement: "y"),
            update: update)
        return scope
    }

    private func text(_ session: NativeEditorSession, block: Int) -> String {
        session.surface.blocks[block].runs.map(\.text).joined()
    }

    private func seedState() -> Data { BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID) }

    private func isSaved(_ state: DocumentSaveCoordinator.DocSaveState) -> Bool {
        if case .saved = state { return true }
        return false
    }

    private func isPendingSync(_ state: DocumentSaveCoordinator.DocSaveState) -> Bool {
        if case .pendingSync = state { return true }
        return false
    }

    /// A durable replica for the environment's document, optionally with one
    /// journaled local edit that was never handed to the coordinator.
    @discardableResult
    private func seedReplica(_ env: Environment, typed: String?) throws -> ReplicaScope {
        let scope = ReplicaScope(
            serverOrigin: env.model.client.serverOrigin, ownerUserID: owner, org: "docs",
            documentID: env.model.documentID)
        let checkpoint = seedState()
        _ = try env.replicaStore.create(for: scope, checkpoint: checkpoint)
        guard let typed else { return scope }
        let doc = YDoc(clientID: 2)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(checkpoint), origin: .remote)
        let update = try BlockNoteWriter(doc: doc).replaceText(block: Self.firstID, range: 0..<0, with: typed)
        try ReplicaSaveAdapter(store: env.replicaStore, scope: scope).record(
            NativeEditCommand(id: UUID(), baseRevision: 0, blockID: Self.firstID, range: 0..<0, replacement: typed),
            update: update)
        return scope
    }

    private struct Environment {
        let model: EditorViewModel
        let defaults: UserDefaults
        let suite: String
        let directory: URL
        let ownership: ReplicaOwnershipStore
        let replicaStore: ReplicaStore
        let documentID: UUID
        let makeModel: @MainActor () -> EditorViewModel
        var replicaDirectory: URL { directory.appendingPathComponent("ReplicaDrafts") }
        /// A new process: fresh coordinator and view model over the same disk.
        @MainActor func relaunch() -> EditorViewModel { makeModel() }
        func clean() {
            MockURLProtocol.reset()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeEnvironment(
        autosaveInterval: Duration = .seconds(10), isLiveHeld: @escaping @MainActor (UUID) -> Bool = { _ in false }
    ) -> Environment {
        MockURLProtocol.reset()
        let suite = "NativeEditorActivationTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let documentID = UUID()
        SignedInUserStore(userDefaults: defaults).remember(owner)
        let makeModel: @MainActor () -> EditorViewModel = {
            let client = DocsAPIClient(
                baseURL: URL(string: "https://docs.example.org/api/v1.0/")!, session: MockURLProtocol.makeSession(),
                cookieProvider: { [] })
            let content = DocumentContentCacheStore(directory: directory)
            let children = DocumentChildrenCacheStore(userDefaults: defaults)
            let replicaStore = ReplicaStore(
                directory: directory.appendingPathComponent("ReplicaDrafts"),
                ownershipStore: ReplicaOwnershipStore(userDefaults: defaults))
            let coordinator = DocumentSaveCoordinator(
                client: client, draftStore: PendingDraftStore(userDefaults: defaults), replicaStore: replicaStore,
                contentCache: content, createStore: PendingDocumentCreateStore(userDefaults: defaults),
                deleteStore: PendingDocumentDeleteStore(userDefaults: defaults),
                attachmentStore: PendingAttachmentStore(
                    userDefaults: defaults, directory: directory.appendingPathComponent("attachments")),
                listCache: DocumentCacheStore(userDefaults: defaults), childrenCache: children,
                backgroundTasks: .noop, isLiveReplicaHeld: isLiveHeld)
            return EditorViewModel(
                client: client, documentID: documentID, title: "List title", saveCoordinator: coordinator,
                signedInUser: SignedInUserStore(userDefaults: defaults), contentCache: content,
                childrenCache: children, listCache: DocumentCacheStore(userDefaults: defaults),
                autosaveInterval: autosaveInterval,
                availability: OnlineAvailability(userDefaults: defaults))
        }
        let model = makeModel()
        let ownership = ReplicaOwnershipStore(userDefaults: defaults)
        return Environment(
            model: model, defaults: defaults, suite: suite, directory: directory, ownership: ownership,
            replicaStore: model.saveCoordinator.replicaStore, documentID: documentID, makeModel: makeModel)
    }
}

/// A Docs 6 server: config, raw state, formatted export, `/users/me/`, the
/// collaboration PATCH and the title PATCH. `isOffline` fails every request.
private final class ServerStub: @unchecked Sendable {
    let log = RequestRecorder()
    private let lock = NSLock()
    private let owner: UUID
    private let state: Data
    private var _isOffline = false
    private var _collaborationWsUrl: String?
    private var _canUpdate = true
    private var _detailFails = false
    private var _detailStatus = 200
    private var _detailID: UUID?
    private var _patched: [Data] = []
    private var _titles: [String] = []
    var stateGate: MockURLProtocol.ResponseGate?
    var contentGate: MockURLProtocol.ResponseGate?

    init(owner: UUID, state: Data) {
        self.owner = owner
        self.state = state
    }

    var isOffline: Bool {
        get { locked { _isOffline } }
        set { locked { _isOffline = newValue } }
    }
    /// The document's `abilities.update` the detail route answers.
    var canUpdate: Bool {
        get { locked { _canUpdate } }
        set { locked { _canUpdate = newValue } }
    }
    /// The detail route answers 503, like a failing server or a captive portal.
    var detailFails: Bool {
        get { locked { _detailFails } }
        set { locked { _detailFails = newValue } }
    }
    /// The detail route answers this status instead (403, 404: an answer about the document).
    var detailStatus: Int {
        get { locked { _detailStatus } }
        set { locked { _detailStatus = newValue } }
    }
    /// The id the detail route's answer names (nil: the one asked for).
    var detailID: UUID? {
        get { locked { _detailID } }
        set { locked { _detailID = newValue } }
    }
    var collaborationWsUrl: String? {
        get { locked { _collaborationWsUrl } }
        set { locked { _collaborationWsUrl = newValue } }
    }
    var patchedUpdates: [Data] { locked { _patched } }
    var titles: [String] { locked { _titles } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func install() {
        MockURLProtocol.stubHandler = { [self] request in
            log.record(request)
            if isOffline {
                return .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
            }
            let url = request.url?.absoluteString ?? ""  // `URL.path` drops the trailing slash
            let json = ["Content-Type": "application/json"]
            if url.hasSuffix("/config/") {
                let socket = collaborationWsUrl.map { #"","COLLABORATION_WS_URL":"\#($0)"# } ?? ""
                return .init(
                    statusCode: 200, headers: json, body: Data(#"{"RELEASE_VERSION":"6.0.0\#(socket)"}"#.utf8),
                    error: nil)
            }
            if url.hasSuffix("/users/me/") {
                return .init(
                    statusCode: 200, headers: json, body: Data(#"{"id":"\#(owner.uuidString)"}"#.utf8), error: nil)
            }
            if url.contains("/collaboration/ydoc/") {
                if request.httpMethod == "PATCH" {
                    let body =
                        (try? JSONSerialization.jsonObject(with: bodyData(from: request) ?? Data()))
                        as? [String: String]
                    if let update = body?["update"].flatMap({ Data(base64Encoded: $0) }) {
                        locked { _patched.append(update) }
                    }
                    return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
                }
                let body = try! JSONSerialization.data(withJSONObject: ["doc": state.base64EncodedString()])
                return .init(statusCode: 200, headers: json, body: body, error: nil, releasedBy: stateGate)
            }
            if url.contains("formatted-content") {
                let id = request.url!.path.split(separator: "/").first { UUID(uuidString: String($0)) != nil }!
                let object: [String: Any] = [
                    "id": String(id), "title": "Fresh server title", "content": "First paragraph.",
                    "created_at": "2026-11-07T10:00:00Z", "updated_at": "2026-11-07T10:00:00Z",
                ]
                return .init(
                    statusCode: 200, headers: json, body: try! JSONSerialization.data(withJSONObject: object),
                    error: nil, releasedBy: contentGate)
            }
            if request.httpMethod == "GET", url.hasSuffix("/"),
                let id = url.split(separator: "/").last.flatMap({ UUID(uuidString: String($0)) })
            {
                if detailFails { return .init(statusCode: 503, headers: [:], body: Data(), error: nil) }
                if detailStatus != 200 {
                    return .init(statusCode: detailStatus, headers: [:], body: Data(), error: nil)
                }
                let detail: [String: Any] = [
                    "id": (detailID ?? id).uuidString.lowercased(), "title": "Fresh server title", "excerpt": NSNull(),
                    "abilities": ["update": canUpdate], "computed_link_reach": "restricted",
                    "computed_link_role": NSNull(), "created_at": "2026-11-07T10:00:00Z", "creator": NSNull(),
                    "depth": 1, "link_role": "reader", "link_reach": "restricted", "numchild": 0, "path": "0001",
                    "updated_at": "2026-11-07T10:00:00Z", "user_role": "owner",
                ]
                return .init(
                    statusCode: 200, headers: json, body: try! JSONSerialization.data(withJSONObject: detail),
                    error: nil)
            }
            if request.httpMethod == "PATCH" {
                let body =
                    (try? JSONSerialization.jsonObject(with: bodyData(from: request) ?? Data())) as? [String: Any]
                if let title = body?["title"] as? String { locked { _titles.append(title) } }
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
    }
}
