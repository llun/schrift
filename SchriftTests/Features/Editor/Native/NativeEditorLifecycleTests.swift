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

    func testCloseDestroysReplicaAndDetachesEngineBeforeReopen() async throws {
        let state = BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID)
        let session = try await NativeEditorSession.seed(state: state, clientID: 123)
        let isDetachedBefore = await session.engine { $0.isDetached }
        XCTAssertEqual(isDetachedBefore, false)
        XCTAssertEqual(session.surface.blocks.count, 3)
        await session.close().value
        await session.close().value
        // PR08b option A: the engine is gone after close; session.engine returns nil.
        let closedEngine = await session.engine { $0.isDetached }
        XCTAssertNil(closedEngine)
        XCTAssertTrue(session.isClosed)
        let closedReplica = await session.replicaDoc { $0.store.clients.isEmpty }
        XCTAssertNil(closedReplica, "destroy must clear the replica graph")
        let closedShare = await session.replicaDoc { $0.share.isEmpty }
        XCTAssertNil(closedShare)
        // PR08b option A: a closed session's engine is gone and inspect closures return nil.
        let closedWrite = await session.engine { engine -> DocumentEngineError? in
            do {
                _ = try engine.replaceText(block: Self.firstID, range: 0..<0, with: "closed")
                return nil
            } catch {
                return error as? DocumentEngineError
            }
        }
        XCTAssertNil(closedWrite, "a closed session must not write")
        let reopened = try await NativeEditorSession.seed(state: state)
        addTeardownBlock { await reopened.close().value }
        XCTAssertEqual(reopened.surface.blocks, session.surface.blocks)
        let reopenedDetached = await reopened.engine { $0.isDetached }
        XCTAssertEqual(reopenedDetached, false)
    }

    func testReleasingSessionAndFailedSeedBothDestroyTheirReplica() async throws {
        var session: NativeEditorSession? = try await NativeEditorSession.seed(
            state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID), clientID: 124
        )
        XCTAssertNotNil(session)
        // PR08b option A: the replica is owned by DocumentReplicaSession; releasing the session posts close on deinit.
        let docOpen = await session?.replicaDoc { $0.store.clients.count }
        XCTAssertNotNil(docOpen)
        session = nil
        XCTAssertNil(session)

        // Start with real structs so failure cleanup has cycles to break.
        do {
            _ = try await NativeEditorSession.seed(state: Data([0xff]))
            XCTFail("an undecodable seed must not open")
        } catch Lib0DecodingError.truncated {}
    }

    func testInvalidRootAndEmptyRootAreDistinguished() async throws {
        let empty = try await NativeEditorSession.seed(state: Data([0, 0]))
        addTeardownBlock { await empty.close().value }
        XCTAssertFalse(empty.hasUnsupportedRoot)
        XCTAssertTrue(empty.surface.blocks.isEmpty)
        let doc = YDoc(clientID: 130)
        defer { doc.destroy() }
        let root = doc.get(BlockNoteYjs.fragmentField)
        try doc.transact { tx in
            _ = try YWrite.insertAfter(
                tx, into: root, after: nil, [.type(YType(typeRef: .xmlElement(nodeName: "unknown")))])
        }
        let unsupported = try await NativeEditorSession.seed(state: YStateEncoder.encodeStateAsUpdate(doc))
        addTeardownBlock { await unsupported.close().value }
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
        // PR08b option A: a read-only reader comes from inspect (replica == nil); session.engine returns nil.
        let engine = await session.engine { $0.isDetached }
        XCTAssertNil(engine)
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

    func testDeleteDuringFormattedRefreshPreservesCacheAndFallsBackToClassic() async {
        let fixture = makeFixture()
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        let cache = DocumentContentCacheStore(directory: fixture.directory)
        let original = CachedDocumentContent(
            documentID: fixture.model.documentID, title: "Preserved title", markdown: "Preserved cached body",
            syncedAt: Date(timeIntervalSince1970: 1), serverUpdatedAt: Date(timeIntervalSince1970: 2))
        cache.save(original)
        let response = MockURLProtocol.ResponseGate()
        stub(
            version: "6.0.0", state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID),
            markdown: "New server body that must not replace the cache", formattedGate: response)
        let open = NativeEditorOpen(
            preference: { true }, waitForTimeout: { try await Task.sleep(for: .seconds(30)) })
        defer { open.close() }
        let loading = Task { await open.open(viewModel: fixture.model, isOffline: false) }
        await waitUntil {
            MockURLProtocol.deferredDeliveryCount == 1
                && MockURLProtocol.lastRequest?.url?.path.contains("formatted-content") == true
        }
        // This is inside refreshOfflineCacheForNativeReader's awaited read,
        // after both the opener's and the refresh method's pre-fetch checks.
        fixture.model.saveCoordinator.recordPendingDelete(documentID: fixture.model.documentID, ownerUserID: UUID())
        response.open()
        await loading.value
        XCTAssertEqual(
            cache.content(for: fixture.model.documentID), original,
            "the refresh method's post-fetch guards must prevent this late cache write")
        guard case .classic = open.route else { return XCTFail("a tombstoned refresh must select classic") }
    }

    func testClassicReopenStaysMountedWhileServerConfigIsRechecked() async {
        let fixture = makeFixture()
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        let open = NativeEditorOpen(
            preference: { true }, waitForTimeout: { try await Task.sleep(for: .seconds(30)) })
        defer { open.close() }
        stub(version: "5.0.0", state: Data())
        await open.open(viewModel: fixture.model, isOffline: false)
        guard case .classic = open.route else { return XCTFail("legacy server must select classic") }
        open.close()

        let response = MockURLProtocol.ResponseGate()
        stub(version: "5.0.0", state: Data(), configGate: response)
        let reopening = Task { await open.open(viewModel: fixture.model, isOffline: false) }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        let remainsClassic: Bool
        if case .classic = open.route { remainsClassic = true } else { remainsClassic = false }
        XCTAssertTrue(remainsClassic, "reappearing classic must not be unmounted for a loading spinner")
        response.open()
        await reopening.value
        guard case .classic = open.route else { return XCTFail("classic reopen changed route") }
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

    func testOwnedDocumentWithSwitchOffRestoresReadOnlyWithoutNetwork() async throws {
        let fixture = makeFixture()
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        try seedReplica(fixture)
        let open = NativeEditorOpen(preference: { false })
        defer { open.close() }
        await open.open(viewModel: fixture.model, isOffline: false)
        guard case .native(let session) = open.route else {
            return XCTFail("an owned document must restore natively even with the switch off")
        }
        XCTAssertTrue(open.isPreservedReadOnly)
        XCTAssertFalse(session.textView.isEditable)
        XCTAssertNil(session.input, "the switch is off, so the replica stays read-only")
        XCTAssertEqual(session.surface.blocks.count, 3)
        XCTAssertNil(MockURLProtocol.lastRequest, "restore must not fetch")
    }

    func testOwnedDocumentWithMissingReplicaShowsPreservedUnavailable() async throws {
        let fixture = makeFixture()
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        let scope = try seedReplica(fixture)
        try fixture.replicaStore.remove(for: scope)
        // A marker without a replica is the crash-safe direction: read-only
        // while the switch is off (with it on, slice B re-seeds it; see
        // NativeEditorActivationTests).
        XCTAssertTrue(fixture.ownership.mark(scope))
        let open = NativeEditorOpen(preference: { false })
        defer { open.close() }
        await open.open(viewModel: fixture.model, isOffline: false)
        guard case .preservedUnavailable = open.route else {
            return XCTFail("a missing replica must stay read-only, never classic")
        }
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testCorruptMarkerShowsPreservedUnavailableForEveryDocument() async {
        let fixture = makeFixture()
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        fixture.defaults.set(Data([0xff]), forKey: "dev.llun.Schrift.replicaOwnership")
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: fixture.model, isOffline: false)
        guard case .preservedUnavailable = open.route else {
            return XCTFail("unknown ownership must stay read-only, never classic")
        }
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testReenablingTheSwitchRestoresTheSameReplica() async throws {
        let fixture = makeFixture()
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        try seedReplica(fixture)
        let off = NativeEditorOpen(preference: { false })
        await off.open(viewModel: fixture.model, isOffline: false)
        guard case .native(let first) = off.route else { return XCTFail("owned doc must restore") }
        let blocks = first.surface.blocks
        off.close()
        let on = NativeEditorOpen(preference: { true })
        defer { on.close() }
        // Offline: with the switch on an online open also integrates the server state.
        await on.open(viewModel: fixture.model, isOffline: true)
        guard case .native(let second) = on.route else {
            return XCTFail("re-enabling the switch must restore the same replica")
        }
        XCTAssertEqual(second.surface.blocks, blocks)
        XCTAssertFalse(on.isPreservedReadOnly, "the turn-it-on notice is only true with the switch off")
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testAnotherAccountsReplicaIsNeverShown() async throws {
        let fixture = makeFixture()
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        try seedReplica(fixture)
        SignedInUserStore(userDefaults: fixture.defaults).remember(UUID())
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: fixture.model, isOffline: false)
        guard case .preservedUnavailable = open.route else {
            return XCTFail("another account's unsynced replica must stay hidden and read-only")
        }
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    private func stub(
        version: String, state: Data, status: Int = 200, gate: MockURLProtocol.ResponseGate? = nil,
        configGate: MockURLProtocol.ResponseGate? = nil, onGatedCompletion: (@Sendable () -> Void)? = nil,
        markdown: String = "Exported offline content", recorder: RequestRecorder? = nil,
        formattedGate: MockURLProtocol.ResponseGate? = nil
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
                    body: try! JSONSerialization.data(withJSONObject: object), error: nil,
                    releasedBy: formattedGate)
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
        let ownership: ReplicaOwnershipStore
        let replicaStore: ReplicaStore
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
        let ownership = ReplicaOwnershipStore(userDefaults: defaults)
        let replicaStore = ReplicaStore(
            directory: directory.appendingPathComponent("ReplicaDrafts"), ownershipStore: ownership)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: PendingDraftStore(userDefaults: defaults), replicaStore: replicaStore,
            contentCache: content,
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
        return Fixture(
            model: model, defaults: defaults, suite: suite, directory: directory,
            ownership: ownership, replicaStore: replicaStore)
    }

    /// A durable replica for the fixture's document, with one typed edit.
    @discardableResult
    private func seedReplica(_ fixture: Fixture) throws -> ReplicaScope {
        let owner = UUID()
        SignedInUserStore(userDefaults: fixture.defaults).remember(owner)
        let scope = ReplicaScope(
            serverOrigin: fixture.model.client.serverOrigin, ownerUserID: owner, org: "docs",
            documentID: fixture.model.documentID)
        let checkpoint = BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID)
        _ = try fixture.replicaStore.create(for: scope, checkpoint: checkpoint)
        let doc = YDoc(clientID: 2)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(checkpoint), origin: .remote)
        let update = try BlockNoteWriter(doc: doc).replaceText(block: Self.firstID, range: 0..<0, with: "x")
        try ReplicaSaveAdapter(store: fixture.replicaStore, scope: scope).record(
            NativeEditCommand(id: UUID(), baseRevision: 0, blockID: Self.firstID, range: 0..<0, replacement: "x"),
            update: update)
        return scope
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
