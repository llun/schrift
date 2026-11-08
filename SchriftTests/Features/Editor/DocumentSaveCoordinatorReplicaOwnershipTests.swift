import XCTest

@testable import Schrift

/// The durable owner marker's effect on the coordinator: a native-owned document
/// is never written by the classic or live writer, and an explicit discard
/// removes the replica and its marker together.
@MainActor
final class DocumentSaveCoordinatorReplicaOwnershipTests: DocumentSaveCoordinatorTestCase {
    private let owner = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private var ownershipSuite: String!
    private var ownershipDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        ownershipSuite = "ReplicaOwnershipTests.\(UUID().uuidString)"
        ownershipDefaults = UserDefaults(suiteName: ownershipSuite)
    }

    override func tearDown() {
        ownershipDefaults?.removePersistentDomain(forName: ownershipSuite)
        ownershipDefaults = nil
        ownershipSuite = nil
        super.tearDown()
    }

    private struct Fixture {
        let coordinator: DocumentSaveCoordinator
        let drafts: PendingDraftStore
        let store: ReplicaStore
        let ownership: ReplicaOwnershipStore
        let scope: ReplicaScope
        let client: DocsAPIClient
        let defaults: UserDefaults
        let contentCache: DocumentContentCacheStore
        let listCache: DocumentCacheStore
    }

    private func fixture() throws -> Fixture {
        let suite = "DocumentSaveCoordinatorReplicaOwnershipTests.\(UUID().uuidString)"
        draftSuiteNames.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let drafts = PendingDraftStore(userDefaults: defaults)
        let listCache = DocumentCacheStore(userDefaults: defaults)
        SignedInUserStore(userDefaults: defaults).remember(owner)
        let ownership = ReplicaOwnershipStore(userDefaults: ownershipDefaults)
        let store = ReplicaStore(
            directory: cacheDirectory.appendingPathComponent("ReplicaDrafts"), ownershipStore: ownership)
        let contentCache = DocumentContentCacheStore(directory: cacheDirectory)
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: drafts, replicaStore: store,
            contentCache: contentCache, listCache: listCache, backgroundTasks: .noop,
            isLiveReplicaHeld: { _ in true })
        let scope = ReplicaScope(
            serverOrigin: client.serverOrigin, ownerUserID: owner, org: "docs", documentID: documentID)
        return Fixture(
            coordinator: coordinator, drafts: drafts, store: store, ownership: ownership, scope: scope,
            client: client, defaults: defaults, contentCache: contentCache, listCache: listCache)
    }

    private func seedReplica(_ f: Fixture) throws -> ReplicaSaveAdapter {
        let checkpoint = BlockNoteYjs.encode(
            [
                BlockNoteBlock(
                    node: "paragraph", props: DocumentEngineTestCase.paragraphProps,
                    runs: [InlineRun("One")], id: "one")
            ], clientID: 1)
        _ = try f.store.create(for: f.scope, checkpoint: checkpoint)
        let doc = YDoc(clientID: 2)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(checkpoint), origin: .remote)
        let update = try BlockNoteWriter(doc: doc).replaceText(block: "one", range: 0..<0, with: "x")
        let adapter = ReplicaSaveAdapter(store: f.store, scope: f.scope)
        try adapter.record(
            NativeEditCommand(id: UUID(), baseRevision: 0, blockID: "one", range: 0..<0, replacement: "x"),
            update: update)
        return adapter
    }

    func testClassicAndLiveEnqueuesAreRefusedForAnOwnedDocumentWithoutADraft() throws {
        let f = try fixture()
        _ = try seedReplica(f)
        XCTAssertTrue(f.coordinator.isNativeOwned(documentID: documentID))
        f.coordinator.enqueue(documentID: documentID, title: "Classic", markdown: "flattened")
        f.coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0, 0]), projectedMarkdown: "flattened", title: "Live")
        XCTAssertNil(f.drafts.draft(for: documentID), "the classic writer must not store a draft")
        XCTAssertNil(f.coordinator.pendingSave(documentID: documentID))
        XCTAssertTrue(isPendingSync(f.coordinator.state(for: documentID)))
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testNativeEnqueueIsAllowedForAnOwnedDocument() throws {
        let f = try fixture()
        let adapter = try seedReplica(f)
        try f.coordinator.enqueueReplica(adapter: adapter, title: "Native")
        XCTAssertNotNil(f.drafts.draft(for: documentID)?.replica)
        XCTAssertNotNil(f.coordinator.pendingSave(documentID: documentID)?.replicaRequest)
        XCTAssertNil(MockURLProtocol.lastRequest, "the live hold keeps the request queued")
    }

    func testKeepServerDiscardsTheReplicaAndMarker() throws {
        let f = try fixture()
        let adapter = try seedReplica(f)
        try f.coordinator.enqueueReplica(adapter: adapter, title: "Native")
        f.coordinator.resolveConflictKeepingServer(documentID: documentID)
        XCTAssertNil(try f.store.restore(for: f.scope))
        XCTAssertEqual(f.ownership.owner(documentID: documentID, serverOrigin: f.scope.serverOrigin), .none)
        XCTAssertNil(f.drafts.draft(for: documentID))
        XCTAssertFalse(f.coordinator.isNativeOwned(documentID: documentID))
    }

    func testDiscardPendingWorkRemovesTheReplicaAndMarker() throws {
        let f = try fixture()
        let adapter = try seedReplica(f)
        try f.coordinator.enqueueReplica(adapter: adapter, title: "Native")
        f.coordinator.discardPendingWork(documentID: documentID)
        XCTAssertNil(try f.store.restore(for: f.scope))
        XCTAssertEqual(f.ownership.owner(documentID: documentID, serverOrigin: f.scope.serverOrigin), .none)
        XCTAssertNil(f.drafts.draft(for: documentID))
    }

    func testDiscardPendingWorkRemovesAReplicaWhoseDraftIsAlreadyGone() throws {
        let f = try fixture()
        _ = try seedReplica(f)
        // A successful save removes the draft but keeps the marker; a later
        // delete must still find and remove the replica through the marker.
        XCTAssertNil(f.drafts.draft(for: documentID))
        f.coordinator.discardPendingWork(documentID: documentID)
        XCTAssertNil(try f.store.restore(for: f.scope))
        XCTAssertEqual(f.ownership.owner(documentID: documentID, serverOrigin: f.scope.serverOrigin), .none)
    }

    func testAnotherAccountsDeleteKeepsTheReplicaAndNativeDraft() throws {
        let f = try fixture()
        let adapter = try seedReplica(f)
        try f.coordinator.enqueueReplica(adapter: adapter, title: "Native")
        // A shared device: B signs in, and B's DELETE of A's document lands (or 404s).
        SignedInUserStore(userDefaults: f.defaults).remember(UUID())
        f.coordinator.completeImmediateDelete(documentID: documentID)
        f.coordinator.resolveConflictKeepingServer(documentID: documentID)
        XCTAssertNotNil(try f.store.restore(for: f.scope), "A's replica is A's unsynced work")
        XCTAssertEqual(f.ownership.owner(documentID: documentID, serverOrigin: f.scope.serverOrigin), .owned(f.scope))
        XCTAssertEqual(f.drafts.draft(for: documentID)?.replica?.scope, f.scope)
        XCTAssertNil(f.coordinator.pendingSave(documentID: documentID), "B's own delete flow still completes")
    }

    func testANativeDraftOwnsTheDocumentWhenTheMarkerDoesNotNameIt() throws {
        let f = try fixture()
        let adapter = try seedReplica(f)
        try f.coordinator.enqueueReplica(adapter: adapter, title: "Native")
        XCTAssertTrue(f.ownership.clear(f.scope), "a repair that could not read the folder dropped it")
        XCTAssertEqual(f.coordinator.nativeOwnership(documentID: documentID), .owned(f.scope))
        XCTAssertTrue(f.coordinator.isNativeOwned(documentID: documentID))
    }

    func testTheClassicLoadNeverShowsANativeDraftsShadow() async throws {
        let f = try fixture()
        let adapter = try seedReplica(f)
        try f.coordinator.enqueueReplica(adapter: adapter, title: "Native")
        let shadow = try XCTUnwrap(f.drafts.draft(for: documentID)?.markdown)
        XCTAssertTrue(shadow.contains("xOne"))
        f.contentCache.save(
            CachedDocumentContent(
                documentID: documentID, title: "Cached", markdown: "Server body",
                syncedAt: Date(timeIntervalSince1970: 1_000_000)))
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        let model = EditorViewModel(
            client: f.client, documentID: documentID, title: "Doc", saveCoordinator: f.coordinator,
            signedInUser: SignedInUserStore(userDefaults: f.defaults), contentCache: f.contentCache,
            childrenCache: DocumentChildrenCacheStore(userDefaults: f.defaults), listCache: f.listCache,
            availability: OnlineAvailability(userDefaults: f.defaults))
        await model.load()
        XCTAssertEqual(model.rawMarkdown, "Server body", "the native shadow is never the classic body")
    }

    func testRecoverQuarantinedDraftsRehydratesTheConflictHold() throws {
        let f = try fixture()
        let draft = PendingDraft(
            documentID: documentID, title: "Held", markdown: "body", updatedAt: Date(),
            conflictServerUpdatedAt: Date(timeIntervalSince1970: 2))
        f.drafts.save(draft)
        // Simulate a blob that was unreadable at launch and is decodable now:
        // move the live bytes into the quarantine slot.
        let live = try XCTUnwrap(f.defaults.data(forKey: "dev.llun.Schrift.pendingDrafts"))
        f.defaults.set(live, forKey: "dev.llun.Schrift.pendingDrafts.unreadable")
        f.defaults.removeObject(forKey: "dev.llun.Schrift.pendingDrafts")
        XCTAssertTrue(f.coordinator.hasUnreadableDrafts)
        XCTAssertNil(f.coordinator.conflict(for: documentID))
        XCTAssertTrue(f.coordinator.recoverQuarantinedDrafts())
        XCTAssertFalse(f.coordinator.hasUnreadableDrafts)
        let recovered = try XCTUnwrap(f.drafts.draft(for: documentID))
        XCTAssertEqual(recovered.markdown, draft.markdown)
        XCTAssertEqual(recovered.conflictServerUpdatedAt, draft.conflictServerUpdatedAt)
        XCTAssertNotNil(f.coordinator.conflict(for: documentID), "the hold is in force again")
    }

    func testRecoverQuarantinedDraftsReportsFailureAndKeepsTheBlob() throws {
        let f = try fixture()
        f.defaults.set(Data([0xff]), forKey: "dev.llun.Schrift.pendingDrafts.unreadable")
        XCTAssertTrue(f.coordinator.hasUnreadableDrafts)
        XCTAssertFalse(f.coordinator.recoverQuarantinedDrafts())
        XCTAssertTrue(f.coordinator.hasUnreadableDrafts)
        XCTAssertEqual(f.defaults.data(forKey: "dev.llun.Schrift.pendingDrafts.unreadable"), Data([0xff]))
    }

    func testCanStartEditingIsFalseForAnOwnedDocumentEvenWithLoadedContent() async throws {
        let f = try fixture()
        _ = try seedReplica(f)
        f.contentCache.save(
            CachedDocumentContent(
                documentID: documentID, title: "Cached", markdown: "# Cached",
                syncedAt: Date(timeIntervalSince1970: 1_000_000)))
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        let model = EditorViewModel(
            client: f.client, documentID: documentID, title: "Doc", saveCoordinator: f.coordinator,
            signedInUser: SignedInUserStore(userDefaults: f.defaults), contentCache: f.contentCache,
            childrenCache: DocumentChildrenCacheStore(userDefaults: f.defaults), listCache: f.listCache,
            availability: OnlineAvailability(userDefaults: f.defaults))
        await model.load()
        XCTAssertTrue(model.hasLoadedContent, "the cached copy loaded")
        XCTAssertFalse(model.canStartEditing, "a native-owned document is never classic-editable")
        model.startEditing()
        XCTAssertFalse(model.isEditing)
    }

    func testTheDefaultMarkerStoreUsesTheInjectedDefaults() throws {
        let suite = "DocumentSaveCoordinatorReplicaOwnershipTests.\(UUID().uuidString)"
        draftSuiteNames.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(Data([0xff]), forKey: "dev.llun.Schrift.replicaOwnership")
        let coordinator = DocumentSaveCoordinator(
            client: DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] }),
            draftStore: PendingDraftStore(userDefaults: defaults),
            contentCache: DocumentContentCacheStore(directory: cacheDirectory),
            createStore: PendingDocumentCreateStore(userDefaults: defaults),
            deleteStore: PendingDocumentDeleteStore(userDefaults: defaults),
            listCache: DocumentCacheStore(userDefaults: defaults), backgroundTasks: .noop)
        XCTAssertTrue(coordinator.isNativeOwned(documentID: documentID), "never UserDefaults.standard")
    }

    func testUnreadableMarkerMakesEveryDocumentReadOnly() throws {
        let f = try fixture()
        ownershipDefaults.set(Data([0xff]), forKey: "dev.llun.Schrift.replicaOwnership")
        XCTAssertTrue(f.coordinator.isNativeOwned(documentID: documentID))
        XCTAssertTrue(f.coordinator.isNativeOwned(documentID: otherDocumentID))
        XCTAssertEqual(f.coordinator.nativeOwnership(documentID: documentID), .unreadable)
    }
}
