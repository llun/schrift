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
        let env = makeEnvironment(autosaveInterval: .zero)
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
        XCTAssertGreaterThan(try XCTUnwrap(env.replicaStore.manifest(for: scope)).revision, 1)
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

    // MARK: - Marker leftovers

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

    // MARK: - Fixture

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
    private var _patched: [Data] = []
    private var _titles: [String] = []
    var stateGate: MockURLProtocol.ResponseGate?

    init(owner: UUID, state: Data) {
        self.owner = owner
        self.state = state
    }

    var isOffline: Bool {
        get { locked { _isOffline } }
        set { locked { _isOffline = newValue } }
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
                return .init(
                    statusCode: 200, headers: json, body: Data(#"{"RELEASE_VERSION":"6.0.0"}"#.utf8), error: nil)
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
