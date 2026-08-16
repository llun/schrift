import XCTest

@testable import Schrift

/// The two halves of a move the coordinator owns: the local re-parent, and what a landed
/// server move owes the device's caches before it announces.
@MainActor
final class DocumentSaveCoordinatorMoveTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let ownerID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let documentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let parentID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

    private var suiteNames: [String] = []
    private var cacheDirectories: [URL] = []

    override func tearDown() {
        for name in suiteNames { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suiteNames.removeAll()
        for directory in cacheDirectories { try? FileManager.default.removeItem(at: directory) }
        cacheDirectories.removeAll()
        MockURLProtocol.reset()
        super.tearDown()
    }

    private struct Environment {
        let coordinator: DocumentSaveCoordinator
        let creates: PendingDocumentCreateStore
        let listCache: DocumentCacheStore
        let childrenCache: DocumentChildrenCacheStore
        let contentCache: DocumentContentCacheStore
        let defaults: UserDefaults
    }

    private func makeEnvironment() -> Environment {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let suiteName = "DocumentSaveCoordinatorMoveTests.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentSaveCoordinatorMoveTests/\(UUID().uuidString)", isDirectory: true)
        cacheDirectories.append(cacheDirectory)
        let contentCache = DocumentContentCacheStore(directory: cacheDirectory)
        let creates = PendingDocumentCreateStore(userDefaults: defaults)
        let listCache = DocumentCacheStore(userDefaults: defaults)
        let childrenCache = DocumentChildrenCacheStore(userDefaults: defaults)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: PendingDraftStore(userDefaults: defaults),
            contentCache: contentCache, createStore: creates,
            deleteStore: PendingDocumentDeleteStore(userDefaults: defaults),
            listCache: listCache, childrenCache: childrenCache,
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)
        return Environment(
            coordinator: coordinator, creates: creates, listCache: listCache,
            childrenCache: childrenCache, contentCache: contentCache, defaults: defaults)
    }

    private func document(id: UUID, title: String = "Q3 Planning", depth: Int = 1) -> Document {
        Document(
            id: id, title: title, excerpt: nil, abilities: DocumentAbilities(), linkReach: .restricted,
            linkRole: .reader, computedLinkReach: nil, computedLinkRole: nil, isFavorite: false,
            depth: depth, numchild: 0, path: String(repeating: "0", count: 4 * depth),
            createdAt: Date(), updatedAt: Date(), userRole: .owner, creator: nil)
    }

    private final class MoveRecorder {
        var seen: [DocumentMoveEvent] = []
    }

    // MARK: - The local re-parent

    func testMovingALocalDocumentRewritesItsParentAndBumpsTheCreatesVersion() {
        let env = makeEnvironment()
        let parent = env.coordinator.createLocalDocument(title: "P", parentID: nil, ownerUserID: ownerID)
        let child = env.coordinator.createLocalDocument(title: "C", parentID: nil, ownerUserID: ownerID)
        let before = env.coordinator.pendingCreatesVersion

        XCTAssertTrue(env.coordinator.moveLocalDocument(documentID: child.id, newParentID: parent.id))

        XCTAssertEqual(env.creates.create(for: child.id)?.parentID, parent.id)
        // The version bump is what makes every read-time merge re-run — it is the whole
        // propagation mechanism for a local move.
        XCTAssertGreaterThan(env.coordinator.pendingCreatesVersion, before)
    }

    func testMovingALocalDocumentToTheTopLevelClearsItsParent() {
        let env = makeEnvironment()
        let parent = env.coordinator.createLocalDocument(title: "P", parentID: nil, ownerUserID: ownerID)
        let child = env.coordinator.createLocalDocument(
            title: "C", parentID: parent.id, ownerUserID: ownerID)

        XCTAssertTrue(env.coordinator.moveLocalDocument(documentID: child.id, newParentID: nil))

        XCTAssertNil(env.creates.create(for: child.id)?.parentID)
    }

    /// The POST has landed, so the record's `parentID` is inert and the migration is about to
    /// re-key everything. The server copy is what the caller must move instead.
    func testMovingACheckpointedRecordIsRefused() {
        let env = makeEnvironment()
        let parent = env.coordinator.createLocalDocument(title: "P", parentID: nil, ownerUserID: ownerID)
        let child = env.coordinator.createLocalDocument(title: "C", parentID: nil, ownerUserID: ownerID)
        var record = env.creates.create(for: child.id)!
        record.syncedServerID = documentID
        env.creates.save(record)
        let coordinator = DocumentSaveCoordinator(
            client: DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] }),
            draftStore: PendingDraftStore(userDefaults: env.defaults),
            contentCache: env.contentCache, createStore: env.creates,
            deleteStore: PendingDocumentDeleteStore(userDefaults: env.defaults),
            listCache: env.listCache, childrenCache: env.childrenCache,
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)

        XCTAssertFalse(coordinator.moveLocalDocument(documentID: child.id, newParentID: parent.id))
        XCTAssertNil(env.creates.create(for: child.id)?.parentID, "unchanged")
    }

    func testMovingALocalDocumentIntoItselfIsRefused() {
        let env = makeEnvironment()
        let document = env.coordinator.createLocalDocument(title: "D", parentID: nil, ownerUserID: ownerID)

        XCTAssertFalse(
            env.coordinator.moveLocalDocument(documentID: document.id, newParentID: document.id))
        XCTAssertNil(env.creates.create(for: document.id)?.parentID)
    }

    /// Two records naming each other deadlock the replay's parent gate for good — each skips
    /// because the other is still pending — so the cycle must be refused before it is made.
    func testMovingALocalDocumentUnderItsOwnDescendantIsRefused() {
        let env = makeEnvironment()
        let root = env.coordinator.createLocalDocument(title: "Root", parentID: nil, ownerUserID: ownerID)
        let child = env.coordinator.createLocalDocument(
            title: "Child", parentID: root.id, ownerUserID: ownerID)
        let grandchild = env.coordinator.createLocalDocument(
            title: "Grandchild", parentID: child.id, ownerUserID: ownerID)

        XCTAssertFalse(
            env.coordinator.moveLocalDocument(documentID: root.id, newParentID: grandchild.id))
        XCTAssertNil(env.creates.create(for: root.id)?.parentID, "unchanged")
    }

    /// The walk resolves a checkpointed server id back to its record, so a cycle cannot hide
    /// behind the alias a checkpoint introduces.
    func testTheCycleWalkFollowsACheckpointedParentsServerID() {
        let env = makeEnvironment()
        let root = env.coordinator.createLocalDocument(title: "Root", parentID: nil, ownerUserID: ownerID)
        let child = env.coordinator.createLocalDocument(
            title: "Child", parentID: root.id, ownerUserID: ownerID)
        // The child has been POSTed and now also answers to a server id; a grandchild filed
        // under *that* id is still, in truth, inside the root's subtree.
        var childRecord = env.creates.create(for: child.id)!
        childRecord.syncedServerID = documentID
        env.creates.save(childRecord)
        let grandchild = env.coordinator.createLocalDocument(
            title: "Grandchild", parentID: documentID, ownerUserID: ownerID)
        let coordinator = DocumentSaveCoordinator(
            client: DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] }),
            draftStore: PendingDraftStore(userDefaults: env.defaults),
            contentCache: env.contentCache, createStore: env.creates,
            deleteStore: PendingDocumentDeleteStore(userDefaults: env.defaults),
            listCache: env.listCache, childrenCache: env.childrenCache,
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)

        XCTAssertFalse(
            coordinator.moveLocalDocument(documentID: root.id, newParentID: grandchild.id),
            "the alias must not hide the cycle")
    }

    /// **The one guard whose failure is silent.** `replayCreate` copies the record before its
    /// await and writes that copy back after, so a move made while the POST is on the wire
    /// would be reverted *after* the server had already filed the document under the old
    /// parent — the picker would close, the row would appear to have moved, and nothing would
    /// ever say otherwise.
    func testAMoveIsRefusedWhileTheDocumentsCreatePostIsOnTheWire() async {
        let env = makeEnvironment()
        // A **server** destination, deliberately: a second local document would have its own
        // record, and `runCreatePass` replays oldest-first, so the POST held open would be
        // that one's rather than the moving document's.
        let targetID = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
        let moving = env.coordinator.createLocalDocument(
            title: "Moving", parentID: nil, ownerUserID: ownerID, seedMarkdown: "# Body")
        // Only the create POST is held: `runDeletePass` and the replay both ask `/users/me/`
        // first, and gating those would stall the pass before it ever reaches the POST.
        let gate = MockURLProtocol.ResponseGate()
        let userBody = #"{"id": "22222222-2222-4222-8222-222222222222"}"#.data(using: .utf8)!
        let createdBody = """
            {"id": "77777777-7777-4777-8777-777777777777", "title": "Moving", "abilities": {}, \
            "link_reach": "restricted", "link_role": "reader", "depth": 1, "numchild": 0, \
            "path": "0002", "created_at": "2026-08-01T10:00:00Z", "updated_at": "2026-08-01T10:00:00Z"}
            """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { request in
            if request.url?.absoluteString.contains("users/me") == true {
                return .init(statusCode: 200, headers: [:], body: userBody, error: nil)
            }
            if request.httpMethod == "POST" {
                return .init(statusCode: 201, headers: [:], body: createdBody, error: nil, releasedBy: gate)
            }
            return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
        }

        let coordinator = env.coordinator
        async let pass: Void = coordinator.syncPendingDrafts()
        await waitUntil { MockURLProtocol.deferredDeliveryCount > 0 }

        XCTAssertFalse(
            coordinator.moveLocalDocument(documentID: moving.id, newParentID: targetID),
            "the POST already named the old parent; accepting here would silently revert")
        XCTAssertNil(env.creates.create(for: moving.id)?.parentID, "and nothing was written")

        gate.open()
        await pass
    }

    func testMovingALocalDocumentUnderATombstonedParentIsRefused() {
        let env = makeEnvironment()
        let child = env.coordinator.createLocalDocument(title: "C", parentID: nil, ownerUserID: ownerID)
        env.coordinator.recordPendingDelete(documentID: parentID, ownerUserID: ownerID)

        XCTAssertFalse(env.coordinator.moveLocalDocument(documentID: child.id, newParentID: parentID))
        XCTAssertNil(env.creates.create(for: child.id)?.parentID)
    }

    // MARK: - The landed server move

    func testALandedMoveSweepsTheRowFromEveryCachedLevel() {
        let env = makeEnvironment()
        let row = document(id: documentID)
        let oldParentID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
        env.childrenCache.save([row], for: oldParentID)

        env.coordinator.completeDocumentMove(documentID: documentID, row: row, newParentID: parentID)

        XCTAssertEqual(env.childrenCache.children(for: oldParentID), [])
    }

    func testALandedMoveAppendsTheRowOnlyToALevelThatWasActuallyFetched() {
        let env = makeEnvironment()
        let row = document(id: documentID)
        let sibling = document(id: UUID(), title: "Sibling")
        env.childrenCache.save([sibling], for: parentID)

        env.coordinator.completeDocumentMove(documentID: documentID, row: row, newParentID: parentID)

        XCTAssertEqual(env.childrenCache.children(for: parentID)?.map(\.id), [sibling.id, documentID])
    }

    /// nil (never fetched) and `[]` (fetched, found nothing) are read as different everywhere,
    /// so a move must not invent a level out of the first.
    func testALandedMoveNeverFabricatesALevelThatWasNeverFetched() {
        let env = makeEnvironment()

        env.coordinator.completeDocumentMove(
            documentID: documentID, row: document(id: documentID), newParentID: parentID)

        XCTAssertNil(env.childrenCache.children(for: parentID))
    }

    /// The sweep runs before the insert, or it would strip the row it had just filed.
    func testMovingBetweenTwoCachedLevelsLeavesTheRowInTheNewOne() {
        let env = makeEnvironment()
        let row = document(id: documentID)
        let oldParentID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
        env.childrenCache.save([row], for: oldParentID)
        env.childrenCache.save([], for: parentID)

        env.coordinator.completeDocumentMove(documentID: documentID, row: row, newParentID: parentID)

        XCTAssertEqual(env.childrenCache.children(for: oldParentID), [])
        XCTAssertEqual(env.childrenCache.children(for: parentID)?.map(\.id), [documentID])
    }

    /// A move is not a deletion: the document's body and its own children level are still
    /// exactly right, and purging them would blank a document offline for no reason.
    func testALandedMoveKeepsTheDocumentsOwnBodyAndChildrenLevel() {
        let env = makeEnvironment()
        let row = document(id: documentID)
        let ownChild = document(id: UUID(), title: "Own child", depth: 2)
        env.childrenCache.save([ownChild], for: documentID)
        env.contentCache.save(
            CachedDocumentContent(
                documentID: documentID, title: "Q3 Planning", markdown: "# Body", syncedAt: Date()))

        env.coordinator.completeDocumentMove(documentID: documentID, row: row, newParentID: parentID)

        XCTAssertEqual(env.childrenCache.children(for: documentID)?.map(\.id), [ownChild.id])
        XCTAssertNotNil(env.contentCache.content(for: documentID))
    }

    func testADocumentFiledUnderAParentLeavesTheCachedRecentsList() {
        let env = makeEnvironment()
        let row = document(id: documentID)
        env.listCache.saveRecentDocuments([row])

        env.coordinator.completeDocumentMove(documentID: documentID, row: row, newParentID: parentID)

        XCTAssertEqual(env.listCache.loadRecentDocuments(), [])
    }

    /// The pinned and shared lists are about a favorite and about access, neither of which a
    /// move changes — dropping the row there would hide a document the next fetch returns.
    func testAMoveLeavesThePinnedAndSharedCachesAlone() {
        let env = makeEnvironment()
        var pinned = document(id: documentID)
        pinned.isFavorite = true
        env.listCache.savePinnedDocuments([pinned])
        env.listCache.saveSharedWithMeDocuments([pinned])

        env.coordinator.completeDocumentMove(documentID: documentID, row: pinned, newParentID: parentID)

        XCTAssertEqual(env.listCache.loadPinnedDocuments().map(\.id), [documentID])
        XCTAssertEqual(env.listCache.loadSharedWithMeDocuments()?.map(\.id), [documentID])
    }

    func testAPromotedDocumentJoinsTheCachedRecentsList() {
        let env = makeEnvironment()
        let existing = document(id: UUID(), title: "Existing")
        env.listCache.saveRecentDocuments([existing])
        let row = document(id: documentID, depth: 2)

        env.coordinator.completeDocumentMove(documentID: documentID, row: row, newParentID: nil)

        XCTAssertEqual(env.listCache.loadRecentDocuments()?.map(\.id), [documentID, existing.id])
    }

    /// Home's feed is unfiltered, so promoting a document it already lists is ordinary — and a
    /// duplicate id in a cached list becomes a duplicate row.
    func testAPromotionDoesNotDuplicateARowTheRecentsCacheAlreadyHolds() {
        let env = makeEnvironment()
        let row = document(id: documentID)
        env.listCache.saveRecentDocuments([row])

        env.coordinator.completeDocumentMove(documentID: documentID, row: row, newParentID: nil)

        XCTAssertEqual(env.listCache.loadRecentDocuments()?.filter { $0.id == documentID }.count, 1)
    }

    func testAPromotionNeverFabricatesARecentsListThatWasNeverCached() {
        let env = makeEnvironment()

        env.coordinator.completeDocumentMove(
            documentID: documentID, row: document(id: documentID, depth: 2), newParentID: nil)

        XCTAssertNil(env.listCache.loadRecentDocuments())
    }

    /// A mover without a row — the editor's Options sheet — still lands the move; it just has
    /// nothing to file, and the destination picks the document up on its next fetch.
    func testAMoveWithNoRowSweepsAndAnnouncesWithoutInventingOne() {
        let env = makeEnvironment()
        let oldParentID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
        env.childrenCache.save([document(id: documentID)], for: oldParentID)
        env.childrenCache.save([], for: parentID)
        let recorder = MoveRecorder()
        env.coordinator.observeDocumentMoved(recorder) { recorder.seen.append($0) }

        env.coordinator.completeDocumentMove(documentID: documentID, row: nil, newParentID: parentID)

        XCTAssertEqual(env.childrenCache.children(for: oldParentID), [])
        XCTAssertEqual(env.childrenCache.children(for: parentID), [])
        XCTAssertEqual(recorder.seen.map(\.documentID), [documentID])
        XCTAssertNil(recorder.seen.first?.row)
    }

    // MARK: - The fan-out

    func testTheMoveAnnouncementReachesEverySubscriber() {
        let env = makeEnvironment()
        let first = MoveRecorder()
        let second = MoveRecorder()
        env.coordinator.observeDocumentMoved(first) { first.seen.append($0) }
        env.coordinator.observeDocumentMoved(second) { second.seen.append($0) }

        env.coordinator.completeDocumentMove(
            documentID: documentID, row: document(id: documentID), newParentID: parentID)

        XCTAssertEqual(first.seen.count, 1)
        XCTAssertEqual(second.seen.count, 1)
    }

    /// The coordinator is app-scoped and outlives every screen, so a dead subscriber must be
    /// dropped rather than accumulating one entry per document ever opened.
    func testMoveObserversArePrunedOnceTheirOwnerIsGone() {
        let env = makeEnvironment()
        let survivor = MoveRecorder()
        env.coordinator.observeDocumentMoved(survivor) { survivor.seen.append($0) }
        do {
            // The handler must not capture its own owner, or the closure keeps alive the very
            // object whose weak reference is what this is testing — which is exactly why the
            // production observers all capture `[weak self]`.
            let transient = MoveRecorder()
            env.coordinator.observeDocumentMoved(transient) { _ in
                XCTFail("a deallocated observer must never be called")
            }
            XCTAssertEqual(env.coordinator.documentMovedObserverCountForTesting, 2, "precondition")
        }

        env.coordinator.completeDocumentMove(
            documentID: documentID, row: document(id: documentID), newParentID: parentID)

        XCTAssertEqual(survivor.seen.count, 1, "the live observer still hears about it")
        XCTAssertEqual(
            env.coordinator.documentMovedObserverCountForTesting, 1,
            "and the dead one is dropped, not merely skipped")
    }
}
