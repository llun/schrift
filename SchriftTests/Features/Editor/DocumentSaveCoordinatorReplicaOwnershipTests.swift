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

    func testPurgeCleanNativeReplicasOnSignOutKeepsProtectedWorkAndPurgesCleanOwned() throws {
        let suite = "SignOutPurgeTests.\(UUID().uuidString)"
        draftSuiteNames.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let drafts = PendingDraftStore(userDefaults: defaults)
        let createStore = PendingDocumentCreateStore(userDefaults: defaults)
        let deleteStore = PendingDocumentDeleteStore(userDefaults: defaults)
        let attachmentStore = PendingAttachmentStore(
            userDefaults: defaults,
            directory: cacheDirectory.appendingPathComponent("Attachments", isDirectory: true)
        )
        let listCache = DocumentCacheStore(userDefaults: defaults)
        SignedInUserStore(userDefaults: defaults).remember(owner)
        let ownership = ReplicaOwnershipStore(userDefaults: ownershipDefaults)
        let store = ReplicaStore(
            directory: cacheDirectory.appendingPathComponent("ReplicaDrafts"),
            ownershipStore: ownership
        )
        let contentCache = DocumentContentCacheStore(directory: cacheDirectory)
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let coordinator = DocumentSaveCoordinator(
            client: client,
            draftStore: drafts,
            replicaStore: store,
            contentCache: contentCache,
            createStore: createStore,
            deleteStore: deleteStore,
            attachmentStore: attachmentStore,
            listCache: listCache,
            backgroundTasks: .noop,
            isLiveReplicaHeld: { _ in true }
        )
        coordinator.nativeEditorEnabled = { true }

        let checkpoint = BlockNoteYjs.encode(
            [
                BlockNoteBlock(
                    node: "paragraph", props: DocumentEngineTestCase.paragraphProps,
                    runs: [InlineRun("Clean")], id: "clean")
            ], clientID: 1)

        let cleanDocID = UUID()
        let conflictDocID = UUID()
        let attachmentDocID = UUID()
        let deleteDocID = UUID()
        let otherOwnerDocID = UUID()

        let scopeFor: (UUID, UUID) -> ReplicaScope = { docID, user in
            ReplicaScope(serverOrigin: client.serverOrigin, ownerUserID: user, org: "docs", documentID: docID)
        }

        let cleanScope = scopeFor(cleanDocID, owner)
        let conflictScope = scopeFor(conflictDocID, owner)
        let attachmentScope = scopeFor(attachmentDocID, owner)
        let deleteScope = scopeFor(deleteDocID, owner)
        let otherScope = scopeFor(otherOwnerDocID, UUID())

        for s in [cleanScope, conflictScope, attachmentScope, deleteScope, otherScope] {
            _ = try store.create(for: s, checkpoint: checkpoint)
        }

        coordinator.recordConflict(documentID: conflictDocID, serverUpdatedAt: Date())
        coordinator.recordPendingDelete(documentID: deleteDocID, ownerUserID: owner)
        XCTAssertNotNil(
            coordinator.queueNativeAttachment(
                scope: attachmentScope,
                target: NativeMediaTarget(
                    org: "docs", blockID: "b1", slot: MediaBlock.Slot(node: "image", url: ""), fileName: "a.png",
                    contentType: "image/png"
                ),
                data: Data([1, 2, 3])
            )
        )
        ServerConfigStore(userDefaults: defaults).remember(
            ServerConfig(releaseVersion: "6.0.0", collaborationWsUrl: nil),
            forServerOrigin: client.serverOrigin
        )
        let localDoc = coordinator.createLocalDocument(title: "Local", parentID: nil, ownerUserID: owner)
        let localScope = scopeFor(localDoc.id, owner)

        // Clear owner right before invoking purge, mirroring sign-out where leaving ownerID is passed explicitly.
        SignedInUserStore(userDefaults: defaults).clear()
        coordinator.purgeCleanNativeReplicasOnSignOut(ownerUserID: owner)

        XCTAssertNil(try store.restore(for: cleanScope), "clean replica with no protected state must be purged")
        XCTAssertNotNil(try store.restore(for: conflictScope), "replica referenced by conflicts must stay")
        XCTAssertNotNil(try store.restore(for: attachmentScope), "replica with pending attachment must stay")
        XCTAssertNotNil(try store.restore(for: deleteScope), "replica with pending delete must stay")
        XCTAssertNotNil(try store.restore(for: localScope), "replica for pending create must stay")
        XCTAssertNotNil(try store.restore(for: otherScope), "different owner's replica must stay")
    }

    func testPurgeCleanNativeReplicasOnSignOutFailsClosedWhenAnyMetadataStoreIsUnreadable() throws {
        let corruptKeys = [
            "dev.llun.Schrift.pendingDrafts",
            "dev.llun.Schrift.pendingCreates",
            "dev.llun.Schrift.pendingDeletes",
            "dev.llun.Schrift.pendingAttachments",
        ]
        for corruptKey in corruptKeys {
            let suite = "SignOutFailClosed.\(UUID().uuidString)"
            draftSuiteNames.append(suite)
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(Data([0xff]), forKey: corruptKey)

            let drafts = PendingDraftStore(userDefaults: defaults)
            let createStore = PendingDocumentCreateStore(userDefaults: defaults)
            let deleteStore = PendingDocumentDeleteStore(userDefaults: defaults)
            let attachmentStore = PendingAttachmentStore(
                userDefaults: defaults,
                directory: cacheDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            )
            let listCache = DocumentCacheStore(userDefaults: defaults)
            SignedInUserStore(userDefaults: defaults).remember(owner)
            let ownership = ReplicaOwnershipStore(userDefaults: ownershipDefaults)
            let store = ReplicaStore(
                directory: cacheDirectory.appendingPathComponent("ReplicaDrafts.\(UUID().uuidString)"),
                ownershipStore: ownership
            )
            let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
            let coordinator = DocumentSaveCoordinator(
                client: client,
                draftStore: drafts,
                replicaStore: store,
                contentCache: DocumentContentCacheStore(directory: cacheDirectory),
                createStore: createStore,
                deleteStore: deleteStore,
                attachmentStore: attachmentStore,
                listCache: listCache,
                backgroundTasks: .noop,
                isLiveReplicaHeld: { _ in true }
            )
            let scope = ReplicaScope(
                serverOrigin: client.serverOrigin, ownerUserID: owner, org: "docs", documentID: UUID()
            )
            _ = try store.create(for: scope, checkpoint: Data([0, 0]))
            coordinator.purgeCleanNativeReplicasOnSignOut(ownerUserID: owner)
            XCTAssertNotNil(
                try store.restore(for: scope),
                "must fail closed and keep clean replica when \(corruptKey) is unreadable"
            )
        }

        // Also fail closed when replicaOwnership itself is unreadable.
        let f = try fixture()
        _ = try f.store.create(for: f.scope, checkpoint: Data([0, 0]))
        ownershipDefaults.set(Data([0xff]), forKey: "dev.llun.Schrift.replicaOwnership")
        f.coordinator.purgeCleanNativeReplicasOnSignOut(ownerUserID: owner)
        XCTAssertNotNil(try f.store.restore(for: f.scope))
    }

    func testPurgeCleanNativeReplicasOnSignOutFailsClosedWhenLeavingOwnerIsUnknown() throws {
        let f = try fixture()
        let accountAScope = f.scope
        let accountBScope = ReplicaScope(
            serverOrigin: f.client.serverOrigin, ownerUserID: UUID(), org: "docs", documentID: UUID())
        _ = try f.store.create(for: accountAScope, checkpoint: Data([0, 0]))
        _ = try f.store.create(for: accountBScope, checkpoint: Data([0, 0]))

        // Sign-out cleared SignedInUserStore first and the caller omitted ownerUserID.
        SignedInUserStore(userDefaults: f.defaults).clear()
        f.coordinator.purgeCleanNativeReplicasOnSignOut()

        XCTAssertNotNil(
            try f.store.restore(for: accountAScope),
            "unknown leaving owner must fail closed and purge nothing for account A")
        XCTAssertNotNil(
            try f.store.restore(for: accountBScope),
            "unknown leaving owner must fail closed and purge nothing for account B")
        XCTAssertEqual(
            f.ownership.owner(documentID: accountAScope.documentID, serverOrigin: f.client.serverOrigin),
            .owned(accountAScope))
        XCTAssertEqual(
            f.ownership.owner(documentID: accountBScope.documentID, serverOrigin: f.client.serverOrigin),
            .owned(accountBScope))
    }

    func testBackupExclusionStaysFalseWhileCoordinatorHoldsUnsyncedMetadata() async throws {
        func isExcluded(_ folder: URL) throws -> Bool? {
            var mutable = folder
            mutable.removeCachedResourceValue(forKey: .isExcludedFromBackupKey)
            return try mutable.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        }

        let suite = "BackupExclusionCoordinator.\(UUID().uuidString)"
        draftSuiteNames.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        SignedInUserStore(userDefaults: defaults).remember(owner)
        let replicaDir = cacheDirectory.appendingPathComponent("ReplicaDrafts.\(UUID().uuidString)", isDirectory: true)
        let ownership = ReplicaOwnershipStore(userDefaults: defaults)
        let store = ReplicaStore(directory: replicaDir, ownershipStore: ownership)
        let drafts = PendingDraftStore(userDefaults: defaults)
        let creates = PendingDocumentCreateStore(userDefaults: defaults)
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        ServerConfigStore(userDefaults: defaults).remember(
            ServerConfig(releaseVersion: "6.0.0", collaborationWsUrl: nil),
            forServerOrigin: client.serverOrigin)
        let coordinator = DocumentSaveCoordinator(
            client: client,
            draftStore: drafts,
            replicaStore: store,
            contentCache: DocumentContentCacheStore(directory: cacheDirectory),
            createStore: creates,
            deleteStore: PendingDocumentDeleteStore(userDefaults: defaults),
            attachmentStore: PendingAttachmentStore(
                userDefaults: defaults, directory: cacheDirectory.appendingPathComponent(UUID().uuidString)),
            listCache: DocumentCacheStore(userDefaults: defaults),
            backgroundTasks: .noop,
            isLiveReplicaHeld: { _ in false })
        coordinator.nativeEditorEnabled = { true }

        // 1. Offline local create (`outbox: []`, seedMarkdown in checkpoint): must stay in backups.
        let localDoc = coordinator.createLocalDocument(
            title: "Offline Created", parentID: nil, ownerUserID: owner, seedMarkdown: "Seed body")
        let localScope = ReplicaScope(
            serverOrigin: client.serverOrigin, ownerUserID: owner, org: "docs", documentID: localDoc.id)
        let localFolder = replicaDir.appendingPathComponent(try localScope.directoryName(), isDirectory: true)
        XCTAssertNotEqual(
            try isExcluded(localFolder), true,
            "offline-created replica backing PendingDocumentCreate must stay in backups even with empty outbox")

        // 2. Title-only native edit on a clean signed-in server doc (`outbox: []`, PendingDraft present).
        let serverDocID = UUID()
        let serverScope = ReplicaScope(
            serverOrigin: client.serverOrigin, ownerUserID: owner, org: "docs", documentID: serverDocID)
        let checkpoint = BlockNoteYjs.encode(
            [BlockNoteBlock(node: "paragraph", props: [], runs: [InlineRun("Hello")], id: "b1")], clientID: 1)
        let cleanManifest = try store.create(for: serverScope, checkpoint: checkpoint)
        let serverFolder = replicaDir.appendingPathComponent(try serverScope.directoryName(), isDirectory: true)
        XCTAssertEqual(try isExcluded(serverFolder), true, "clean synced replica starts excluded from backup")

        let adapter = ReplicaSaveAdapter(store: store, scope: serverScope)
        drafts.save(
            PendingDraft(
                documentID: serverDocID, title: "Title Only", markdown: "Hello", updatedAt: Date(),
                replica: ReplicaDraftReference(manifest: cleanManifest, markdown: "Hello")))
        try coordinator.enqueueReplica(adapter: adapter, title: "Title Only")
        // Also simulate clearing provisional files on an outbox-empty replica while draft stays queued/saved.
        try store.writeProvisionalRecoveries([], for: serverScope)
        XCTAssertNotEqual(
            try isExcluded(serverFolder), true,
            "title-only edit backed by PendingDraft must keep replica in backups despite empty outbox/provisional")

        // Wait for the initial enqueue (title-only failing offline) to settle before testing half-landed save.
        await waitUntil {
            coordinator.state(for: serverDocID) != .saving
        }

        // 3. Half-landed save: body PATCH succeeds (acknowledging outbox to []), title PATCH fails.
        let halfDocID = UUID()
        let halfScope = ReplicaScope(
            serverOrigin: client.serverOrigin, ownerUserID: owner, org: "docs", documentID: halfDocID)
        _ = try store.create(for: halfScope, checkpoint: checkpoint)
        let ydoc = YDoc(clientID: 2)
        defer { ydoc.destroy() }
        try ydoc.applyUpdate(YUpdateDecoder.decode(checkpoint), origin: .remote)
        let editUpdate = try BlockNoteWriter(doc: ydoc).replaceText(block: "b1", range: 0..<0, with: "Edit ")
        let halfAdapter = ReplicaSaveAdapter(store: store, scope: halfScope)
        try halfAdapter.record(
            NativeEditCommand(id: UUID(), baseRevision: 0, blockID: "b1", range: 0..<0, replacement: "Edit "),
            update: editUpdate)
        let halfFolder = replicaDir.appendingPathComponent(try halfScope.directoryName(), isDirectory: true)
        XCTAssertNotEqual(try isExcluded(halfFolder), true)

        var titleShouldFail = true
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("/config/") {
                return .init(
                    statusCode: 200, headers: [:], body: Data(#"{"RELEASE_VERSION":"6.0.0"}"#.utf8), error: nil)
            }
            if url.contains("/collaboration/ydoc/") {
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
            }
            if request.httpMethod == "PATCH", url.contains("/documents/") {
                return titleShouldFail
                    ? .init(statusCode: 500, headers: [:], body: Data(), error: nil)
                    : .init(statusCode: 200, headers: [:], body: Data("{}".utf8), error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: Data("{}".utf8), error: nil)
        }

        try coordinator.enqueueReplica(adapter: halfAdapter, title: "Updated Title")
        await waitUntil {
            if case .failed = coordinator.state(for: halfDocID) { return true }
            return false
        }
        XCTAssertTrue(try XCTUnwrap(try store.manifest(for: halfScope)).outbox.isEmpty, "body PATCH cleared outbox")
        XCTAssertNotNil(drafts.draft(for: halfDocID), "half-landed title failure keeps PendingDraft")
        XCTAssertNotEqual(
            try isExcluded(halfFolder), true,
            "half-landed save whose title PATCH failed must keep replica backed up even though outbox is empty")

        // 4. Retry succeeds: draft is removed and folder flips back to excluded from backup.
        titleShouldFail = false
        coordinator.retryReplicaDraft(documentID: halfDocID)
        await waitUntil {
            if case .saved = coordinator.state(for: halfDocID) { return true }
            return false
        }
        XCTAssertNil(drafts.draft(for: halfDocID))
        XCTAssertEqual(
            try isExcluded(halfFolder), true,
            "replica must exclude from backup only after both outbox and coordinator metadata are clean")
    }
}
