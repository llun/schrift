import XCTest

@testable import Schrift

/// A 404 is not proof of a deletion. Older docs backends have no `formatted-content/` route
/// at all, and every 404 maps to `.notFound`, so a whole server's documents used to render as
/// "This document is no longer available." with nothing to say otherwise.
@MainActor
final class EditorUnavailableDetailTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!
    private var cacheDirectory: URL!
    private var suiteName: String!
    private var userDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorUnavailableDetailTests.\(UUID().uuidString)", isDirectory: true)
        suiteName = "EditorUnavailableDetailTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: cacheDirectory)
        // The save coordinator writes drafts into this suite; without this they persist to
        // disk across runs.
        userDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeViewModel(diagnostics: APIDiagnosticsLog?) -> EditorViewModel {
        let client = DocsAPIClient(
            baseURL: baseURL,
            session: MockURLProtocol.makeSession(),
            cookieProvider: { [] },
            onRequestFailure: { failure in diagnostics?.record(failure) }
        )
        let draftStore = PendingDraftStore(userDefaults: userDefaults)
        let contentCache = DocumentContentCacheStore(directory: cacheDirectory)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: draftStore, contentCache: contentCache, backgroundTasks: .noop)
        return EditorViewModel(
            client: client, documentID: documentID, title: "Doc", saveCoordinator: coordinator,
            contentCache: contentCache,
            childrenCache: DocumentChildrenCacheStore(userDefaults: userDefaults),
            diagnostics: diagnostics)
    }

    func testUnavailableDocumentQuotesTheServersOwnResponse() async {
        let diagnostics = APIDiagnosticsLog()
        let viewModel = makeViewModel(diagnostics: diagnostics)
        // Both routes 404 — a genuinely gone document, or a proxy swallowing the path.
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 404, headers: [:], body: Data(#"{"detail":"Not found."}"#.utf8), error: nil)
        }

        await viewModel.load()

        XCTAssertTrue(viewModel.isUnavailable)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.errorDetail, "HTTP 404: Not found.")
    }

    /// Offline there is no HTTP response to quote, and the marker must keep an older
    /// failure's detail from being attributed to this one.
    func testTransientFailureOffersNoDetail() async {
        let diagnostics = APIDiagnosticsLog()
        diagnostics.record(RequestFailure(method: "GET", path: "documents/", statusCode: 403, body: Data()))
        let viewModel = makeViewModel(diagnostics: diagnostics)
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        await viewModel.load()

        XCTAssertFalse(viewModel.isUnavailable)
        XCTAssertNil(viewModel.errorDetail)
    }

    /// A missing route (or a proxy serving HTML for a path it swallowed) is no evidence about
    /// any document. It must not tear the editor down or purge the cache the way a real 404
    /// does — the screen stays, with a transient message and its pull-to-refresh.
    func testAnHTML404DoesNotDeclareTheDocumentDeleted() async {
        let viewModel = makeViewModel(diagnostics: APIDiagnosticsLog())
        MockURLProtocol.stubHandler = { request in
            // Route absent for the document, present for the confirmation probe -> the HTML
            // came from in front of the server.
            if request.url?.path.contains("00000000") == true {
                return .init(
                    statusCode: 404, headers: ["Content-Type": "application/json"],
                    body: Data(#"{"detail":"Not found."}"#.utf8), error: nil)
            }
            return .init(
                statusCode: 404, headers: ["Content-Type": "text/html"],
                body: Data("<html>404</html>".utf8), error: nil)
        }

        await viewModel.load()

        XCTAssertFalse(viewModel.isUnavailable, "a route 404 must not read as a deletion")
        XCTAssertNotNil(viewModel.errorMessage)
    }

    /// The detail must quote the document's own response, not the confirmation probe's — the
    /// probe asks about an id the user never opened.
    func testTheDetailQuotesTheDocumentsResponseNotTheProbes() async {
        let viewModel = makeViewModel(diagnostics: APIDiagnosticsLog())
        MockURLProtocol.stubHandler = { request in
            if request.url?.path.contains("00000000") == true {
                return .init(
                    statusCode: 404, headers: ["Content-Type": "application/json"],
                    body: Data(#"{"detail":"probe: wrong reason"}"#.utf8), error: nil)
            }
            return .init(
                statusCode: 404, headers: ["Content-Type": "text/html"],
                body: Data("the document's own reason".utf8), error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.errorDetail, "HTTP 404: the document's own reason")
    }
}
