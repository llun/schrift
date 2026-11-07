import XCTest

@testable import Schrift

@MainActor
final class NativeEditorLifecycleTests: DocumentEngineTestCase {
    func testPreferenceIsReadAtEachOpenWithoutSwitchingAnActiveEditor() async {
        let fixture = makeFixture()
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        var reads = 0
        let open = NativeEditorOpen(preference: {
            reads += 1
            return NativeEditorPreference.isEnabled(fixture.defaults)
        })
        defer { open.close() }
        XCTAssertEqual(reads, 1, "construction only chooses the initial renderer")
        XCTAssertFalse(NativeEditorPreference.isEnabled(fixture.defaults))
        await open.open(viewModel: fixture.model, isOffline: false)
        guard case .classic = open.route else { return XCTFail("unset preference must keep classic") }
        XCTAssertEqual(reads, 2, "the first open must reread the source")
        fixture.defaults.set(true, forKey: NativeEditorPreference.key)
        await open.open(viewModel: fixture.model, isOffline: false)
        guard case .classic = open.route else { return XCTFail("an active editor must not swap live") }
        XCTAssertEqual(reads, 2)

        stub(version: "6.0.0", state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID))
        open.close()
        await open.open(viewModel: fixture.model, isOffline: false)
        guard case .native(let session) = open.route else { return XCTFail("reopen must read the enabled preference") }
        XCTAssertEqual(reads, 3)
        fixture.defaults.set(false, forKey: NativeEditorPreference.key)
        await open.open(viewModel: fixture.model, isOffline: false)
        guard case .native = open.route else { return XCTFail("an active reader must not swap live") }
        XCTAssertEqual(reads, 3)
        open.close()
        XCTAssertTrue(session.isClosed)
        MockURLProtocol.reset()
        await open.open(viewModel: fixture.model, isOffline: false)
        guard case .classic = open.route else { return XCTFail("reopen must read the disabled preference") }
        XCTAssertEqual(reads, 4)
        XCTAssertNil(MockURLProtocol.lastRequest)
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
        let off = NativeEditorOpen(preference: { false })
        await off.open(viewModel: fixture.model, isOffline: false)
        guard case .classic = off.route else { return XCTFail("off route changed") }
        XCTAssertNil(MockURLProtocol.lastRequest)
        let offline = NativeEditorOpen(preference: { true })
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
        let open = NativeEditorOpen(preference: { true })
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
        let open = NativeEditorOpen(preference: { true })
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
        let open = NativeEditorOpen(preference: { true })
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
            let completionCount = Counter()
            let completed = expectation(
                description: stallsConfig ? "late config response completed" : "late raw response completed")
            completed.assertForOverFulfill = true
            stub(
                version: "6.0.0", state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID),
                gate: stallsConfig ? nil : response, configGate: stallsConfig ? response : nil,
                onGatedCompletion: {
                    _ = completionCount.next()
                    completed.fulfill()
                })
            let open = NativeEditorOpen(preference: { true }, waitForTimeout: { await deadline.wait() })
            let loading = Task { await open.open(viewModel: fixture.model, isOffline: false) }
            await waitUntil {
                deadline.isWaiting && MockURLProtocol.deferredDeliveryCount == 1
                    && (stallsConfig
                        ? MockURLProtocol.lastRequest?.url?.path.contains("/config") == true
                        : MockURLProtocol.lastRequest?.url?.path.contains("/collaboration/ydoc/") == true)
            }
            // The network gate stays shut: fallback cannot depend on URLSession
            // or a shared config task cooperating with cancellation.
            deadline.fire()
            await loading.value
            guard case .classic = open.route else { return XCTFail("deadline did not select classic") }
            XCTAssertEqual(completionCount.current, 0, "the late response must still be held after fallback")
            response.open()
            await fulfillment(of: [completed], timeout: 3)
            XCTAssertEqual(completionCount.current, 1)
            let installedSession: NativeEditorSession?
            if case .native(let session) = open.route { installedSession = session } else { installedSession = nil }
            XCTAssertNil(installedSession, "late prefetch completion must not install a native replica")
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
            let open = NativeEditorOpen(preference: { true })
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
        let recorder = RequestRecorder()
        stub(
            version: "6.0.0", state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID),
            recorder: recorder)
        let open = NativeEditorOpen(preference: { true })
        await open.open(viewModel: fixture.model, isOffline: false)
        guard case .native(let session) = open.route else { return XCTFail("expected native session") }
        XCTAssertEqual(session.surface.blocks.count, 3)
        XCTAssertFalse(fixture.model.hasLoadedContent, "classic markdown loading must not run")
        XCTAssertFalse(fixture.model.isEditing)
        XCTAssertNotNil(session.textView.textLayoutManager)
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "GET")
        XCTAssertEqual(
            recorder.count(
                ofMethod: "GET",
                urlContaining:
                    "/collaboration/ydoc/v1/docs/\(fixture.model.documentID.uuidString.lowercased())"), 1)
        open.close()
        XCTAssertTrue(session.isClosed)
        XCTAssertTrue(session.engine.isDetached)
    }

    func testSuccessfulNativeOpenRefreshesCacheForOfflineClassicFallback() async {
        for hasStaleCopy in [false, true] {
            let fixture = makeFixture()
            defer {
                fixture.clean()
                MockURLProtocol.reset()
            }
            let cache = DocumentContentCacheStore(directory: fixture.directory)
            if hasStaleCopy {
                cache.save(
                    CachedDocumentContent(
                        documentID: fixture.model.documentID, title: "Old title", markdown: "Old body",
                        syncedAt: Date(timeIntervalSince1970: 1)))
            }
            let recorder = RequestRecorder()
            stub(
                version: "6.0.0", state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID),
                markdown: "Fresh server-exported offline text", recorder: recorder)
            let open = NativeEditorOpen(preference: { true })
            await open.open(viewModel: fixture.model, isOffline: false)
            guard case .native = open.route else { return XCTFail("expected native reader") }
            let cached = cache.content(for: fixture.model.documentID)
            XCTAssertEqual(cached?.markdown, "Fresh server-exported offline text")
            XCTAssertEqual(cached?.title, "Fresh server title")
            XCTAssertEqual(cached?.serverUpdatedAt, ISO8601DateFormatter().date(from: "2026-11-07T10:00:00Z"))
            XCTAssertFalse(fixture.model.hasLoadedContent, "cache refresh must not install classic editor state")
            open.close()

            let requests = recorder.methods.count
            fixture.defaults.set(true, forKey: "schrift.workOffline")
            await open.open(viewModel: fixture.model, isOffline: true)
            guard case .classic = open.route else { return XCTFail("offline reopen must use classic") }
            await fixture.model.load()
            XCTAssertTrue(fixture.model.hasLoadedContent)
            XCTAssertEqual(fixture.model.currentMarkdown(), "Fresh server-exported offline text")
            XCTAssertEqual(fixture.model.title, "Fresh server title")
            XCTAssertEqual(recorder.methods.count, requests, "offline fallback must use the refreshed disk cache")
            open.close()
        }
    }

    func testPendingCreationIntentAlwaysChoosesEditableClassicWithoutNativeFetch() async {
        let intent = NewDocumentEntryIntent()
        let fixture = makeFixture(entryIntent: intent)
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        stub(version: "6.0.0", state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID), markdown: "")
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: fixture.model, isOffline: false)
        guard case .classic = open.route else { return XCTFail("creation intent must choose classic explicitly") }
        XCTAssertNil(MockURLProtocol.lastRequest, "must not rely on an empty raw-state decode failure")
        XCTAssertTrue(intent.isPending)
        await fixture.model.load()
        XCTAssertTrue(fixture.model.isEditing)
        XCTAssertFalse(intent.isPending)
    }

    func testPendingLocalDraftStaysOnClassicRoute() async {
        let fixture = makeFixture()
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        PendingDraftStore(userDefaults: fixture.defaults).save(
            PendingDraft(documentID: fixture.model.documentID, title: "Local", markdown: "Unsynced", updatedAt: Date()))
        let open = NativeEditorOpen(preference: { true })
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
        let open = NativeEditorOpen(preference: { true })
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
        let open = NativeEditorOpen(preference: { true })
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
        configGate: MockURLProtocol.ResponseGate? = nil, onGatedCompletion: (@Sendable () -> Void)? = nil,
        markdown: String = "Exported offline content", recorder: RequestRecorder? = nil
    ) {
        MockURLProtocol.stubHandler = { request in
            recorder?.record(request)
            if request.url?.path.contains("formatted-content") == true {
                let id = request.url!.path.split(separator: "/").first { UUID(uuidString: String($0)) != nil }!
                let object: [String: Any] = [
                    "id": String(id), "title": "Fresh server title", "content": markdown,
                    "created_at": "2026-11-07T10:00:00Z", "updated_at": "2026-11-07T10:00:00Z",
                ]
                return .init(
                    statusCode: 200, headers: ["Content-Type": "application/json"],
                    body: try! JSONSerialization.data(withJSONObject: object), error: nil)
            }
            if request.url?.path.contains("children") == true {
                return .init(statusCode: 200, headers: [:], body: Data("{\"count\":0,\"results\":[]}".utf8), error: nil)
            }
            let isConfig =
                request.url?.path.hasSuffix("config") == true || request.url?.path.hasSuffix("config/") == true
            let object = isConfig ? ["RELEASE_VERSION": version] : ["doc": state.base64EncodedString()]
            let responseGate = isConfig ? configGate : gate
            return .init(
                statusCode: isConfig ? 200 : status, headers: ["Content-Type": "application/json"],
                body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), error: nil,
                releasedBy: responseGate, onCompletion: responseGate == nil ? nil : onGatedCompletion)
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

    private func makeFixture(
        connectivity: ConnectivityMonitor? = nil, entryIntent: NewDocumentEntryIntent? = nil
    ) -> Fixture {
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
            entryIntent: entryIntent,
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
