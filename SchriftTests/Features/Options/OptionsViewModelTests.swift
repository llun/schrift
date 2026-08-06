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

    private func makeLocalEnvironment() -> (
        coordinator: DocumentSaveCoordinator, document: Document, drafts: PendingDraftStore,
        creates: PendingDocumentCreateStore, client: DocsAPIClient
    ) {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let suiteName = "OptionsViewModelTests.local.\(UUID().uuidString)"
        localSuiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        let drafts = PendingDraftStore(userDefaults: defaults)
        let creates = PendingDocumentCreateStore(userDefaults: defaults)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: drafts, createStore: creates,
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)
        let document = coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil,
            ownerUserID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
        return (coordinator, document, drafts, creates, client)
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
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)
        let viewModel = OptionsViewModel(
            client: env.client, documentID: env.document.id, isFavorite: false, saveCoordinator: coordinator)

        await viewModel.delete()

        XCTAssertTrue(viewModel.didDelete)
        XCTAssertNil(viewModel.errorKey, "already gone is not an error")
        XCTAssertNil(env.creates.create(for: env.document.id), "and nothing is left to re-POST")
    }

    /// A failed server DELETE must leave everything: the record still names a live document,
    /// and discarding the local trace here would strand it permanently.
    func testAFailedServerDeleteKeepsTheRecord() async {
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }
        let env = makeLocalEnvironment()
        var record = env.creates.create(for: env.document.id)!
        record.syncedServerID = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
        env.creates.save(record)
        let coordinator = DocumentSaveCoordinator(
            client: env.client, draftStore: env.drafts, createStore: env.creates,
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)
        let viewModel = OptionsViewModel(
            client: env.client, documentID: env.document.id, isFavorite: false, saveCoordinator: coordinator)

        await viewModel.delete()

        XCTAssertFalse(viewModel.didDelete)
        XCTAssertNotNil(viewModel.errorKey)
        XCTAssertNotNil(env.creates.create(for: env.document.id), "not stranded")
    }
}
