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
        // The switch is on by default now; this test drives the classic route explicitly.
        fixture.defaults.set(false, forKey: NativeEditorPreference.key)
        let open = NativeEditorOpen(preference: {
            reads += 1
            return NativeEditorPreference.isEnabled(fixture.defaults)
        })
        defer { open.close() }
        XCTAssertEqual(reads, 1, "construction only chooses the initial renderer")
        XCTAssertFalse(NativeEditorPreference.isEnabled(fixture.defaults))
        await open.open(viewModel: fixture.model, isOffline: false)
        guard case .classic = open.route else { return XCTFail("an explicit off must keep classic") }
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

    func testSwitchOffKeepsClassicWithoutFetching() async {
        let fixture = makeFixture()
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        let off = NativeEditorOpen(preference: { false })
        await off.open(viewModel: fixture.model, isOffline: false)
        guard case .classic = off.route else { return XCTFail("off route changed") }
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testOfflineNeverOpenedShowsGoOnlineAndRetriesOnReconnect() async {
        let fixture = makeFixture()
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: fixture.model, isOffline: true)
        guard case .unavailable(.offlineNeverOpened) = open.route else {
            return XCTFail("offline with nothing cached must show the go-online state")
        }
        XCTAssertTrue(fixture.model.isNativeRouteActive)
        XCTAssertNil(MockURLProtocol.lastRequest, "nothing cached means nothing to fetch")

        stub(version: "6.0.0", state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID))
        await open.retry(viewModel: fixture.model, isOffline: false)
        guard case .native = open.route else { return XCTFail("Retry must open natively once online") }
    }

    func testOfflineWithCachedClassicCopyStaysClassic() async {
        let fixture = makeFixture()
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        DocumentContentCacheStore(directory: fixture.directory).save(
            CachedDocumentContent(
                documentID: fixture.model.documentID, title: "Cached", markdown: "Cached body",
                syncedAt: Date()))
        let open = NativeEditorOpen(preference: { true })
        await open.open(viewModel: fixture.model, isOffline: true)
        guard case .classic = open.route else {
            return XCTFail("a cached classic copy keeps the classic reader")
        }
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
        guard case .classic = open.route else {
            return XCTFail("an in-flight response must not install a tombstoned document")
        }
    }

    func testUnreachableServerShowsGoOnlineWithoutPrefetching() async {
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
        defer { open.close() }
        await open.open(viewModel: fixture.model, isOffline: false)
        guard case .unavailable(.offlineNeverOpened) = open.route else {
            return XCTFail("an unreachable server with nothing cached must show the go-online state")
        }
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testSlowFetchStaysLoadingPastTheOldDeadlineAndOpensNative() async {
        let fixture = makeFixture()
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        let gate = MockURLProtocol.ResponseGate()
        stub(version: "6.0.0", state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID), gate: gate)
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        let loading = Task { await open.open(viewModel: fixture.model, isOffline: false) }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        // The old three-second deadline selected classic here. Real time is the
        // only way to prove a deadline is gone; the fetch is held, not slow.
        try? await Task.sleep(for: .seconds(3.2))
        guard case .loading = open.route else { return XCTFail("a held fetch must stay loading") }
        gate.open()
        await loading.value
        guard case .native = open.route else { return XCTFail("the late answer must open natively") }
    }

    func testLegacyServerKeepsClassic() async {
        let fixture = makeFixture()
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        stub(version: "5.0.0", state: Data())
        let open = NativeEditorOpen(preference: { true })
        await open.open(viewModel: fixture.model, isOffline: false)
        guard case .classic = open.route else { return XCTFail("a legacy server has no native path") }
    }

    func testFetchFailureShowsRetryableNativeErrorAndRetryOpens() async {
        for (configStatus, status, body) in [
            (500, 200, Data()), (200, 500, Data()), (200, 200, Data("invalid".utf8)),
        ] {
            let fixture = makeFixture()
            defer {
                fixture.clean()
                MockURLProtocol.reset()
            }
            stub(version: "6.0.0", state: body, status: status, configStatus: configStatus)
            let open = NativeEditorOpen(preference: { true })
            defer { open.close() }
            await open.open(viewModel: fixture.model, isOffline: false)
            let expected: NativeOpenUnavailable =
                configStatus == 500 || status == 500 ? .openFailed : .unreadableState
            guard case .unavailable(let reason) = open.route else {
                return XCTFail("a failed fetch must show the native error state, never classic")
            }
            XCTAssertEqual(reason, expected)
            XCTAssertTrue(fixture.model.isNativeRouteActive)

            stub(version: "6.0.0", state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID))
            await open.retry(viewModel: fixture.model, isOffline: false)
            guard case .native = open.route else { return XCTFail("Retry must open once the server recovers") }
        }
    }

    /// A Retry that lands after the page closed (the user navigated back) does nothing:
    /// it never installs a session for a screen that is gone.
    func testRetryAfterCloseDoesNotReopen() async {
        let fixture = makeFixture()
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        stub(version: "6.0.0", state: Data(), status: 500)
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: fixture.model, isOffline: false)
        guard case .unavailable(.openFailed) = open.route else { return XCTFail("expected the error state") }
        open.close()
        let recorder = RequestRecorder()
        stub(
            version: "6.0.0", state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID),
            recorder: recorder)
        await open.retry(viewModel: fixture.model, isOffline: false)
        guard case .loading = open.route else { return XCTFail("a late Retry must not reopen: \(open.route)") }
        XCTAssertTrue(recorder.methods.isEmpty, "a late Retry must not fetch")
    }

    /// Pending local work that arrives mid-fetch routes to `.waitingClassicEdits` when the
    /// native switch is on, even when the fetch then fails.
    func testLocalDraftArrivingBeforeAFailedFetchRoutesToWaitingClassicEdits() async {
        let fixture = makeFixture()
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        // A draft is shown only to the signed-in account it belongs to.
        SignedInUserStore(userDefaults: fixture.defaults).remember(UUID())
        let gate = MockURLProtocol.ResponseGate()
        stub(version: "6.0.0", state: Data(), status: 500, gate: gate)
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        let loading = Task { await open.open(viewModel: fixture.model, isOffline: false) }
        await waitUntil { MockURLProtocol.lastRequest?.url?.path.contains("/collaboration/ydoc/") == true }
        PendingDraftStore(userDefaults: fixture.defaults).save(
            PendingDraft(
                documentID: fixture.model.documentID, title: "Local", markdown: "Arrived while loading",
                updatedAt: Date()))
        gate.open()
        await loading.value
        guard case .waitingClassicEdits = open.route else {
            return XCTFail("a failed fetch must route a local classic draft to .waitingClassicEdits: \(open.route)")
        }
    }

    func testCacheRefreshFailureStillInstallsTheNativeSession() async {
        let fixture = makeFixture()
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        stub(
            version: "6.0.0", state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID),
            formattedStatus: 500)
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: fixture.model, isOffline: false)
        guard case .native = open.route else {
            return XCTFail("the classic cache refresh must not block the native session")
        }
    }

    func testSupersededOpenDoesNotFlipToClassic() async {
        let fixture = makeFixture()
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        let gate = MockURLProtocol.ResponseGate()
        stub(version: "6.0.0", state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID), gate: gate)
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        let loading = Task { await open.open(viewModel: fixture.model, isOffline: false) }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        // Another account signs in while the fetch is in flight.
        SignedInUserStore(userDefaults: fixture.defaults).remember(UUID())
        gate.open()
        await loading.value
        guard case .loading = open.route else {
            return XCTFail("a superseded open must leave the route to the newer open, never classic")
        }
    }

    /// Going offline while the fetch is in flight drops its answer; with no deadline
    /// to fall back on, the route settles from the device instead of spinning: a page
    /// with nothing cached says "Go online", one with a cached classic copy goes classic.
    func testGoingOfflineMidFetchSettlesTheRouteInsteadOfSpinning() async {
        for cached in [false, true] {
            let fixture = makeFixture()
            defer {
                fixture.clean()
                MockURLProtocol.reset()
            }
            if cached {
                DocumentContentCacheStore(directory: fixture.directory).save(
                    CachedDocumentContent(
                        documentID: fixture.model.documentID, title: "Cached", markdown: "Cached body",
                        syncedAt: Date(timeIntervalSince1970: 1), serverUpdatedAt: Date(timeIntervalSince1970: 2)))
            }
            let gate = MockURLProtocol.ResponseGate()
            stub(
                version: "6.0.0", state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID), gate: gate
            )
            let open = NativeEditorOpen(preference: { true })
            let loading = Task { await open.open(viewModel: fixture.model, isOffline: false) }
            await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
            fixture.defaults.set(true, forKey: "schrift.workOffline")
            fixture.model.availability.preferencesChanged()
            gate.open()
            await loading.value
            switch (cached, open.route) {
            case (false, .unavailable(.offlineNeverOpened)), (true, .classic): break
            default: XCTFail("cached \(cached): the route must settle, got \(open.route)")
            }
            open.close()
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
            await waitUntil {
                cache.content(for: fixture.model.documentID)?.markdown == "Fresh server-exported offline text"
            }
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

    func testDeleteDuringFormattedRefreshPreservesCacheAndReopenFallsBackToClassic() async {
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
        let settled = Counter()
        stub(
            version: "6.0.0", state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID),
            onGatedCompletion: { _ = settled.next() },
            markdown: "New server body that must not replace the cache", formattedGate: response)
        let open = NativeEditorOpen(preference: { true })
        defer {
            response.open()
            open.close()
        }
        await open.open(viewModel: fixture.model, isOffline: false)
        guard case .native = open.route else {
            return XCTFail("first open must select .native before the deferred formatted-content refresh completes")
        }
        await waitUntil {
            MockURLProtocol.deferredDeliveryCount == 1
                && MockURLProtocol.lastRequest?.url?.path.contains("formatted-content") == true
        }
        // This is inside refreshOfflineCacheForNativeReader's awaited read,
        // after both the opener's and the refresh method's pre-fetch checks.
        fixture.model.saveCoordinator.recordPendingDelete(documentID: fixture.model.documentID, ownerUserID: UUID())
        response.open()
        await waitUntil { settled.current == 1 }
        await waitAndConfirmNever {
            cache.content(for: fixture.model.documentID) != original
        }
        XCTAssertEqual(
            cache.content(for: fixture.model.documentID), original,
            "the refresh method's post-fetch guards must prevent this late cache write")
        // Reopening with the pending delete recorded routes back to classic.
        open.close()
        await open.open(viewModel: fixture.model, isOffline: false)
        guard case .classic = open.route else {
            return XCTFail("reopening a pending-delete document keeps the classic owner")
        }
    }

    func testClassicReopenStaysMountedWhileServerConfigIsRechecked() async {
        let fixture = makeFixture()
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        let open = NativeEditorOpen(preference: { true })
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

    func testPendingCreationIntentOpensNativelyOnDocs6AndFallsBackToClassicWhenDisabled() async {
        let intent = NewDocumentEntryIntent()
        let fixture = makeFixture(entryIntent: intent)
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        stub(version: "6.0.0", state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID), markdown: "")

        // With native disabled, the creation intent still falls back to editable classic without native fetches.
        let disabledOpen = NativeEditorOpen(preference: { false })
        defer { disabledOpen.close() }
        await disabledOpen.open(viewModel: fixture.model, isOffline: false)
        guard case .classic = disabledOpen.route else { return XCTFail("disabled native must keep classic") }
        XCTAssertNil(MockURLProtocol.lastRequest)
        XCTAssertTrue(intent.isPending)

        // With native enabled on Docs 6, the new server document opens natively rather than falling back to classic.
        let nativeIntent = NewDocumentEntryIntent()
        let nativeFixture = makeFixture(entryIntent: nativeIntent, nativeEditorEnabled: { true })
        defer { nativeFixture.clean() }
        stub(version: "6.0.0", state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID), markdown: "")
        let enabledOpen = NativeEditorOpen(preference: { true })
        defer { enabledOpen.close() }
        await enabledOpen.open(viewModel: nativeFixture.model, isOffline: false)
        guard case .native = enabledOpen.route else {
            return XCTFail("creation intent on Docs 6 must open natively instead of falling back to classic")
        }
        XCTAssertTrue(nativeFixture.model.isNativeRouteActive)
    }

    func testPendingLocalDraftRoutesToWaitingClassicWhenSwitchOnAndClassicWhenOff() async {
        let fixture = makeFixture()
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        SignedInUserStore(userDefaults: fixture.defaults).remember(UUID())
        PendingDraftStore(userDefaults: fixture.defaults).save(
            PendingDraft(documentID: fixture.model.documentID, title: "Local", markdown: "Unsynced", updatedAt: Date()))
        let openOn = NativeEditorOpen(preference: { true })
        defer { openOn.close() }
        await openOn.open(viewModel: fixture.model, isOffline: true)
        guard case .waitingClassicEdits = openOn.route else {
            return XCTFail("waiting classic draft must open on .waitingClassicEdits with switch on")
        }
        XCTAssertNil(MockURLProtocol.lastRequest)
        openOn.close()

        let openOff = NativeEditorOpen(preference: { false })
        defer { openOff.close() }
        await openOff.open(viewModel: fixture.model, isOffline: false)
        guard case .classic = openOff.route else {
            return XCTFail("switch off must keep classic route for pending local draft")
        }
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

    func testLocalDraftArrivingDuringRawFetchRoutesToWaitingClassicEdits() async {
        let fixture = makeFixture()
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        // A draft is shown only to the signed-in account it belongs to.
        SignedInUserStore(userDefaults: fixture.defaults).remember(UUID())
        let gate = MockURLProtocol.ResponseGate()
        stub(version: "6.0.0", state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID), gate: gate)
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        let loading = Task { await open.open(viewModel: fixture.model, isOffline: false) }
        await waitUntil { MockURLProtocol.lastRequest?.url?.path.contains("/collaboration/ydoc/") == true }
        PendingDraftStore(userDefaults: fixture.defaults).save(
            PendingDraft(
                documentID: fixture.model.documentID, title: "Local", markdown: "Arrived while loading",
                updatedAt: Date()))
        gate.open()
        await loading.value
        guard case .waitingClassicEdits = open.route else {
            return XCTFail(
                "an in-flight baseline must route an arrived local draft to .waitingClassicEdits: \(open.route)")
        }
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
        await open.open(viewModel: fixture.model, isOffline: false, canUpdate: true)
        guard case .native(let session) = open.route else {
            return XCTFail("an owned document must restore natively even with the switch off")
        }
        XCTAssertEqual(open.editUnavailableReason, .nativeSwitchOff)
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
        await open.open(viewModel: fixture.model, isOffline: false, canUpdate: true)
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
        XCTAssertNotEqual(
            on.editUnavailableReason, .nativeSwitchOff, "the turn-it-on notice is only true with the switch off")
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

    func testLocalCreatedDocumentOpensNativelyOfflineWithoutHTTPOrWebSocketCalls() async throws {
        let suite = "LocalCreateNativeLifecycle.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            MockURLProtocol.reset()
        }
        let owner = UUID()
        SignedInUserStore(userDefaults: defaults).remember(owner)
        let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
        let client = DocsAPIClient(
            baseURL: baseURL, session: MockURLProtocol.makeSession(),
            cookieProvider: { [] })
        ServerConfigStore(userDefaults: defaults).remember(
            ServerConfig(releaseVersion: "6.0.0", collaborationWsUrl: nil),
            forServerOrigin: client.serverOrigin)
        let content = DocumentContentCacheStore(directory: directory)
        let children = DocumentChildrenCacheStore(userDefaults: defaults)
        let ownership = ReplicaOwnershipStore(userDefaults: defaults)
        let replicaStore = ReplicaStore(
            directory: directory.appendingPathComponent("ReplicaDrafts"), ownershipStore: ownership)
        let listCache = DocumentCacheStore(userDefaults: defaults)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: PendingDraftStore(userDefaults: defaults), replicaStore: replicaStore,
            contentCache: content,
            createStore: PendingDocumentCreateStore(userDefaults: defaults),
            deleteStore: PendingDocumentDeleteStore(userDefaults: defaults),
            attachmentStore: PendingAttachmentStore(
                userDefaults: defaults, directory: directory.appendingPathComponent("attachments")),
            listCache: listCache, childrenCache: children, backgroundTasks: .noop, sleep: neverSleep)
        coordinator.nativeEditorEnabled = { true }

        let localDoc = coordinator.createLocalDocument(title: "", parentID: nil, ownerUserID: owner)
        let model = EditorViewModel(
            client: client, documentID: localDoc.id, title: localDoc.title ?? "", saveCoordinator: coordinator,
            signedInUser: SignedInUserStore(userDefaults: defaults), contentCache: content, childrenCache: children,
            listCache: listCache, availability: OnlineAvailability(userDefaults: defaults))

        let recorder = RequestRecorder()
        let wsAttempted = Counter()
        stub(
            version: "6.0.0", state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID),
            recorder: recorder)

        let open = NativeEditorOpen(preference: { true })
        open.collaboration = DocumentCollaborationManager(
            serverBaseURL: baseURL,
            cookieProvider: { [] },
            featureEnabled: { true },
            isOffline: { false },
            serverConfigProvider: { nil },
            socketFactory: { _ in
                _ = wsAttempted.next()
                return FakeWebSocket()
            })
        defer { open.close() }

        // Both offline and online requests for a localID must open from the local replica
        // without issuing any document HTTP request or dialing a WebSocket for the localID.
        await open.open(viewModel: model, isOffline: true, canUpdate: true)
        guard case .native(let session) = open.route else {
            return XCTFail("local-created Docs 6 document must open natively offline")
        }
        XCTAssertTrue(model.isNativeRouteActive)
        XCTAssertTrue(recorder.methods.isEmpty)

        session.textView.selectedRange = NSRange(location: 0, length: 0)
        session.input?.textViewDidChangeSelection(session.textView)
        session.textView.insertText("Offline draft ")
        await session.settle()
        XCTAssertTrue(session.surface.blocks.first?.runs.map(\.text).joined().hasPrefix("Offline draft ") == true)

        open.close()
        await open.open(viewModel: model, isOffline: false)
        guard case .native = open.route else {
            return XCTFail("local-created document must stay offline-local in native even when connectivity is online")
        }
        XCTAssertTrue(recorder.methods.isEmpty, "must never hit HTTP routes with a localID")
        XCTAssertEqual(wsAttempted.current, 0, "must never dial WebSocket with a localID")
    }

    func testOfflineDocs6UnmigratedMarkdownCacheDisablesStartEditingAndPreservesPendingDraftException() async throws {
        let offlineConnectivity = ConnectivityMonitor(
            monitoring: NetworkPathMonitoring { onChange in
                onChange(false)
                return {}
            })

        // 1. Docs 6 cached + native enabled + unmigrated cached Markdown only -> read-only guard.
        let guarded = makeFixture(connectivity: offlineConnectivity, nativeEditorEnabled: { true })
        defer {
            guarded.clean()
            MockURLProtocol.reset()
        }
        await waitUntil { guarded.model.availability.isOffline }
        ServerConfigStore(userDefaults: guarded.defaults).remember(
            ServerConfig(releaseVersion: "6.0.0", collaborationWsUrl: nil),
            forServerOrigin: guarded.model.client.serverOrigin)
        DocumentContentCacheStore(directory: guarded.directory).save(
            CachedDocumentContent(
                documentID: guarded.model.documentID, title: "Cached", markdown: "Read only copy",
                syncedAt: Date(), serverUpdatedAt: Date()))
        await guarded.model.load()
        XCTAssertTrue(guarded.model.isNativeBaselineRequiredOffline)
        XCTAssertTrue(guarded.model.isNativeLimitedOfflineRead)
        XCTAssertFalse(guarded.model.canStartEditing, "unmigrated Markdown cache cannot enter classic editing offline")

        // 2. Classic PendingDraft on disk stays editable offline.
        let drafted = makeFixture(connectivity: offlineConnectivity, nativeEditorEnabled: { true })
        defer { drafted.clean() }
        await waitUntil { drafted.model.availability.isOffline }
        ServerConfigStore(userDefaults: drafted.defaults).remember(
            ServerConfig(releaseVersion: "6.0.0", collaborationWsUrl: nil),
            forServerOrigin: drafted.model.client.serverOrigin)
        SignedInUserStore(userDefaults: drafted.defaults).remember(UUID())
        let pendingStore = PendingDraftStore(userDefaults: drafted.defaults)
        pendingStore.save(
            PendingDraft(
                documentID: drafted.model.documentID, title: "Drafted", markdown: "Offline classic draft",
                updatedAt: Date()))
        await drafted.model.load()
        XCTAssertFalse(drafted.model.isNativeLimitedOfflineRead)
        XCTAssertTrue(drafted.model.canStartEditing, "classic PendingDraft must remain editable offline")

        // 3. Default-off native preference leaves classic offline editing unchanged.
        let defaultOff = makeFixture(connectivity: offlineConnectivity, nativeEditorEnabled: { false })
        defer { defaultOff.clean() }
        await waitUntil { defaultOff.model.availability.isOffline }
        ServerConfigStore(userDefaults: defaultOff.defaults).remember(
            ServerConfig(releaseVersion: "6.0.0", collaborationWsUrl: nil),
            forServerOrigin: defaultOff.model.client.serverOrigin)
        DocumentContentCacheStore(directory: defaultOff.directory).save(
            CachedDocumentContent(
                documentID: defaultOff.model.documentID, title: "DefaultOff", markdown: "Editable classic",
                syncedAt: Date(), serverUpdatedAt: Date()))
        await defaultOff.model.load()
        XCTAssertFalse(defaultOff.model.isNativeLimitedOfflineRead)
        XCTAssertTrue(defaultOff.model.canStartEditing)
    }

    func testStaleFormattedContentLoadRefreshAndApplyAreGuardedWhileNativeActiveOrOwned() async throws {
        let fixture = makeFixture(nativeEditorEnabled: { true })
        defer {
            fixture.clean()
            MockURLProtocol.reset()
        }
        try seedReplica(fixture)
        stub(
            version: "6.0.0",
            state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID),
            markdown: "Initial server body"
        )

        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: fixture.model, isOffline: false)
        XCTAssertTrue(fixture.model.isNativeRouteActive)

        // Late formatted-content responses must never overwrite an active or owned native session.
        stub(
            version: "6.0.0",
            state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID),
            markdown: "Stale server body"
        )

        // Attempt late classic load/refresh while native route is active.
        fixture.model.updateNativeTitle("Native active title") {}
        await fixture.model.load()
        await fixture.model.refresh()
        XCTAssertFalse(fixture.model.isEditing, "classic editing must not activate over an active native route")
        XCTAssertNotEqual(fixture.model.rawMarkdown, "Stale server body")
        XCTAssertEqual(fixture.model.title, "Native active title")

        // Even after closing the native route, native-owned docs block classic load/refresh and preserve pending title edits.
        open.close()
        XCTAssertFalse(fixture.model.isNativeRouteActive)
        XCTAssertTrue(fixture.model.saveCoordinator.isNativeOwned(documentID: fixture.model.documentID))
        fixture.model.updateNativeTitle("User edited native title") {}
        await fixture.model.load()
        await fixture.model.refresh()
        XCTAssertEqual(fixture.model.title, "User edited native title")
        XCTAssertNotEqual(fixture.model.rawMarkdown, "Stale server body")
        XCTAssertFalse(fixture.model.isEditing)
    }

    private func stub(
        version: String, state: Data, status: Int = 200, gate: MockURLProtocol.ResponseGate? = nil,
        configGate: MockURLProtocol.ResponseGate? = nil, onGatedCompletion: (@Sendable () -> Void)? = nil,
        markdown: String = "Exported offline content", recorder: RequestRecorder? = nil,
        formattedGate: MockURLProtocol.ResponseGate? = nil, configStatus: Int = 200,
        formattedStatus: Int = 200
    ) {
        MockURLProtocol.stubHandler = { request in
            recorder?.record(request)
            if request.url?.path.contains("formatted-content") == true {
                guard formattedStatus == 200 else {
                    return .init(statusCode: formattedStatus, headers: [:], body: Data(), error: nil)
                }
                let id = request.url!.path.split(separator: "/").first { UUID(uuidString: String($0)) != nil }!
                let object: [String: Any] = [
                    "id": String(id), "title": "Fresh server title", "content": markdown,
                    "created_at": "2026-11-07T10:00:00Z", "updated_at": "2026-11-07T10:00:00Z",
                ]
                return .init(
                    statusCode: 200, headers: ["Content-Type": "application/json"],
                    body: try! JSONSerialization.data(withJSONObject: object), error: nil,
                    releasedBy: formattedGate, onCompletion: formattedGate == nil ? nil : onGatedCompletion)
            }
            if request.url?.path.contains("children") == true {
                return .init(statusCode: 200, headers: [:], body: Data("{\"count\":0,\"results\":[]}".utf8), error: nil)
            }
            let isConfig =
                request.url?.path.hasSuffix("config") == true || request.url?.path.hasSuffix("config/") == true
            if isConfig, configStatus != 200 {
                return .init(statusCode: configStatus, headers: [:], body: Data(), error: nil)
            }
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
        connectivity: ConnectivityMonitor? = nil,
        entryIntent: NewDocumentEntryIntent? = nil,
        nativeEditorEnabled: (@Sendable () -> Bool)? = nil
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
            listCache: DocumentCacheStore(userDefaults: defaults), childrenCache: children, backgroundTasks: .noop,
            sleep: neverSleep)
        coordinator.nativeEditorEnabled = nativeEditorEnabled ?? { false }
        let model = EditorViewModel(
            client: client, documentID: UUID(), title: "Fixture", saveCoordinator: coordinator,
            entryIntent: entryIntent,
            signedInUser: SignedInUserStore(userDefaults: defaults), contentCache: content, childrenCache: children,
            listCache: DocumentCacheStore(userDefaults: defaults),
            availability: OnlineAvailability(connectivity: connectivity, userDefaults: defaults),
            nativeEditorEnabled: nativeEditorEnabled)
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
