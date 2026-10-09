import XCTest

@testable import Schrift

@MainActor
final class DocumentActionsMoveTests: DocumentActionsTestCase {
    /// A recorder standing in for a list screen. Held weakly by the coordinator, so a test
    /// must keep it alive itself.
    private final class MoveRecorder {
        var seen: [DocumentMoveEvent] = []
    }

    private func serverDocument(
        id: UUID, title: String = "Q3 Planning", depth: Int = 1, numchild: Int = 0
    ) -> Document {
        Document(
            id: id, title: title, excerpt: nil, abilities: DocumentAbilities(), linkReach: .restricted,
            linkRole: .reader, computedLinkReach: nil, computedLinkRole: nil, isFavorite: false,
            depth: depth, numchild: numchild, path: String(repeating: "0", count: 4 * depth),
            createdAt: Date(), updatedAt: Date(), userRole: .owner, creator: nil)
    }

    private func stubMoveOK(_ log: RequestRecorder? = nil) {
        MockURLProtocol.stubHandler = { request in
            log?.record(request)
            return .init(
                statusCode: 200, headers: [:],
                body: #"{"message": "Document moved successfully."}"#.data(using: .utf8)!, error: nil)
        }
    }

    func testMovingUnderAParentPostsTheChildPositionToTheMoveRoute() async {
        let log = RequestRecorder()
        stubMoveOK(log)
        let env = makeEnvironment()
        let parentID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

        let outcome = await env.actions.move(
            documentID: documentID, row: serverDocument(id: documentID),
            to: .under(parentID: parentID))

        XCTAssertEqual(outcome, .moved)
        XCTAssertEqual(log.count(ofMethod: "POST", urlContaining: "/move/"), 1)
        let body = MockURLProtocol.lastRequest.flatMap(bodyData(from:))
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        XCTAssertEqual(json?["position"], "last-child")
        XCTAssertEqual(json?["target_document_id"], parentID.uuidString.lowercased())
    }

    /// Promotion has no "no parent" target — the server takes a sibling root instead.
    func testMovingToTheTopLevelPostsTheSiblingPositionAtTheGivenRoot() async {
        stubMoveOK()
        let env = makeEnvironment()
        let siblingRootID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!

        let outcome = await env.actions.move(
            documentID: documentID, row: serverDocument(id: documentID, depth: 2),
            to: .root(siblingRootID: siblingRootID))

        XCTAssertEqual(outcome, .moved)
        let body = MockURLProtocol.lastRequest.flatMap(bodyData(from:))
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        XCTAssertEqual(json?["position"], "last-sibling")
        XCTAssertEqual(json?["target_document_id"], siblingRootID.uuidString.lowercased())
    }

    /// There is no offline queue for a move. A failure must leave
    /// the device exactly as it was rather than recording anything a replay would act on.
    func testAFailedMoveQueuesNothingAndChangesNothing() async {
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 400, headers: [:], body: Data(), error: nil)
        }
        let env = makeEnvironment()
        let recorder = MoveRecorder()
        env.coordinator.observeDocumentMoved(recorder) { recorder.seen.append($0) }

        let outcome = await env.actions.move(
            documentID: documentID, row: serverDocument(id: documentID),
            to: .under(parentID: UUID()))

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(recorder.seen.isEmpty, "nothing landed, so nothing may be announced")
        // "Queues nothing" means exactly this: unlike a failed delete, a failed move leaves no
        // record for any later pass to act on.
        XCTAssertNil(env.creates.create(for: documentID))
        XCTAssertNil(env.drafts.draft(for: documentID))
    }

    func testALandedMoveAnnouncesTheEventEveryListReactsTo() async {
        stubMoveOK()
        let env = makeEnvironment()
        let parentID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let row = serverDocument(id: documentID)
        let recorder = MoveRecorder()
        env.coordinator.observeDocumentMoved(recorder) { recorder.seen.append($0) }

        _ = await env.actions.move(documentID: documentID, row: row, to: .under(parentID: parentID))

        XCTAssertEqual(recorder.seen.count, 1)
        XCTAssertEqual(recorder.seen.first?.documentID, documentID)
        XCTAssertEqual(recorder.seen.first?.newParentID, parentID)
        XCTAssertEqual(recorder.seen.first?.row, row)
    }

    /// A document that exists only here is re-parented on the device — no request at all,
    /// because `documents/{local-uuid}/move/` names nothing on the server.
    func testMovingALocalDocumentRewritesItsRecordWithoutARequest() async {
        let log = RequestRecorder()
        stubMoveOK(log)
        let env = makeEnvironment()
        let parent = env.coordinator.createLocalDocument(
            title: "Parent", parentID: nil, ownerUserID: ownerID)
        let child = env.coordinator.createLocalDocument(
            title: "Child", parentID: nil, ownerUserID: ownerID)

        let outcome = await env.actions.move(
            documentID: child.id, row: child, to: .under(parentID: parent.id))

        XCTAssertEqual(outcome, .moved)
        XCTAssertEqual(log.count(ofMethod: "POST"), 0, "a local move never reaches the network")
        XCTAssertEqual(env.creates.create(for: child.id)?.parentID, parent.id)
    }

    func testMovingALocalDocumentToTheTopLevelClearsItsParent() async {
        let env = makeEnvironment()
        let parent = env.coordinator.createLocalDocument(
            title: "Parent", parentID: nil, ownerUserID: ownerID)
        let child = env.coordinator.createLocalDocument(
            title: "Child", parentID: parent.id, ownerUserID: ownerID)

        let outcome = await env.actions.move(
            documentID: child.id, row: child, to: .root(siblingRootID: nil))

        XCTAssertEqual(outcome, .moved)
        XCTAssertNil(env.creates.create(for: child.id)?.parentID)
    }

    /// A checkpointed record's POST has landed, so the document the user means is the *server*
    /// one — the local `parentID` is inert from that moment and rewriting it would move
    /// nothing.
    func testMovingACheckpointedDocumentAddressesItsServerID() async {
        let log = RequestRecorder()
        stubMoveOK(log)
        let env = makeEnvironment()
        let document = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: ownerID)
        var record = env.creates.create(for: document.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        let coordinator = DocumentSaveCoordinator(
            client: env.client, draftStore: env.drafts, contentCache: env.contentCache,
            createStore: env.creates, deleteStore: env.deletes,
            listCache: DocumentCacheStore(userDefaults: env.defaults),
            childrenCache: DocumentChildrenCacheStore(userDefaults: env.defaults),
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)
        let actions = DocumentActions(
            client: env.client, saveCoordinator: coordinator, signedInUser: env.signedIn)
        let parentID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let recorder = MoveRecorder()
        coordinator.observeDocumentMoved(recorder) { recorder.seen.append($0) }

        let outcome = await actions.move(
            documentID: document.id, row: document, to: .under(parentID: parentID))

        XCTAssertEqual(outcome, .moved)
        XCTAssertEqual(log.count(ofMethod: "POST", urlContaining: serverID.uuidString.lowercased()), 1)
        // The caches and every list row for this document are keyed by the server id, so the
        // announcement must be too — under the local one it would sweep and re-file nothing.
        XCTAssertEqual(recorder.seen.first?.documentID, serverID)
        // …and the row is **dropped**, because the one the caller had here is synthetic. A
        // `localDocument(from:)` row must never reach a persisted cache, and re-keying it onto
        // the server id is exactly what would make a leak undetectable — a client-minted id
        // 404s on every fetch, a re-keyed one is indistinguishable from a real row. The cost is
        // only that the destination picks the document up on its next fetch.
        XCTAssertNil(recorder.seen.first?.row)
    }

    /// A server document cannot be filed under a client-minted id: the POST would 404, and
    /// `retryableSaveFailure` rightly refuses to retry one.
    func testAServerDocumentIsNeverMovedUnderALocalParent() async {
        let log = RequestRecorder()
        stubMoveOK(log)
        let env = makeEnvironment()
        let localParent = env.coordinator.createLocalDocument(
            title: "Parent", parentID: nil, ownerUserID: ownerID)

        let outcome = await env.actions.move(
            documentID: documentID, row: serverDocument(id: documentID),
            to: .under(parentID: localParent.id))

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(log.count(ofMethod: "POST"), 0)
    }

    /// **The headline offline case**: create at the top level with no network, then file the
    /// result under an existing server document. The destination is a real server id the
    /// pending record simply points at; the replay creates the document in the right place.
    func testALocalDocumentCanBeFiledUnderAServerRootWithNoRequest() async {
        let log = RequestRecorder()
        stubMoveOK(log)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Created offline", parentID: nil, ownerUserID: ownerID)
        let serverRootID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!

        let outcome = await env.actions.move(
            documentID: local.id, row: local, to: .under(parentID: serverRootID))

        XCTAssertEqual(outcome, .moved)
        XCTAssertEqual(log.count(ofMethod: "POST"), 0)
        XCTAssertEqual(env.creates.create(for: local.id)?.parentID, serverRootID)
    }

    /// The ladder's `? .moved : .failed` false arm — a refusal must travel back to the caller
    /// as a failure it can report, not be swallowed into an apparent success.
    func testALocalMoveTheCoordinatorRefusesIsReportedAsAFailure() async {
        let log = RequestRecorder()
        stubMoveOK(log)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Moving", parentID: nil, ownerUserID: ownerID)

        let outcome = await env.actions.move(
            documentID: local.id, row: local, to: .under(parentID: local.id))

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(log.count(ofMethod: "POST"), 0)
    }

    /// **A local move announces nothing and writes no persisted cache.** The whole propagation
    /// is the version bump plus each surface's read-time merge — and it must stay that way,
    /// because the row a surface would hand over here is a `localDocument(from:)` synthetic,
    /// which must never enter a metadata cache.
    func testALocalMoveAnnouncesNothingAndWritesNoPersistedCache() async {
        let env = makeEnvironment()
        let listCache = DocumentCacheStore(userDefaults: env.defaults)
        let childrenCache = DocumentChildrenCacheStore(userDefaults: env.defaults)
        listCache.saveRecentDocuments([])
        let parent = env.coordinator.createLocalDocument(
            title: "Parent", parentID: nil, ownerUserID: ownerID)
        childrenCache.save([], for: parent.id)
        let moving = env.coordinator.createLocalDocument(
            title: "Moving", parentID: nil, ownerUserID: ownerID)
        let recorder = MoveRecorder()
        env.coordinator.observeDocumentMoved(recorder) { recorder.seen.append($0) }

        let outcome = await env.actions.move(
            documentID: moving.id, row: moving, to: .under(parentID: parent.id))

        XCTAssertEqual(outcome, .moved)
        XCTAssertTrue(recorder.seen.isEmpty, "a local move has nothing to announce")
        XCTAssertEqual(listCache.loadRecentDocuments(), [], "and no synthetic row may be cached")
        XCTAssertEqual(childrenCache.children(for: parent.id), [])
    }

    /// The tombstone outlives the move, so the only thing success would buy is a document
    /// deleted from somewhere else.
    func testADocumentAlreadyQueuedForDeletionIsNotMoved() async {
        let log = RequestRecorder()
        stubMoveOK(log)
        let env = makeEnvironment()
        env.coordinator.recordPendingDelete(documentID: documentID, ownerUserID: ownerID)

        let outcome = await env.actions.move(
            documentID: documentID, row: serverDocument(id: documentID),
            to: .under(parentID: UUID()))

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(log.count(ofMethod: "POST"), 0)
    }

    /// **On the unscoped predicate**, deliberately: the picker filters destinations with the
    /// *scoped* one, which answers false for an unattributable or foreign-account tombstone —
    /// so this guard is the only thing standing between the user and filing a subtree into a
    /// document that is on its way out.
    func testAServerDocumentIsNeverFiledUnderATombstonedParent() async {
        let log = RequestRecorder()
        stubMoveOK(log)
        let env = makeEnvironment()
        let parentID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        env.coordinator.recordPendingDelete(documentID: parentID, ownerUserID: ownerID)

        let outcome = await env.actions.move(
            documentID: documentID, row: serverDocument(id: documentID),
            to: .under(parentID: parentID))

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(log.count(ofMethod: "POST"), 0)
    }

    /// Promotion needs a root to sit beside. Without one there is no request to make, and
    /// reporting failure is honest — the picker withholds the affordance for this reason.
    func testAServerDocumentCannotBePromotedWithoutASiblingRoot() async {
        let log = RequestRecorder()
        stubMoveOK(log)
        let env = makeEnvironment()

        let outcome = await env.actions.move(
            documentID: documentID, row: serverDocument(id: documentID, depth: 2),
            to: .root(siblingRootID: nil))

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(log.count(ofMethod: "POST"), 0)
    }
}
