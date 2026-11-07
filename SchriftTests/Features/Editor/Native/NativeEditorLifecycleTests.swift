import XCTest

@testable import Schrift

@MainActor
final class NativeEditorLifecycleTests: DocumentEngineTestCase {
    func testPreferenceDefaultsOffAndOpenCapturesTheChoice() {
        let suite = "NativeEditorLifecycleTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(NativeEditorPreference.isEnabled(defaults))
        let open = NativeEditorOpen(enabled: NativeEditorPreference.isEnabled(defaults))
        defaults.set(true, forKey: NativeEditorPreference.key)
        XCTAssertTrue(NativeEditorPreference.isEnabled(defaults))
        XCTAssertFalse(open.enabled)
        guard case .classic = open.route else { return XCTFail("off must keep the classic route") }
        let nextOpen = NativeEditorOpen(enabled: NativeEditorPreference.isEnabled(defaults))
        XCTAssertTrue(nextOpen.enabled)
        guard case .loading = nextOpen.route else { return XCTFail("next open should try native") }
    }

    func testCloseDestroysReplicaAndDetachesEngineBeforeReopen() throws {
        let state = BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID)
        weak var replica: YDoc?
        let session = try NativeEditorSession(state: state) {
            let doc = YDoc(clientID: 123)
            replica = doc
            return doc
        }
        XCTAssertNotNil(replica)
        XCTAssertFalse(session.engine.isDetached)
        XCTAssertEqual(session.surface.blocks.count, 3)
        session.close()
        session.close()
        XCTAssertTrue(session.engine.isDetached)
        XCTAssertTrue(session.isClosed)
        XCTAssertTrue(replica?.store.clients.isEmpty == true, "destroy must clear the replica graph")
        XCTAssertTrue(replica?.share.isEmpty == true)
        XCTAssertThrowsError(try session.engine.replaceText(block: Self.firstID, range: 0..<0, with: "closed"))
        let reopened = try NativeEditorSession(state: state)
        defer { reopened.close() }
        XCTAssertEqual(reopened.surface.blocks, session.surface.blocks)
        XCTAssertFalse(reopened.engine.isDetached)
    }

    func testReleasingSessionAndFailedSeedBothDestroyTheirReplica() throws {
        weak var replica: YDoc?
        var session: NativeEditorSession? = try NativeEditorSession(
            state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID)
        ) {
            let doc = YDoc(clientID: 124)
            replica = doc
            return doc
        }
        XCTAssertNotNil(session)
        XCTAssertNotNil(replica)
        session = nil
        XCTAssertNil(replica)

        // Start with real structs so failure cleanup has cycles to break.
        XCTAssertThrowsError(
            try NativeEditorSession(state: Data([0xff])) {
                let doc = try self.makeDoc(clientID: 125)
                replica = doc
                return doc
            })
        XCTAssertNil(replica)
    }

    func testInvalidRootAndEmptyRootAreDistinguished() throws {
        let empty = try NativeEditorSession(state: Data([0, 0]))
        defer { empty.close() }
        XCTAssertFalse(empty.hasUnsupportedRoot)
        XCTAssertTrue(empty.surface.blocks.isEmpty)
        let doc = YDoc(clientID: 130)
        defer { doc.destroy() }
        let root = doc.get(BlockNoteYjs.fragmentField)
        try doc.transact { tx in
            _ = try YWrite.insertAfter(
                tx, into: root, after: nil, [.type(YType(typeRef: .xmlElement(nodeName: "unknown")))])
        }
        let unsupported = try NativeEditorSession(state: YStateEncoder.encodeStateAsUpdate(doc))
        defer { unsupported.close() }
        XCTAssertTrue(unsupported.hasUnsupportedRoot)
    }

    func testSwitchOffAndOfflineKeepClassicWithoutFetching() async {
        let fixture = makeFixture()
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        let off = NativeEditorOpen(enabled: false)
        await off.open(viewModel: fixture.model, isOffline: false)
        guard case .classic = off.route else { return XCTFail("off route changed") }
        XCTAssertNil(MockURLProtocol.lastRequest)
        let offline = NativeEditorOpen(enabled: true)
        await offline.open(viewModel: fixture.model, isOffline: true)
        guard case .classic = offline.route else { return XCTFail("offline must fall back") }
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testPendingDeletionKeepsClassicWithoutFetching() async {
        let fixture = makeFixture()
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        fixture.model.saveCoordinator.recordPendingDelete(documentID: fixture.model.documentID, ownerUserID: UUID())
        XCTAssertTrue(fixture.model.isDocumentPendingDelete)
        let open = NativeEditorOpen(enabled: true)
        await open.open(viewModel: fixture.model, isOffline: false)
        guard case .classic = open.route else { return XCTFail("a tombstoned document must stay on classic") }
        XCTAssertNil(MockURLProtocol.lastRequest, "a tombstone must prevent even the config prefetch")
    }

    func testDeletionQueuedDuringRawFetchPreventsNativeInstallation() async {
        let fixture = makeFixture()
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        let response = MockURLProtocol.ResponseGate()
        stub(
            version: "6.0.0", state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID), gate: response
        )
        let open = NativeEditorOpen(enabled: true)
        let loading = Task { await open.open(viewModel: fixture.model, isOffline: false) }
        await waitUntil { MockURLProtocol.lastRequest?.url?.path.contains("/collaboration/ydoc/") == true }
        fixture.model.saveCoordinator.recordPendingDelete(documentID: fixture.model.documentID, ownerUserID: UUID())
        response.open()
        await loading.value
        guard case .classic = open.route else { return XCTFail("an in-flight response showed a tombstoned document") }
    }

    func testUnreachableServerKeepsClassicWithoutPrefetching() async {
        let connectivity = ConnectivityMonitor(monitoring: NetworkPathMonitoring { _ in {} })
        let fixture = makeFixture(connectivity: connectivity)
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        connectivity.report(.unreachable)
        await waitUntil { connectivity.serverUnreachable }
        XCTAssertFalse(fixture.model.availability.isOffline, "this is transport evidence on a satisfied path")
        let open = NativeEditorOpen(enabled: true)
        await open.open(viewModel: fixture.model, isOffline: false)
        guard case .classic = open.route else { return XCTFail("unreachable native prefetch must not hold up cache") }
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testDeadlineBoundsStalledConfigAndRawFetchWithoutWaitingForResponse() async {
        for stallsConfig in [true, false] {
            let fixture = makeFixture()
            defer {
                fixture.clean()
                MockURLProtocol.reset()
            }
            let response = MockURLProtocol.ResponseGate()
            let deadline = NativeOpenTestDeadline()
            stub(
                version: "6.0.0", state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID),
                gate: stallsConfig ? nil : response, configGate: stallsConfig ? response : nil)
            let open = NativeEditorOpen(enabled: true, waitForTimeout: { await deadline.wait() })
            let loading = Task { await open.open(viewModel: fixture.model, isOffline: false) }
            await waitUntil {
                deadline.isWaiting
                    && (stallsConfig
                        ? MockURLProtocol.lastRequest?.url?.path.contains("/config") == true
                        : MockURLProtocol.lastRequest?.url?.path.contains("/collaboration/ydoc/") == true)
            }
            // The network gate stays shut: fallback cannot depend on URLSession
            // or a shared config task cooperating with cancellation.
            deadline.fire()
            await loading.value
            guard case .classic = open.route else { return XCTFail("deadline did not select classic") }
            response.open()
            if stallsConfig { _ = try? await fixture.model.client.serverConfig() }
            await open.open(viewModel: fixture.model, isOffline: false)
            guard case .classic = open.route else { return XCTFail("a late response replaced the selected fallback") }
        }
    }

    func testLegacyAndFailedRawFetchFallBackToClassic() async {
        for (version, status, body) in [
            ("5.0.0", 200, Data()), ("6.0.0", 500, Data()), ("6.0.0", 200, Data("invalid".utf8)),
        ] {
            let fixture = makeFixture()
            defer {
                fixture.clean()
                MockURLProtocol.reset()
            }
            stub(version: version, state: body, status: status)
            let open = NativeEditorOpen(enabled: true)
            await open.open(viewModel: fixture.model, isOffline: false)
            guard case .classic = open.route else { return XCTFail("legacy or failed raw fetch must fall back") }
        }
    }

    func testRawDocs6RouteSeedsProductionSurfaceAndNeverStartsClassicLoad() async throws {
        let fixture = makeFixture()
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        stub(version: "6.0.0", state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID))
        let open = NativeEditorOpen(enabled: true)
        await open.open(viewModel: fixture.model, isOffline: false)
        guard case .native(let session) = open.route else { return XCTFail("expected native session") }
        XCTAssertEqual(session.surface.blocks.count, 3)
        XCTAssertFalse(fixture.model.hasLoadedContent, "classic markdown loading must not run")
        XCTAssertFalse(fixture.model.isEditing)
        XCTAssertNotNil(session.textView.textLayoutManager)
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "GET")
        XCTAssertEqual(
            MockURLProtocol.lastRequest?.url?.path,
            "/collaboration/ydoc/v1/docs/\(fixture.model.documentID.uuidString.lowercased())")
        open.close()
        XCTAssertTrue(session.isClosed)
        XCTAssertTrue(session.engine.isDetached)
    }

    func testPendingLocalDraftStaysOnClassicRoute() async {
        let fixture = makeFixture()
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        PendingDraftStore(userDefaults: fixture.defaults).save(
            PendingDraft(documentID: fixture.model.documentID, title: "Local", markdown: "Unsynced", updatedAt: Date()))
        let open = NativeEditorOpen(enabled: true)
        await open.open(viewModel: fixture.model, isOffline: false)
        guard case .classic = open.route else { return XCTFail("server baseline must not hide local work") }
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testClosingDuringRawFetchDiscardsTheLateResponse() async {
        let fixture = makeFixture()
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        let gate = MockURLProtocol.ResponseGate()
        stub(version: "6.0.0", state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID), gate: gate)
        let open = NativeEditorOpen(enabled: true)
        let loading = Task { await open.open(viewModel: fixture.model, isOffline: false) }
        await waitUntil { MockURLProtocol.lastRequest?.url?.path.contains("/collaboration/ydoc/") == true }
        open.close()
        gate.open()
        await loading.value
        guard case .loading = open.route else { return XCTFail("a closed request installed a session") }
    }

    func testLocalDraftArrivingDuringRawFetchKeepsTheClassicRoute() async {
        let fixture = makeFixture()
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        let gate = MockURLProtocol.ResponseGate()
        stub(version: "6.0.0", state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID), gate: gate)
        let open = NativeEditorOpen(enabled: true)
        let loading = Task { await open.open(viewModel: fixture.model, isOffline: false) }
        await waitUntil { MockURLProtocol.lastRequest?.url?.path.contains("/collaboration/ydoc/") == true }
        PendingDraftStore(userDefaults: fixture.defaults).save(
            PendingDraft(
                documentID: fixture.model.documentID, title: "Local", markdown: "Arrived while loading",
                updatedAt: Date()))
        gate.open()
        await loading.value
        guard case .classic = open.route else { return XCTFail("an in-flight baseline hid a local draft") }
    }

    private func stub(
        version: String, state: Data, status: Int = 200, gate: MockURLProtocol.ResponseGate? = nil,
        configGate: MockURLProtocol.ResponseGate? = nil
    ) {
        MockURLProtocol.stubHandler = { request in
            let isConfig =
                request.url?.path.hasSuffix("config") == true || request.url?.path.hasSuffix("config/") == true
            let object = isConfig ? ["RELEASE_VERSION": version] : ["doc": state.base64EncodedString()]
            return .init(
                statusCode: isConfig ? 200 : status, headers: ["Content-Type": "application/json"],
                body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), error: nil,
                releasedBy: isConfig ? configGate : gate)
        }
    }

    private struct Fixture {
        let model: EditorViewModel
        let defaults: UserDefaults
        let suite: String
        let directory: URL
        func clean() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFixture(connectivity: ConnectivityMonitor? = nil) -> Fixture {
        MockURLProtocol.reset()
        let suite = "NativeEditorLifecycleTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let client = DocsAPIClient(
            baseURL: URL(string: "https://docs.example.org/api/v1.0/")!, session: MockURLProtocol.makeSession(),
            cookieProvider: { [] })
        let content = DocumentContentCacheStore(directory: directory)
        let children = DocumentChildrenCacheStore(userDefaults: defaults)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: PendingDraftStore(userDefaults: defaults), contentCache: content,
            createStore: PendingDocumentCreateStore(userDefaults: defaults),
            deleteStore: PendingDocumentDeleteStore(userDefaults: defaults),
            attachmentStore: PendingAttachmentStore(
                userDefaults: defaults, directory: directory.appendingPathComponent("attachments")),
            listCache: DocumentCacheStore(userDefaults: defaults), childrenCache: children, backgroundTasks: .noop)
        let model = EditorViewModel(
            client: client, documentID: UUID(), title: "Fixture", saveCoordinator: coordinator,
            signedInUser: SignedInUserStore(userDefaults: defaults), contentCache: content, childrenCache: children,
            listCache: DocumentCacheStore(userDefaults: defaults),
            availability: OnlineAvailability(connectivity: connectivity, userDefaults: defaults))
        return Fixture(model: model, defaults: defaults, suite: suite, directory: directory)
    }
}

@MainActor
private final class NativeOpenTestDeadline {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }
    func fire() {
        continuation?.resume()
        continuation = nil
    }
}
