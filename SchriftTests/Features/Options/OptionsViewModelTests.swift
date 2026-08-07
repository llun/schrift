import XCTest

@testable import Schrift

final class DocumentShareURLTests: XCTestCase {
    func testBuildsExpectedURL() {
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        XCTAssertEqual(
            documentShareURL(serverHost: "docs.llun.dev", documentID: id)?.absoluteString,
            "https://docs.llun.dev/docs/11111111-1111-4111-8111-111111111111/"
        )
    }
}

@MainActor
final class OptionsViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    private var localSuiteNames: [String] = []

    override func tearDown() {
        for name in localSuiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        localSuiteNames.removeAll()
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeViewModel(isFavorite: Bool = false) -> OptionsViewModel {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        return OptionsViewModel(client: client, documentID: documentID, isFavorite: isFavorite)
    }

    func testToggleFavoriteFlipsStateOnSuccess() async {
        let viewModel = makeViewModel(isFavorite: false)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 201, headers: [:], body: Data(), error: nil) }

        await viewModel.toggleFavorite()

        XCTAssertTrue(viewModel.isFavorite)
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertNil(viewModel.errorKey)
    }

    func testToggleFavoriteFailureKeepsStateAndSetsError() async {
        let viewModel = makeViewModel(isFavorite: false)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.toggleFavorite()

        XCTAssertFalse(viewModel.isFavorite)
        XCTAssertEqual(viewModel.errorKey, .options_error_toggle_favorite)
    }

    func testDeleteSetsDidDeleteOnSuccess() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 204, headers: [:], body: Data(), error: nil) }

        await viewModel.delete()

        XCTAssertTrue(viewModel.didDelete)
        XCTAssertFalse(viewModel.isDeleting)
        XCTAssertNil(viewModel.errorKey)
    }

    func testDeleteFailureSetsErrorAndDoesNotSetDidDelete() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.delete()

        XCTAssertFalse(viewModel.didDelete)
        XCTAssertEqual(viewModel.errorKey, .options_error_delete)
    }

    // MARK: - Locally-created documents

    /// Every store on this test's own suite. The create and **delete** stores especially: a
    /// coordinator that falls back to `UserDefaults.standard` writes real records into the
    /// shared domain, and a later pass then issues a genuine `/users/me/` that escapes
    /// `MockURLProtocol` and stalls the run for a minute.
    private func makeLocalEnvironment() -> (
        coordinator: DocumentSaveCoordinator, document: Document, drafts: PendingDraftStore,
        creates: PendingDocumentCreateStore, deletes: PendingDocumentDeleteStore,
        signedIn: SignedInUserStore, client: DocsAPIClient
    ) {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let suiteName = "OptionsViewModelTests.local.\(UUID().uuidString)"
        localSuiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        let drafts = PendingDraftStore(userDefaults: defaults)
        let creates = PendingDocumentCreateStore(userDefaults: defaults)
        let deletes = PendingDocumentDeleteStore(userDefaults: defaults)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: drafts, createStore: creates, deleteStore: deletes,
            listCache: DocumentCacheStore(userDefaults: defaults),
            childrenCache: DocumentChildrenCacheStore(userDefaults: defaults),
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)
        let document = coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil,
            ownerUserID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
        let signedIn = SignedInUserStore(userDefaults: defaults)
        signedIn.remember(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
        return (coordinator, document, drafts, creates, deletes, signedIn, client)
    }

    /// A document that exists nowhere but here has nothing to DELETE — the request would 404.
    /// Dropping the record and its draft *is* the delete.
    func testDeletingALocalDocumentIssuesNoServerDelete() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        let env = makeLocalEnvironment()
        let viewModel = OptionsViewModel(
            client: env.client, documentID: env.document.id, isFavorite: false,
            saveCoordinator: env.coordinator)

        await viewModel.delete()

        XCTAssertEqual(log.count(ofMethod: "DELETE"), 0)
        XCTAssertTrue(viewModel.didDelete)
        XCTAssertNil(env.creates.create(for: env.document.id), "the record goes")
        XCTAssertNil(env.drafts.draft(for: env.document.id), "and its draft, so no replay revives it")
    }

    /// Deleting a local document takes the sub-pages created under it, and the sheet says so
    /// beforehand — they exist nowhere else, so this is the one delete confirmation that has
    /// something to add beyond its title.
    func testDeletingALocalDocumentAnnouncesAndTakesItsSubpages() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        let env = makeLocalEnvironment()
        let viewModel = OptionsViewModel(
            client: env.client, documentID: env.document.id, isFavorite: false,
            saveCoordinator: env.coordinator)
        XCTAssertFalse(viewModel.hasLocalSubpages, "nothing extra to warn about yet")

        let child = env.coordinator.createLocalDocument(
            title: "Child", parentID: env.document.id,
            ownerUserID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)

        XCTAssertTrue(viewModel.hasLocalSubpages)

        await viewModel.delete()

        XCTAssertEqual(log.count(ofMethod: "DELETE"), 0, "neither document is on a server")
        XCTAssertNil(env.creates.create(for: child.id), "and the sub-page goes with its parent")
        XCTAssertNil(env.drafts.draft(for: child.id))
    }

    /// The warning is about what *this delete* will take, not about the relation. A sub-page
    /// created offline under an ordinary server document is a perfectly ordinary record — and
    /// deleting that server document does not take it, so saying it would be a false sentence
    /// in a destructive confirmation. Staged with a real local child, since asking about a
    /// document that has none can only ever pass.
    func testAServerDocumentNeverAnnouncesSubpagesItsDeleteWouldNotTake() {
        let env = makeLocalEnvironment()
        let serverParent = UUID()
        env.coordinator.createLocalDocument(
            title: "Child", parentID: serverParent,
            ownerUserID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
        let viewModel = OptionsViewModel(
            client: env.client, documentID: serverParent, isFavorite: false, saveCoordinator: env.coordinator)

        XCTAssertFalse(viewModel.hasLocalSubpages)
    }

    /// Once checkpointed the POST has landed, so a real server document exists even though
    /// `isPendingCreate` is still true. Treating it as purely local would leave that copy
    /// alive, to reappear in Home's next list fetch with nothing on the device knowing about it.
    func testDeletingACheckpointedLocalDocumentDeletesTheServerCopyToo() async {
        let log = RequestRecorder()
        let serverID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        let env = makeLocalEnvironment()
        var record = env.creates.create(for: env.document.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // Relaunch so the coordinator's mirror carries the checkpoint.
        let coordinator = DocumentSaveCoordinator(
            client: env.client, draftStore: env.drafts, createStore: env.creates,
            deleteStore: env.deletes,
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)
        let viewModel = OptionsViewModel(
            client: env.client, documentID: env.document.id, isFavorite: false, saveCoordinator: coordinator)

        await viewModel.delete()

        XCTAssertEqual(log.count(ofMethod: "DELETE", urlContaining: serverID.uuidString.lowercased()), 1)
        XCTAssertTrue(viewModel.didDelete)
        XCTAssertNil(env.creates.create(for: env.document.id))
    }

    /// A **404** is not a failure to report: it is indistinguishable from a co-author having
    /// deleted the document first, and keeping the record re-arms the resurrection — the next
    /// resume takes the same 404, clears the checkpoint, and the pass after that re-POSTs the
    /// document from its draft, back with its old body under a new id.
    func testAnAlreadyDeletedServerCopyStillClearsTheRecord() async {
        MockURLProtocol.stubHandler = { _ in
            .init(
                statusCode: 404, headers: ["Content-Type": "application/json"],
                body: Data(#"{"detail":"Not found."}"#.utf8), error: nil)
        }
        let env = makeLocalEnvironment()
        var record = env.creates.create(for: env.document.id)!
        record.syncedServerID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
        env.creates.save(record)
        let coordinator = DocumentSaveCoordinator(
            client: env.client, draftStore: env.drafts, createStore: env.creates,
            deleteStore: env.deletes,
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)
        let viewModel = OptionsViewModel(
            client: env.client, documentID: env.document.id, isFavorite: false, saveCoordinator: coordinator)

        await viewModel.delete()

        XCTAssertTrue(viewModel.didDelete)
        XCTAssertNil(viewModel.errorKey, "already gone is not an error")
        XCTAssertNil(env.creates.create(for: env.document.id), "and nothing is left to re-POST")
    }

    /// A server DELETE rejected **on the merits** must leave everything and say so: the
    /// record still names a live document, and discarding the local trace here would strand
    /// it permanently. Queueing would be worse — it would promise a replay the server has
    /// already refused.
    func testAServerDeleteRejectedOnTheMeritsKeepsTheRecordAndReports() async {
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 403, headers: [:], body: Data(), error: nil)
        }
        let env = makeLocalEnvironment()
        let serverID = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
        let viewModel = checkpointedViewModel(env, serverID: serverID)

        await viewModel.delete()

        XCTAssertFalse(viewModel.didDelete)
        XCTAssertNotNil(viewModel.errorKey)
        XCTAssertNotNil(env.creates.create(for: env.document.id), "not stranded")
        XCTAssertNil(env.deletes.pendingDelete(for: serverID), "and nothing queued to retry")
    }

    // MARK: - Deletions queued while the server is out of reach

    /// Builds the view model for a **checkpointed** record — the POST landed, so a real server
    /// document exists under `serverID` — with every store on the environment's own suite.
    private func checkpointedViewModel(
        _ env: (
            coordinator: DocumentSaveCoordinator, document: Document, drafts: PendingDraftStore,
            creates: PendingDocumentCreateStore, deletes: PendingDocumentDeleteStore,
            signedIn: SignedInUserStore, client: DocsAPIClient
        ),
        serverID: UUID
    ) -> OptionsViewModel {
        var record = env.creates.create(for: env.document.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // Rebuilt so the mirror picks the checkpoint up, exactly as a relaunch would.
        let coordinator = DocumentSaveCoordinator(
            client: env.client, draftStore: env.drafts, createStore: env.creates, deleteStore: env.deletes,
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)
        return OptionsViewModel(
            client: env.client, documentID: env.document.id, isFavorite: false,
            saveCoordinator: coordinator, signedInUser: env.signedIn)
    }

    private func makeServerViewModel(
        signedInUserID: UUID? = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    ) -> (viewModel: OptionsViewModel, coordinator: DocumentSaveCoordinator, deletes: PendingDocumentDeleteStore) {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let suiteName = "OptionsViewModelTests.server.\(UUID().uuidString)"
        localSuiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        let deletes = PendingDocumentDeleteStore(userDefaults: defaults)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: PendingDraftStore(userDefaults: defaults),
            createStore: PendingDocumentCreateStore(userDefaults: defaults), deleteStore: deletes,
            listCache: DocumentCacheStore(userDefaults: defaults),
            childrenCache: DocumentChildrenCacheStore(userDefaults: defaults),
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)
        let signedIn = SignedInUserStore(userDefaults: defaults)
        if let signedInUserID { signedIn.remember(signedInUserID) }
        let viewModel = OptionsViewModel(
            client: client, documentID: documentID, isFavorite: false,
            saveCoordinator: coordinator, signedInUser: signedIn)
        return (viewModel, coordinator, deletes)
    }

    /// The reported case: deleting while the server cannot be reached queues the deletion and
    /// reports the document as deleted, so the screen pops and every list strikes the row
    /// through — rather than leaving the sheet up with "Couldn't delete document".
    func testAnUnreachableServerQueuesTheDeletionAndPops() async {
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        let env = makeServerViewModel()

        await env.viewModel.delete()

        XCTAssertTrue(env.viewModel.didDelete, "the screen pops")
        XCTAssertTrue(env.viewModel.didQueueDelete, "but as a queued deletion, not a made one")
        XCTAssertNil(env.viewModel.errorKey)
        XCTAssertTrue(env.coordinator.isPendingDelete(documentID: documentID))
        XCTAssertEqual(env.deletes.pendingDelete(for: documentID)?.ownerUserID, signedInUserID)
    }

    /// A 5xx and a rate limit are worth retrying too — the classification is the failure the
    /// server actually gave us, never an `isOffline` flag.
    func testRetryableServerFailuresQueueTheDeletionToo() async {
        for status in [500, 429] {
            MockURLProtocol.stubHandler = { _ in .init(statusCode: status, headers: [:], body: Data(), error: nil) }
            let env = makeServerViewModel()

            await env.viewModel.delete()

            XCTAssertTrue(env.viewModel.didQueueDelete, "queued for \(status)")
            XCTAssertNil(env.viewModel.errorKey)
            MockURLProtocol.reset()
        }
    }

    /// **Already gone reads as deleted, not as a failure.** The reasoning the checkpointed
    /// branch always had, which the plain server branch was simply missing: a 404 is what a
    /// co-author's delete looks like, and reporting "Couldn't delete" about a document that
    /// is already gone asks the user to retry something with no work left in it.
    func testAnAlreadyDeletedServerDocumentReadsAsDeleted() async {
        MockURLProtocol.stubHandler = { _ in
            .init(
                statusCode: 404, headers: ["Content-Type": "application/json"],
                body: Data(#"{"detail":"Not found."}"#.utf8), error: nil)
        }
        let env = makeServerViewModel()

        await env.viewModel.delete()

        XCTAssertTrue(env.viewModel.didDelete)
        XCTAssertFalse(env.viewModel.didQueueDelete, "nothing to send — it is already gone")
        XCTAssertNil(env.viewModel.errorKey)
        XCTAssertFalse(env.coordinator.isPendingDelete(documentID: documentID))
    }

    func testARejectionOnTheMeritsStillReportsTheError() async {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 403, headers: [:], body: Data(), error: nil) }
        let env = makeServerViewModel()

        await env.viewModel.delete()

        XCTAssertFalse(env.viewModel.didDelete)
        XCTAssertEqual(env.viewModel.errorKey, .options_error_delete)
        XCTAssertFalse(env.coordinator.isPendingDelete(documentID: documentID))
    }

    /// A deletion nobody can be attributed to would be neither sent nor shown — it would
    /// vanish, leaving a row that looks alive. Better to say the deletion failed.
    func testQueueingRequiresAKnownAccount() async {
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        let env = makeServerViewModel(signedInUserID: nil)

        await env.viewModel.delete()

        XCTAssertFalse(env.viewModel.didDelete)
        XCTAssertEqual(env.viewModel.errorKey, .options_error_delete)
        XCTAssertFalse(env.coordinator.isPendingDelete(documentID: documentID))
    }

    /// A **checkpointed** record queues under its `syncedServerID` — the id that exists —
    /// and keeps every local trace, because those are what the undo restores.
    /// `completePendingDelete` removes them once the DELETE has really landed.
    func testAQueuedDeletionOfACheckpointedRecordKeepsTheRecordAndDraft() async {
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        let env = makeLocalEnvironment()
        let serverID = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
        let viewModel = checkpointedViewModel(env, serverID: serverID)

        await viewModel.delete()

        XCTAssertTrue(viewModel.didQueueDelete)
        XCTAssertEqual(
            env.deletes.pendingDelete(for: serverID)?.documentID, serverID,
            "queued under the id the server actually has")
        XCTAssertNotNil(env.creates.create(for: env.document.id), "the record is the undo's payload")
        XCTAssertNotNil(env.drafts.draft(for: env.document.id), "and so is its body")
    }

    /// An **un-checkpointed** local document has nothing to DELETE, so it is deleted outright
    /// with no tombstone — offline or not.
    func testAnUncheckpointedLocalDocumentStillDeletesInstantly() async {
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        let env = makeLocalEnvironment()
        let viewModel = OptionsViewModel(
            client: env.client, documentID: env.document.id, isFavorite: false,
            saveCoordinator: env.coordinator, signedInUser: env.signedIn)

        await viewModel.delete()

        XCTAssertTrue(viewModel.didDelete)
        XCTAssertFalse(viewModel.didQueueDelete, "nothing to queue — the server never knew it")
        XCTAssertTrue(env.deletes.allDeletes().isEmpty)
        XCTAssertNil(env.creates.create(for: env.document.id), "the record goes, as it always did")
    }

    private var signedInUserID: UUID { UUID(uuidString: "11111111-1111-4111-8111-111111111111")! }
}
