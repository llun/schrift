import XCTest

@testable import Schrift

/// The delete ladder, tested at the layer that owns it.
///
/// `OptionsViewModelTests` still covers the same branches through the sheet and is what
/// proves the extraction preserved behaviour — it passes unedited. These add the part that
/// is genuinely new: an immediate delete now purges the device and announces, which the
/// editor used to do for the one screen it was on and which no list surface could do at all.
@MainActor
final class DocumentActionsTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let ownerID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let serverID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    private var suiteNames: [String] = []
    private var cacheDirectories: [URL] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        for directory in cacheDirectories { try? FileManager.default.removeItem(at: directory) }
        cacheDirectories.removeAll()
        MockURLProtocol.reset()
        super.tearDown()
    }

    private struct Environment {
        let actions: DocumentActions
        let coordinator: DocumentSaveCoordinator
        let drafts: PendingDraftStore
        let creates: PendingDocumentCreateStore
        let deletes: PendingDocumentDeleteStore
        let contentCache: DocumentContentCacheStore
        let client: DocsAPIClient
        let defaults: UserDefaults
        let signedIn: SignedInUserStore
    }

    private func makeEnvironment(signedInUserID: UUID? = nil) -> Environment {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let suiteName = "DocumentActionsTests.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        let drafts = PendingDraftStore(userDefaults: defaults)
        let creates = PendingDocumentCreateStore(userDefaults: defaults)
        let deletes = PendingDocumentDeleteStore(userDefaults: defaults)
        // Its own directory, never the real Application Support one — these tests write and
        // delete document bodies, and the shared store is not suite-scoped the way the
        // UserDefaults-backed ones are.
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentActionsTests/\(UUID().uuidString)", isDirectory: true)
        cacheDirectories.append(cacheDirectory)
        let contentCache = DocumentContentCacheStore(directory: cacheDirectory)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: drafts, contentCache: contentCache,
            createStore: creates, deleteStore: deletes,
            listCache: DocumentCacheStore(userDefaults: defaults),
            childrenCache: DocumentChildrenCacheStore(userDefaults: defaults),
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)
        let signedIn = SignedInUserStore(userDefaults: defaults)
        signedIn.remember(signedInUserID ?? ownerID)
        return Environment(
            actions: DocumentActions(client: client, saveCoordinator: coordinator, signedInUser: signedIn),
            coordinator: coordinator, drafts: drafts, creates: creates, deletes: deletes,
            contentCache: contentCache, client: client, defaults: defaults, signedIn: signedIn)
    }

    /// A recorder that stands in for a list screen: the coordinator holds observers weakly, so
    /// this must be kept alive for the duration of the test.
    private final class DeletionRecorder {
        var seen: [UUID] = []
    }

    private func stubNoContent(_ log: RequestRecorder? = nil) {
        MockURLProtocol.stubHandler = { request in
            log?.record(request)
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
    }

    // MARK: - The plain server document

    func testASuccessfulDeleteReportsDeleted() async {
        stubNoContent()
        let env = makeEnvironment()
        let outcome = await env.actions.delete(documentID: documentID)
        XCTAssertEqual(outcome, .deleted)
    }

    /// **The addition.** Before this, an immediate delete purged nothing — the editor's
    /// `handleDidDelete` did it, and only for the screen it was on. A swipe on a list has no
    /// editor, so without this the deleted document's body stayed cached and every other
    /// surface kept its row until a revalidation that offline never brings.
    func testASuccessfulDeletePurgesTheCachedBodyAndAnnounces() async {
        stubNoContent()
        let env = makeEnvironment()
        env.contentCache.save(
            CachedDocumentContent(
                documentID: documentID, title: "Q3 Planning", markdown: "# Body", syncedAt: Date()))
        XCTAssertNotNil(env.contentCache.content(for: documentID), "precondition")

        let recorder = DeletionRecorder()
        env.coordinator.observeDocumentDeleted(recorder) { recorder.seen.append($0) }

        _ = await env.actions.delete(documentID: documentID)

        XCTAssertNil(env.contentCache.content(for: documentID))
        XCTAssertEqual(recorder.seen, [documentID], "every list surface learns through this")
    }

    /// A 404 is what a co-author's delete looks like. Reporting it would ask the user to
    /// retry something with no work left in it.
    func testAnAlreadyDeletedDocumentReadsAsDeleted() async {
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 404, headers: ["Content-Type": "application/json"], body: Data("{}".utf8), error: nil)
        }
        let env = makeEnvironment()
        let outcome = await env.actions.delete(documentID: documentID)
        XCTAssertEqual(outcome, .deleted)
        XCTAssertFalse(env.coordinator.isPendingDelete(documentID: documentID))
    }

    func testARejectionOnTheMeritsFails() async {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 403, headers: [:], body: Data(), error: nil) }
        let env = makeEnvironment()
        let outcome = await env.actions.delete(documentID: documentID)
        XCTAssertEqual(outcome, .failed)
        XCTAssertFalse(env.coordinator.isPendingDelete(documentID: documentID), "nothing was queued")
    }

    func testARetryableFailureQueuesTheDeletionUnderTheSameID() async {
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        let env = makeEnvironment()
        let outcome = await env.actions.delete(documentID: documentID)
        XCTAssertEqual(outcome, .queued(serverID: documentID))
        XCTAssertEqual(env.deletes.pendingDelete(for: documentID)?.ownerUserID, ownerID)
    }

    func testEveryRetryableStatusQueues() async {
        for status in [500, 503, 429] {
            MockURLProtocol.reset()
            MockURLProtocol.stubHandler = { _ in .init(statusCode: status, headers: [:], body: Data(), error: nil) }
            let env = makeEnvironment()
            let outcome = await env.actions.delete(documentID: documentID)
            XCTAssertEqual(outcome, .queued(serverID: documentID), "status \(status) should queue")
        }
    }

    /// A deletion nobody can be attributed to would be neither sent nor shown — it would
    /// vanish, leaving a row that looks alive.
    func testQueueingRequiresAKnownAccount() async {
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let suiteName = "DocumentActionsTests.anon.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        let deletes = PendingDocumentDeleteStore(userDefaults: defaults)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: PendingDraftStore(userDefaults: defaults),
            createStore: PendingDocumentCreateStore(userDefaults: defaults), deleteStore: deletes,
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)
        // No `remember` — the account is unknown.
        let actions = DocumentActions(
            client: client, saveCoordinator: coordinator,
            signedInUser: SignedInUserStore(userDefaults: defaults))

        let outcome = await actions.delete(documentID: documentID)
        XCTAssertEqual(outcome, .failed)
        XCTAssertNil(deletes.pendingDelete(for: documentID))
    }

    // MARK: - Locally created documents

    func testAnUncheckpointedLocalDocumentIsDeletedWithNoRequest() async {
        let log = RequestRecorder()
        stubNoContent(log)
        let env = makeEnvironment()
        let document = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: ownerID)

        let outcome = await env.actions.delete(documentID: document.id)
        XCTAssertEqual(outcome, .deleted)
        XCTAssertEqual(log.count(ofMethod: "DELETE"), 0, "there is nothing on the server to delete")
        XCTAssertNil(env.creates.create(for: document.id))
        XCTAssertNil(env.drafts.draft(for: document.id))
    }

    func testACheckpointedRecordDeletesItsServerCopyToo() async {
        let log = RequestRecorder()
        stubNoContent(log)
        let env = makeEnvironment()
        let document = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: ownerID)
        var record = env.creates.create(for: document.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // Rebuilt so the mirror picks the checkpoint up, exactly as a relaunch would.
        let coordinator = DocumentSaveCoordinator(
            client: env.client, draftStore: env.drafts, createStore: env.creates, deleteStore: env.deletes,
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)
        let actions = DocumentActions(
            client: env.client, saveCoordinator: coordinator, signedInUser: env.signedIn)

        let outcome = await actions.delete(documentID: document.id)
        XCTAssertEqual(outcome, .deleted)
        XCTAssertEqual(
            log.count(ofMethod: "DELETE", urlContaining: serverID.uuidString.lowercased()), 1)
        XCTAssertNil(env.creates.create(for: document.id), "or a replay would re-POST it")
    }

    /// **The resurrection guard.**
    ///
    /// A checkpointed record's document is met from a *list* under its **server** id, where
    /// `isPendingCreate` answers false — so the pending-create branch never runs and, before
    /// `completeImmediateDelete`, nothing cleared the create record or its draft. The next
    /// resume would GET that id, take the expected 404, clear the checkpoint, and the pass
    /// after that would re-POST the document the user had just deleted, body and all.
    ///
    /// This is the one case the naive port of the ladder would have shipped broken, and it is
    /// unreachable from the Options sheet, which always addresses the *local* id.
    func testDeletingACheckpointedDocumentByItsServerIDClearsTheRecordThatWouldRePostIt() async {
        stubNoContent()
        let env = makeEnvironment()
        let document = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: ownerID)
        var record = env.creates.create(for: document.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        let coordinator = DocumentSaveCoordinator(
            client: env.client, draftStore: env.drafts, createStore: env.creates, deleteStore: env.deletes,
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)
        let actions = DocumentActions(
            client: env.client, saveCoordinator: coordinator, signedInUser: env.signedIn)

        // Deleted the way a list row addresses it — by the server id, not the local one.
        let outcome = await actions.delete(documentID: serverID)
        XCTAssertEqual(outcome, .deleted)

        XCTAssertNil(
            env.creates.create(for: document.id),
            "the create record survived and would re-POST the deleted document")
        XCTAssertNil(env.drafts.draft(for: document.id), "…and its body with it")
    }

    /// Nothing local is cleared on the queued path: the record, its draft and its subtree are
    /// exactly what the undo restores.
    func testAQueuedDeletionOfACheckpointedRecordKeepsTheRecordAndDraft() async {
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        let env = makeEnvironment()
        let document = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: ownerID)
        var record = env.creates.create(for: document.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        let coordinator = DocumentSaveCoordinator(
            client: env.client, draftStore: env.drafts, createStore: env.creates, deleteStore: env.deletes,
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)
        let actions = DocumentActions(
            client: env.client, saveCoordinator: coordinator, signedInUser: env.signedIn)

        let outcome = await actions.delete(documentID: document.id)
        XCTAssertEqual(outcome, .queued(serverID: serverID))
        XCTAssertNotNil(env.creates.create(for: document.id))
        XCTAssertNotNil(env.drafts.draft(for: document.id))
        XCTAssertEqual(env.deletes.pendingDelete(for: serverID)?.ownerUserID, ownerID)
    }

    // MARK: - Predicates

    func testALocallyCreatedDocumentIsReportedAsLocal() {
        let env = makeEnvironment()
        let document = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: ownerID)
        XCTAssertTrue(env.actions.isLocalDocument(document.id))
        XCTAssertFalse(env.actions.isLocalDocument(documentID))
    }

    // MARK: - Favorite

    func testPinningPostsAndReportsTheNewState() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 201, headers: [:], body: Data(), error: nil)
        }
        let env = makeEnvironment()
        let outcome = await env.actions.setFavorite(documentID: documentID, isFavorite: true)
        XCTAssertEqual(outcome, .changed(isFavorite: true))
        XCTAssertEqual(
            log.count(ofMethod: "POST", urlContaining: "\(documentID.uuidString.lowercased())/favorite/"), 1)
    }

    func testUnpinningSendsADelete() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        let env = makeEnvironment()
        let outcome = await env.actions.setFavorite(documentID: documentID, isFavorite: false)
        XCTAssertEqual(outcome, .changed(isFavorite: false))
        XCTAssertEqual(
            log.count(ofMethod: "DELETE", urlContaining: "\(documentID.uuidString.lowercased())/favorite/"), 1)
    }

    /// There is no offline queue for favorites, so a failure is reported rather than
    /// optimistically applied and rolled back.
    func testAFailedFavoriteReportsFailure() async {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        let env = makeEnvironment()
        let outcome = await env.actions.setFavorite(documentID: documentID, isFavorite: true)
        XCTAssertEqual(outcome, .failed)
    }
}
