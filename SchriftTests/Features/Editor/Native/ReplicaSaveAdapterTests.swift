import XCTest

@testable import Schrift

@MainActor
final class ReplicaSaveAdapterTests: DocumentSaveCoordinatorTestCase {
    private let owner = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    private struct Fixture {
        let client: DocsAPIClient
        let coordinator: DocumentSaveCoordinator
        let drafts: PendingDraftStore
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
        let drafts = PendingDraftStore(userDefaults: UserDefaults(suiteName: suite)!)
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: drafts, replicaStore: store,
            contentCache: DocumentContentCacheStore(directory: cacheDirectory), backgroundTasks: .noop,
            isLiveReplicaHeld: isHeld)
        return Fixture(
            client: client, coordinator: coordinator, drafts: drafts, store: store,
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

    private func enqueue(_ f: Fixture, title: String = "Doc", markdown: String = "xOne") throws {
        try f.coordinator.enqueueReplica(
            adapter: f.adapter, title: title, projectedMarkdown: markdown,
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
        try enqueue(f, markdown: "yxOne")
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
        try enqueue(f, markdown: "yxOne")
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
        XCTAssertEqual(f.drafts.draft(for: documentID)?.lastPushedMarkdown, "xOne")
        XCTAssertNotNil(f.drafts.draft(for: documentID)?.replica)
        stub(log: log)
        let relaunched = DocumentSaveCoordinator(
            client: f.client, draftStore: f.drafts, replicaStore: f.store,
            contentCache: DocumentContentCacheStore(directory: cacheDirectory), backgroundTasks: .noop)
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
        XCTAssertThrowsError(try enqueue(f))
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
            contentCache: DocumentContentCacheStore(directory: cacheDirectory), backgroundTasks: .noop)
        await relaunched.syncPendingDrafts()
        XCTAssertNil(MockURLProtocol.lastRequest)
        let restore = try XCTUnwrap(f.store.restore(for: f.scope))
        let path = cacheDirectory.appendingPathComponent("ReplicaDrafts")
            .appendingPathComponent(try f.scope.directoryName()).appendingPathComponent(
                restore.manifest.journal[0].file.name)
        try Data([0xff]).write(to: path)
        XCTAssertThrowsError(try enqueue(f))
        XCTAssertNil(MockURLProtocol.lastRequest)
    }
}
