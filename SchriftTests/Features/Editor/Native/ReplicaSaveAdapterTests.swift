import XCTest

@testable import Schrift

@MainActor
final class ReplicaSaveAdapterTests: DocumentSaveCoordinatorTestCase {
    private let owner = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    private struct Fixture {
        let client: DocsAPIClient
        let coordinator: DocumentSaveCoordinator
        let drafts: PendingDraftStore
        let listCache: DocumentCacheStore
        let contentCache: DocumentContentCacheStore
        let store: ReplicaStore
        let adapter: ReplicaSaveAdapter
        let scope: ReplicaScope
        let checkpoint: Data
        let update: Data
    }

    private func fixture(isHeld: @escaping @MainActor (UUID) -> Bool = { _ in false }) throws -> Fixture {
        let scope = ReplicaScope(
            serverOrigin: "https://docs.example.org", ownerUserID: owner, org: "docs", documentID: documentID)
        let checkpoint = BlockNoteYjs.encode(
            [
                BlockNoteBlock(
                    node: "paragraph",
                    props: DocumentEngineTestCase.paragraphProps, runs: [InlineRun("One")], id: "one")
            ], clientID: 1)
        let doc = YDoc(clientID: 2)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(checkpoint), origin: .remote)
        let update = try BlockNoteWriter(doc: doc).replaceText(block: "one", range: 0..<0, with: "x")
        let store = ReplicaStore(directory: cacheDirectory.appendingPathComponent("ReplicaDrafts"))
        _ = try store.create(for: scope, checkpoint: checkpoint)
        let adapter = ReplicaSaveAdapter(store: store, scope: scope)
        try adapter.record(
            NativeEditCommand(id: UUID(), baseRevision: 0, blockID: "one", range: 0..<0, replacement: "x"),
            update: update)
        let suite = "ReplicaSaveAdapterTests.\(UUID().uuidString)"
        draftSuiteNames.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let drafts = PendingDraftStore(userDefaults: defaults)
        let listCache = DocumentCacheStore(userDefaults: defaults)
        SignedInUserStore(userDefaults: defaults).remember(owner)
        let contentCache = DocumentContentCacheStore(directory: cacheDirectory)
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: drafts, replicaStore: store, contentCache: contentCache,
            listCache: listCache, backgroundTasks: .noop, isLiveReplicaHeld: isHeld)
        return Fixture(
            client: client, coordinator: coordinator, drafts: drafts, listCache: listCache,
            contentCache: contentCache, store: store,
            adapter: adapter, scope: scope, checkpoint: checkpoint, update: update)
    }

    private func stub(
        log: RequestRecorder, bodyStatus: Int = 204, titleStatus: Int = 204, bodyError: URLError? = nil,
        bodyGate: MockURLProtocol.ResponseGate? = nil, titleGate: MockURLProtocol.ResponseGate? = nil,
        responseOwner: UUID? = nil, onBody: (@Sendable (URLRequest) -> Void)? = nil
    ) {
        let ownerID = (responseOwner ?? owner).uuidString
        let formatted = Data(
            """
            {"id":"\(documentID.uuidString)","title":"Doc","content":"xOne",
             "created_at":"2026-01-15T10:30:00Z","updated_at":"2026-01-15T10:30:00Z"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let path = request.url?.absoluteString ?? ""  // `URL.path` drops the trailing slash
            if path.hasSuffix("/config/") {
                return .init(
                    statusCode: 200, headers: [:], body: Data(#"{"RELEASE_VERSION":"6.0.0"}"#.utf8), error: nil)
            }
            if path.hasSuffix("/users/me/") {
                return .init(statusCode: 200, headers: [:], body: Data("{\"id\":\"\(ownerID)\"}".utf8), error: nil)
            }
            if request.httpMethod == "PATCH", path.contains("/collaboration/ydoc/") {
                onBody?(request)
                return .init(statusCode: bodyStatus, headers: [:], body: Data(), error: bodyError, releasedBy: bodyGate)
            }
            if request.httpMethod == "PATCH" {
                return .init(statusCode: titleStatus, headers: [:], body: Data(), error: nil, releasedBy: titleGate)
            }
            if path.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: formatted, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
    }

    private func enqueue(_ f: Fixture, title: String = "Doc") throws {
        try f.coordinator.enqueueReplica(
            adapter: f.adapter, title: title,
            baseline: DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 1), markdown: "One", title: "Doc"))
    }

    private func appendSecond(_ f: Fixture) throws -> Data {
        let doc = YDoc(clientID: 3)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(f.checkpoint), origin: .remote)
        try doc.applyUpdate(YUpdateDecoder.decode(f.update), origin: .remote)
        let update = try BlockNoteWriter(doc: doc).replaceText(block: "one", range: 0..<0, with: "y")
        try f.adapter.record(
            NativeEditCommand(id: UUID(), baseRevision: 1, blockID: "one", range: 0..<0, replacement: "y"),
            update: update)
        return update
    }

    func testJournalAndReferencePrecedeExactDocs6PatchAndAckWaitsForConfirmation() async throws {
        let f = try fixture()
        XCTAssertNil(MockURLProtocol.lastRequest, "journaling itself sends nothing")
        let log = RequestRecorder()
        let gate = MockURLProtocol.ResponseGate()
        defer { gate.open() }
        let expected = f.update
        let path = collaborationYDocPath(org: "docs", documentID: documentID)
        stub(log: log, bodyGate: gate) { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.url?.path, path)
            let json = try? JSONSerialization.jsonObject(with: bodyData(from: request) ?? Data()) as? [String: String]
            XCTAssertEqual(json, ["update": expected.base64EncodedString()])
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Origin"))
        }
        try enqueue(f)
        XCTAssertNotNil(f.drafts.draft(for: documentID)?.replica)
        await waitUntil { log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/") == 1 }
        XCTAssertEqual(try f.store.outbox(for: f.scope)?.updates, [expected])
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/api/v1.0/documents/"), 0)
        gate.open()
        await waitUntil { self.isSaved(f.coordinator.state(for: self.documentID)) }
        XCTAssertNil(try f.store.outbox(for: f.scope))
        XCTAssertNil(f.drafts.draft(for: documentID))
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/content/"), 0)
        XCTAssertEqual(log.count(ofMethod: "PATCH"), 2)
    }

    func testOfflineFailureThenReconnectReplaysRawBytes() async throws {
        let f = try fixture()
        let log = RequestRecorder()
        stub(log: log, bodyError: URLError(.notConnectedToInternet))
        try enqueue(f)
        await waitUntil { self.isPendingSync(f.coordinator.state(for: self.documentID)) }
        XCTAssertEqual(try f.store.outbox(for: f.scope)?.updates, [f.update])
        XCTAssertNotNil(f.drafts.draft(for: documentID)?.replica)
        stub(log: log)
        await f.coordinator.syncPendingDrafts()
        await waitUntil { self.isSaved(f.coordinator.state(for: self.documentID)) }
        XCTAssertNil(try f.store.outbox(for: f.scope))
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/"), 2)
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/content/"), 0)
    }

    func testPermissionAndAuthenticationFailuresRetainRawOutboxAndReference() async throws {
        for status in [401, 403, 404] {
            let f = try fixture()
            let log = RequestRecorder()
            stub(log: log, bodyStatus: status)
            try enqueue(f)
            await waitUntil { self.isFailed(f.coordinator.state(for: self.documentID)) }
            XCTAssertEqual(try f.store.outbox(for: f.scope)?.updates, [f.update])
            XCTAssertNotNil(f.drafts.draft(for: documentID)?.replica)
            XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/api/v1.0/documents/"), 0)
            try FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent("ReplicaDrafts"))
            MockURLProtocol.reset()
        }
    }

    func testNewEditDuringTitleRequestKeepsOutboxDraftAndHonestPendingState() async throws {
        let f = try fixture()
        let log = RequestRecorder()
        let gate = MockURLProtocol.ResponseGate()
        defer { gate.open() }
        stub(log: log, titleGate: gate)
        try enqueue(f)
        await waitUntil { log.count(ofMethod: "PATCH", urlContaining: "/api/v1.0/documents/") == 1 }
        XCTAssertNil(try f.store.outbox(for: f.scope), "body is acknowledged before title")
        let second = try appendSecond(f)
        gate.open()
        await waitUntil { self.isPendingSync(f.coordinator.state(for: self.documentID)) }
        XCTAssertNotNil(f.drafts.draft(for: documentID)?.replica)
        XCTAssertEqual(try f.store.outbox(for: f.scope)?.updates, [second])
        try enqueue(f)
        await waitUntil { self.isSaved(f.coordinator.state(for: self.documentID)) }
        XCTAssertNil(try f.store.outbox(for: f.scope))
        XCTAssertNil(f.drafts.draft(for: documentID))
    }

    func testPartialBatchFailureRetainsEverySequenceForIdempotentReplay() async throws {
        let f = try fixture()
        let second = try appendSecond(f)
        let log = RequestRecorder()
        let counter = Counter()
        let ownerID = owner.uuidString
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let path = request.url?.absoluteString ?? ""  // `URL.path` drops the trailing slash
            if path.hasSuffix("/config/") {
                return .init(
                    statusCode: 200, headers: [:], body: Data(#"{"RELEASE_VERSION":"6.0.0"}"#.utf8), error: nil)
            }
            if path.hasSuffix("/users/me/") {
                return .init(statusCode: 200, headers: [:], body: Data("{\"id\":\"\(ownerID)\"}".utf8), error: nil)
            }
            return .init(statusCode: counter.next() == 1 ? 204 : 503, headers: [:], body: Data(), error: nil)
        }
        try enqueue(f)
        await waitUntil { self.isPendingSync(f.coordinator.state(for: self.documentID)) }
        XCTAssertEqual(try f.store.outbox(for: f.scope)?.updates, [f.update, second])
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/api/v1.0/documents/"), 0)
    }

    func testSameMarkdownDoesNotAcknowledgeANewerRichRevision() async throws {
        let f = try fixture()
        let log = RequestRecorder()
        let gate = MockURLProtocol.ResponseGate()
        defer { gate.open() }
        stub(log: log, titleGate: gate)
        try enqueue(f)
        await waitUntil { log.count(ofMethod: "PATCH", urlContaining: "/api/v1.0/documents/") == 1 }
        let peer = YDoc(clientID: 3)
        defer { peer.destroy() }
        try peer.applyUpdate(YUpdateDecoder.decode(f.checkpoint), origin: .remote)
        try peer.applyUpdate(YUpdateDecoder.decode(f.update), origin: .remote)
        let before = YBlockProjection.projectedMarkdown(YBlockProjection.project(peer))
        let update = try BlockNoteWriter(doc: peer).setBlockType(
            block: "one", to: "paragraph",
            props: [("textAlignment", .string("center"))])
        // The serializer ends with a newline; what matters is that alignment leaves it unchanged.
        XCTAssertEqual(YBlockProjection.projectedMarkdown(YBlockProjection.project(peer)), before)
        try f.adapter.record(
            NativeEditCommand(id: UUID(), baseRevision: 1, blockID: "one", range: 0..<0, replacement: ""),
            update: update)
        gate.open()
        await waitUntil { self.isPendingSync(f.coordinator.state(for: self.documentID)) }
        XCTAssertNotNil(f.drafts.draft(for: documentID)?.replica)
        XCTAssertEqual(try f.store.outbox(for: f.scope)?.updates, [update])
        try enqueue(f)
        await waitUntil { self.isSaved(f.coordinator.state(for: self.documentID)) }
        XCTAssertNil(try f.store.outbox(for: f.scope))
    }

    func testBodyAckSurvivesTitleHalfLandAndRelaunchRetriesOnlyTitle() async throws {
        let f = try fixture()
        let log = RequestRecorder()
        stub(log: log, titleStatus: 500)
        try enqueue(f, title: "Typed")
        await waitUntil { self.isPendingSync(f.coordinator.state(for: self.documentID)) }
        XCTAssertNil(try f.store.outbox(for: f.scope))
        XCTAssertEqual(f.drafts.draft(for: documentID)?.lastPushedMarkdown, "xOne\n")
        XCTAssertNotNil(f.drafts.draft(for: documentID)?.replica)
        stub(log: log)
        let relaunched = DocumentSaveCoordinator(
            client: f.client, draftStore: f.drafts, replicaStore: f.store,
            contentCache: DocumentContentCacheStore(directory: cacheDirectory), listCache: f.listCache,
            backgroundTasks: .noop)
        await relaunched.syncPendingDrafts()
        await waitUntil { self.isSaved(relaunched.state(for: self.documentID)) }
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/"), 1)
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/api/v1.0/documents/"), 2)
    }

    func testConflictsAndLiveReplicaHoldReuseExistingQueueWithoutSending() async throws {
        var held = true
        let f = try fixture(isHeld: { _ in held })
        let log = RequestRecorder()
        stub(log: log)
        f.coordinator.recordConflict(documentID: documentID, serverUpdatedAt: Date())
        try enqueue(f)
        await f.coordinator.syncPendingDrafts()
        XCTAssertEqual(log.count(ofMethod: "PATCH"), 0)
        XCTAssertNotNil(f.drafts.draft(for: documentID)?.conflictServerUpdatedAt)
        f.coordinator.resolveConflictKeepingLocal(documentID: documentID)
        XCTAssertEqual(log.count(ofMethod: "PATCH"), 0, "a resolved conflict cannot bypass A5's live hold")
        held = false
        await f.coordinator.syncPendingDrafts()
        await waitUntil { self.isSaved(f.coordinator.state(for: self.documentID)) }
        XCTAssertNil(try f.store.outbox(for: f.scope))
    }

    func testClassicAndLiveWritersCannotReplaceNativeOwnedDraft() async throws {
        let f = try fixture(isHeld: { _ in true })
        try enqueue(f)
        let original = f.drafts.draft(for: documentID)
        f.coordinator.enqueue(documentID: documentID, title: "Classic", markdown: "flattened")
        f.coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0, 0]), projectedMarkdown: "flattened", title: "Live")
        XCTAssertEqual(f.drafts.draft(for: documentID), original)
        XCTAssertNotNil(f.coordinator.pendingSave(documentID: documentID)?.replicaRequest)
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testOldMarkdownDraftAndWrongAccountAreNeverAdoptedOrSent() async throws {
        let f = try fixture()
        f.drafts.save(PendingDraft(documentID: documentID, title: "Old", markdown: "old", updatedAt: Date()))
        do {
            try enqueue(f)
            XCTFail("an old Markdown draft must not be adopted")
        } catch ReplicaSaveError.incompatibleDraft {}
        XCTAssertNil(f.drafts.draft(for: documentID)?.replica)
        XCTAssertNil(MockURLProtocol.lastRequest)
        f.drafts.remove(documentID: documentID)
        let log = RequestRecorder()
        stub(log: log, responseOwner: UUID())
        try enqueue(f)
        await waitUntil { self.isFailed(f.coordinator.state(for: self.documentID)) }
        XCTAssertEqual(log.count(ofMethod: "PATCH"), 0)
        XCTAssertNotNil(try f.store.outbox(for: f.scope))
    }

    func testCorruptDiskCannotReachNetworkAndShadowMismatchCannotReplay() async throws {
        let f = try fixture(isHeld: { _ in true })
        try enqueue(f)
        let draft = try XCTUnwrap(f.drafts.draft(for: documentID))
        let reference = try XCTUnwrap(draft.replica)
        f.drafts.save(
            PendingDraft(
                documentID: documentID, title: draft.title, markdown: "changed",
                updatedAt: draft.updatedAt, baseline: draft.baseline, replica: reference))
        let relaunched = DocumentSaveCoordinator(
            client: f.client, draftStore: f.drafts, replicaStore: f.store,
            contentCache: DocumentContentCacheStore(directory: cacheDirectory), listCache: f.listCache,
            backgroundTasks: .noop)
        await relaunched.syncPendingDrafts()
        XCTAssertNil(MockURLProtocol.lastRequest)
        let restore = try XCTUnwrap(f.store.restore(for: f.scope))
        let path = cacheDirectory.appendingPathComponent("ReplicaDrafts")
            .appendingPathComponent(try f.scope.directoryName()).appendingPathComponent(
                restore.manifest.journal[0].file.name)
        try Data([0xff]).write(to: path)
        do {
            try enqueue(f)
            XCTFail("a corrupt journal must not be captured")
        } catch ReplicaStoreError.corrupt {}
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testKeystrokeDuringTitleRequestIsRestampedFromRawAndSentByTheNextPass() async throws {
        let f = try fixture()
        let log = RequestRecorder()
        let gate = MockURLProtocol.ResponseGate()
        defer { gate.open() }
        stub(log: log, titleGate: gate)
        try enqueue(f)
        await waitUntil { log.count(ofMethod: "PATCH", urlContaining: "/api/v1.0/documents/") == 1 }
        let second = try appendSecond(f)
        gate.open()
        await waitUntil { self.isPendingSync(f.coordinator.state(for: self.documentID)) }
        let stale = try XCTUnwrap(f.drafts.draft(for: documentID))
        XCTAssertEqual(stale.replica?.revision, 1, "the draft still names the revision before the keystroke")
        XCTAssertEqual(stale.markdown, "xOne\n")
        XCTAssertEqual(try f.store.outbox(for: f.scope)?.updates, [second])
        // No editor re-enqueues: the sync pass alone must carry "y" from the journal.
        await f.coordinator.syncPendingDrafts()
        await waitUntil { self.isSaved(f.coordinator.state(for: self.documentID)) }
        XCTAssertNil(try f.store.outbox(for: f.scope), "the second keystroke was sent and acknowledged")
        XCTAssertNil(f.drafts.draft(for: documentID))
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/"), 2)
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/content/"), 0)
        XCTAssertEqual(try f.store.restore(for: f.scope)?.manifest.httpAcknowledgedThrough, 2)
    }

    func testIncompatibleReferenceIsRefusedRatherThanRestamped() throws {
        let f = try fixture()
        let manifest = try XCTUnwrap(f.store.restore(for: f.scope)).manifest
        let current = ReplicaDraftReference(manifest: manifest, markdown: "xOne")
        var older = manifest
        older.revision = 0
        let stale = ReplicaDraftReference(manifest: older, markdown: "One")
        XCTAssertEqual(try f.adapter.prepare(markdown: "One", expected: stale).markdown, "xOne\n")
        let otherScope = ReplicaScope(
            serverOrigin: f.scope.serverOrigin, ownerUserID: UUID(), org: f.scope.org, documentID: documentID)
        let wrongScope = ReplicaDraftReference(
            manifest: ReplicaManifest(
                formatVersion: manifest.formatVersion, scope: otherScope, generation: manifest.generation,
                revision: 0, checkpointSequence: 0, checkpoint: manifest.checkpoint, journal: [], outbox: [],
                httpAcknowledgedThrough: 0, projectionCacheVersion: manifest.projectionCacheVersion),
            markdown: "One")
        let wrongGeneration = ReplicaDraftReference(
            manifest: ReplicaManifest(
                formatVersion: manifest.formatVersion, scope: f.scope, generation: UUID(),
                revision: 0, checkpointSequence: 0, checkpoint: manifest.checkpoint, journal: [], outbox: [],
                httpAcknowledgedThrough: 0, projectionCacheVersion: manifest.projectionCacheVersion),
            markdown: "One")
        var ahead = manifest
        ahead.revision = 2
        for (reference, markdown) in [
            (wrongScope, "One"), (wrongGeneration, "One"),
            (ReplicaDraftReference(manifest: ahead, markdown: "xOne"), "xOne"),
            (stale, "edited shadow"), (current, "edited shadow"),
        ] {
            do {
                _ = try f.adapter.prepare(markdown: markdown, expected: reference)
                XCTFail("an incompatible reference must not be restamped")
            } catch ReplicaSaveError.staleReference {}
        }
    }

    func testFirstCaptureStampsTheRawProjectionNeverACallerShadow() throws {
        let f = try fixture()
        try enqueue(f)
        let draft = try XCTUnwrap(f.drafts.draft(for: documentID))
        XCTAssertEqual(draft.markdown, "xOne\n", "the shadow is projected from the journal")
        XCTAssertEqual(draft.replica?.revision, 1)
        XCTAssertEqual(draft.replica?.matches(markdown: draft.markdown), true)
    }

    func testManualRetryOfAFailedRawDraftSendsThroughTheRawPath() async throws {
        let f = try fixture()
        let log = RequestRecorder()
        stub(log: log, bodyStatus: 403)
        try enqueue(f)
        await waitUntil { self.isFailed(f.coordinator.state(for: self.documentID)) }
        stub(log: log)  // permission restored
        let viewModel = EditorViewModel(
            client: f.client, documentID: documentID, title: "Doc", saveCoordinator: f.coordinator,
            signedInUser: SignedInUserStore(userDefaults: f.listCache.userDefaults), contentCache: f.contentCache,
            listCache: f.listCache)
        viewModel.saveNow()
        await waitUntil { self.isSaved(f.coordinator.state(for: self.documentID)) }
        XCTAssertNil(try f.store.outbox(for: f.scope))
        XCTAssertNil(f.drafts.draft(for: documentID))
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/content/"), 0)
    }

    func testRawSaveNeverWritesItsShadowIntoTheClassicContentCache() async throws {
        let f = try fixture()
        let log = RequestRecorder()
        stub(log: log)
        try enqueue(f)
        await waitUntil { self.isSaved(f.coordinator.state(for: self.documentID)) }
        XCTAssertNil(f.contentCache.content(for: documentID))
    }

    func testKeepMineUnderAnotherAccountLeavesTheNativeDraftAndConflictUntouched() async throws {
        let f = try fixture()
        let log = RequestRecorder()
        stub(log: log)
        f.coordinator.recordConflict(documentID: documentID, serverUpdatedAt: Date(timeIntervalSince1970: 2))
        try enqueue(f)
        let original = try XCTUnwrap(f.drafts.draft(for: documentID))
        SignedInUserStore(userDefaults: f.listCache.userDefaults).remember(UUID())
        f.coordinator.resolveConflictKeepingLocal(documentID: documentID)
        XCTAssertEqual(f.drafts.draft(for: documentID), original)
        XCTAssertTrue(self.isFailed(f.coordinator.state(for: documentID)))
        XCTAssertNotNil(f.coordinator.pendingSave(documentID: documentID))
        do {
            try enqueue(f)
            XCTFail("another account must not queue this raw draft")
        } catch ReplicaSaveError.invalidScope {}
        XCTAssertEqual(f.drafts.draft(for: documentID), original)
        XCTAssertEqual(log.count(ofMethod: "PATCH"), 0)
    }

    func testKeepMineReportsAFailedRawCaptureInsteadOfANoOp() throws {
        let f = try fixture()
        f.coordinator.recordConflict(documentID: documentID, serverUpdatedAt: Date(timeIntervalSince1970: 2))
        try enqueue(f)
        // A relaunch rehydrates the conflict without a held save, so keep-mine captures afresh.
        let relaunched = DocumentSaveCoordinator(
            client: f.client, draftStore: f.drafts, replicaStore: f.store,
            contentCache: DocumentContentCacheStore(directory: cacheDirectory), listCache: f.listCache,
            backgroundTasks: .noop)
        XCTAssertNil(relaunched.pendingSave(documentID: documentID))
        let restore = try XCTUnwrap(f.store.restore(for: f.scope))
        try Data([0xff]).write(
            to: cacheDirectory.appendingPathComponent("ReplicaDrafts")
                .appendingPathComponent(try f.scope.directoryName())
                .appendingPathComponent(restore.manifest.journal[0].file.name))
        relaunched.resolveConflictKeepingLocal(documentID: documentID)
        XCTAssertTrue(self.isFailed(relaunched.state(for: documentID)))
        XCTAssertNotNil(f.drafts.draft(for: documentID)?.replica)
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testAcknowledgedSaveBelowTheThresholdDoesNotReencodeTheDocument() async throws {
        let f = try fixture()
        let log = RequestRecorder()
        stub(log: log)
        try enqueue(f)
        await waitUntil { self.isSaved(f.coordinator.state(for: self.documentID)) }
        let manifest = try XCTUnwrap(f.store.manifest(for: f.scope))
        XCTAssertTrue(manifest.outbox.isEmpty)
        XCTAssertEqual(manifest.journal.count, 1, "one covered segment is below the threshold")
        XCTAssertEqual(manifest.checkpointSequence, 0)
    }

    func testCompactionCountsOnlyCoveredSegmentsAndKeepsTheProjection() throws {
        let f = try fixture()
        // The fixture already recorded one update; reach the threshold without
        // acknowledging. Compaction would retain every one of these unsent
        // segments, so it must not re-encode the document for nothing.
        for revision in 1..<UInt64(ReplicaSaveAdapter.compactionJournalThreshold) {
            _ = try f.store.append(
                f.update, for: f.scope, commandID: UUID(), baseRevision: revision, origin: .local)
        }
        let before = try XCTUnwrap(f.store.manifest(for: f.scope))
        XCTAssertEqual(before.journal.count, ReplicaSaveAdapter.compactionJournalThreshold)
        XCTAssertFalse(f.adapter.compactIfNeeded())
        XCTAssertEqual(try f.store.manifest(for: f.scope), before)
        // Once the batch is acknowledged, every segment is covered and compacts.
        try f.store.acknowledge(try XCTUnwrap(f.store.outbox(for: f.scope)))
        XCTAssertTrue(f.adapter.compactIfNeeded())
        let restored = try XCTUnwrap(f.store.restore(for: f.scope))
        XCTAssertTrue(restored.manifest.journal.isEmpty)
        XCTAssertEqual(restored.manifest.checkpointSequence, restored.manifest.revision)
        XCTAssertEqual(restored.manifest.generation, before.generation)
        let doc = YDoc(clientID: 0)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(restored.checkpoint), origin: .remote)
        XCTAssertEqual(YBlockProjection.projectedMarkdown(YBlockProjection.project(doc)), "xOne\n")
    }
}
