import XCTest

@testable import Schrift

/// `openLinkedDocument` — resolving a `/docs/<uuid>/` link tapped in the reading
/// surface into the `Document` the view pushes. The URL classification it acts on
/// is pinned separately by `DocumentLinkTests`.
@MainActor
final class EditorViewModelLinkTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!
    private let linkedID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    private var cacheDirectory: URL!
    private var childrenCache: DocumentChildrenCacheStore!
    private var childrenSuiteName: String!

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorViewModelLinkTests.\(UUID().uuidString)", isDirectory: true)
        childrenSuiteName = "EditorViewModelLinkTests.children.\(UUID().uuidString)"
        childrenCache = DocumentChildrenCacheStore(userDefaults: UserDefaults(suiteName: childrenSuiteName)!)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: cacheDirectory)
        UserDefaults(suiteName: childrenSuiteName)?.removePersistentDomain(forName: childrenSuiteName)
        super.tearDown()
    }

    private func makeViewModel() -> EditorViewModel {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let suiteName = "EditorViewModelLinkTests.\(UUID().uuidString)"
        let draftStore = PendingDraftStore(userDefaults: UserDefaults(suiteName: suiteName)!)
        let contentCache = DocumentContentCacheStore(directory: cacheDirectory)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: draftStore, contentCache: contentCache, backgroundTasks: .noop)
        return EditorViewModel(
            client: client, documentID: documentID, title: "Q3 Planning", saveCoordinator: coordinator,
            contentCache: contentCache, childrenCache: childrenCache)
    }

    // `nonisolated`: read from inside the `@Sendable` stub handler, which does not run on
    // the main actor this test class is isolated to.
    private nonisolated static func documentFixture(id: String, title: String) -> Data {
        """
        {
            "id": "\(id)",
            "title": "\(title)",
            "excerpt": null,
            "abilities": {},
            "computed_link_reach": "restricted",
            "computed_link_role": null,
            "created_at": "2026-01-15T10:30:00Z",
            "creator": null,
            "depth": 2,
            "link_role": "reader",
            "link_reach": "restricted",
            "numchild": 0,
            "path": "00010001",
            "updated_at": "2026-01-15T10:30:00Z",
            "user_role": "owner",
            "is_favorite": false
        }
        """.data(using: .utf8)!
    }

    private nonisolated static let contentFixture = """
        {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Q3 Planning", "content": "Hello world",
         "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
        """.data(using: .utf8)!

    private func decodeDocument(id: String, title: String) -> Document {
        try! JSONDecoder.docsAPI.decode(Document.self, from: Self.documentFixture(id: id, title: title))
    }

    // MARK: - Success

    func testOpenLinkedDocumentFetchesTheLinkedDocument() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in
            .init(
                statusCode: 200, headers: [:],
                body: Self.documentFixture(id: "11111111-1111-4111-8111-111111111111", title: "Meeting notes"),
                error: nil)
        }

        let document = await viewModel.openLinkedDocument(linkedID)

        XCTAssertEqual(document?.id, linkedID)
        XCTAssertEqual(document?.title, "Meeting notes")
        XCTAssertEqual(
            MockURLProtocol.lastRequest?.url?.absoluteString,
            "https://docs.example.org/api/v1.0/documents/11111111-1111-4111-8111-111111111111/")
    }

    /// The reported case — a link to a sub-page — is already on screen as a `SubpageRow`,
    /// whose `Document` is exactly what a tap on that row would push. Reusing it makes the
    /// tap instant and is the only way the link can work offline.
    func testOpenLinkedDocumentReusesAListedSubpageWithoutARequest() async {
        let cached = decodeDocument(id: "11111111-1111-4111-8111-111111111111", title: "Cached child")
        childrenCache.save([cached], for: documentID)
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        await viewModel.load()  // seeds subpages from the cache; the content fetch fails
        XCTAssertEqual(viewModel.subpages?.map(\.id), [linkedID])

        let recorder = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            recorder.record(request)
            return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }

        let document = await viewModel.openLinkedDocument(linkedID)

        XCTAssertEqual(document?.title, "Cached child")
        XCTAssertEqual(recorder.methods.count, 0, "a listed sub-page must not cost a round-trip")
        XCTAssertNil(viewModel.errorKey)
    }

    /// The reuse above is a *lookup*, not "are there any sub-pages": a link out of the
    /// sub-tree, with the Subpages section populated, must still miss and fetch.
    func testOpenLinkedDocumentFetchesADocumentThatIsNotASubpage() async {
        let sibling = decodeDocument(id: "33333333-3333-4333-8333-333333333333", title: "Some child")
        childrenCache.save([sibling], for: documentID)
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        await viewModel.load()  // seeds subpages from the cache; the content fetch fails
        XCTAssertEqual(viewModel.subpages?.map(\.title), ["Some child"], "subpages is populated but misses linkedID")

        MockURLProtocol.stubHandler = { _ in
            .init(
                statusCode: 200, headers: [:],
                body: Self.documentFixture(id: "11111111-1111-4111-8111-111111111111", title: "Unrelated doc"),
                error: nil)
        }

        let document = await viewModel.openLinkedDocument(linkedID)

        XCTAssertEqual(document?.title, "Unrelated doc")
        XCTAssertEqual(
            MockURLProtocol.lastRequest?.url?.absoluteString,
            "https://docs.example.org/api/v1.0/documents/11111111-1111-4111-8111-111111111111/")
    }

    // MARK: - Failure

    func testOpenLinkedDocumentSurfacesAFriendlyErrorWhenTheLinkedDocumentIsGone() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 404, headers: [:], body: Data(), error: nil) }

        let document = await viewModel.openLinkedDocument(linkedID)

        XCTAssertNil(document)
        XCTAssertEqual(viewModel.errorKey, .editor_error_open_link)
    }

    func testOpenLinkedDocumentSurfacesAFriendlyErrorWhenAccessIsDenied() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 403, headers: [:], body: Data(), error: nil) }

        let document = await viewModel.openLinkedDocument(linkedID)

        XCTAssertNil(document)
        XCTAssertEqual(viewModel.errorKey, .editor_error_open_link)
    }

    func testOpenLinkedDocumentSurfacesAFriendlyErrorWhenOffline() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        let document = await viewModel.openLinkedDocument(linkedID)

        XCTAssertNil(document)
        XCTAssertEqual(viewModel.errorKey, .editor_error_open_link)
    }

    /// The shared client's `onSessionExpired` hook already raised the re-login sheet;
    /// a competing error banner would only tell the user to "try again" at a document
    /// they cannot reach until they sign back in.
    func testOpenLinkedDocumentStaysSilentWhenTheSessionExpired() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 401, headers: [:], body: Data(), error: nil) }

        let document = await viewModel.openLinkedDocument(linkedID)

        XCTAssertNil(document)
        XCTAssertNil(viewModel.errorKey)
    }

    /// A 404/403 for the *linked* document says nothing about the one being read. Tearing
    /// the open document down over a dead link would discard it — and any unsaved edit.
    func testAFailedLinkLeavesTheOpenDocumentAvailable() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: Self.contentFixture, error: nil)
        }
        await viewModel.load()
        XCTAssertTrue(viewModel.hasLoadedContent)
        let loadedBlocks = viewModel.blocks

        MockURLProtocol.stubHandler = { _ in .init(statusCode: 404, headers: [:], body: Data(), error: nil) }
        _ = await viewModel.openLinkedDocument(linkedID)

        XCTAssertFalse(viewModel.isUnavailable)
        XCTAssertTrue(viewModel.hasLoadedContent)
        XCTAssertEqual(viewModel.blocks.map(\.text), loadedBlocks.map(\.text))
        XCTAssertEqual(viewModel.errorKey, .editor_error_open_link)
    }

    func testASuccessfulLinkClearsAPreviousErrorMessage() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 404, headers: [:], body: Data(), error: nil) }
        _ = await viewModel.openLinkedDocument(linkedID)
        XCTAssertNotNil(viewModel.errorKey)

        MockURLProtocol.stubHandler = { _ in
            .init(
                statusCode: 200, headers: [:],
                body: Self.documentFixture(id: "11111111-1111-4111-8111-111111111111", title: "Meeting notes"),
                error: nil)
        }

        let document = await viewModel.openLinkedDocument(linkedID)

        XCTAssertEqual(document?.title, "Meeting notes")
        XCTAssertNil(viewModel.errorKey)
    }
}
