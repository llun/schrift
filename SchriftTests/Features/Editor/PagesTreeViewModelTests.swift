import XCTest

@testable import Schrift

/// The drawer's loading rules. The ones that matter are the destructive ones:
/// the children cache it writes is shared with the editor's own Subpages list,
/// so a level this view model invents or truncates outlives the drawer.
@MainActor
final class PagesTreeViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let rootID = UUID(uuidString: "1A1A1A1A-1A1A-4A1A-8A1A-1A1A1A1A1A1A")!
    private let childID = UUID(uuidString: "2B2B2B2B-2B2B-4B2B-8B2B-2B2B2B2B2B2B")!
    private let createdID = UUID(uuidString: "4D4D4D4D-4D4D-4D4D-8D4D-4D4D4D4D4D4D")!

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PagesTreeViewModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        MockURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeViewModel() -> (PagesTreeViewModel, DocumentChildrenCacheStore) {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let cache = DocumentChildrenCacheStore(userDefaults: defaults)
        return (PagesTreeViewModel(rootID: rootID, client: client, cache: cache, userDefaults: defaults), cache)
    }

    private func document(_ id: UUID, title: String, numchild: Int = 0) -> Document {
        Document(
            id: id, title: title, excerpt: nil, abilities: DocumentAbilities(),
            linkReach: .restricted, linkRole: .reader, isFavorite: false,
            depth: 1, numchild: numchild, path: "0001",
            createdAt: Date(), updatedAt: Date(), userRole: nil, creator: nil)
    }

    nonisolated private static func documentFixture(id: UUID, title: String, numchild: Int = 0) -> String {
        """
        {
            "id": "\(id.uuidString.lowercased())",
            "title": "\(title)",
            "excerpt": null,
            "abilities": {},
            "computed_link_reach": "restricted",
            "computed_link_role": null,
            "created_at": "2026-01-15T10:30:00Z",
            "creator": null,
            "depth": 1,
            "link_role": "reader",
            "link_reach": "restricted",
            "numchild": \(numchild),
            "path": "0001",
            "updated_at": "2026-01-15T10:30:00Z",
            "user_role": "owner"
        }
        """
    }

    nonisolated private static func listFixture(_ documents: [(UUID, String)]) -> Data {
        let results = documents.map { documentFixture(id: $0.0, title: $0.1) }.joined(separator: ",")
        return Data(
            """
            {"count": \(documents.count), "next": null, "previous": null, "results": [\(results)]}
            """.utf8)
    }

    private func isChildrenRequest(_ request: URLRequest, of parent: UUID) -> Bool {
        request.url?.path.contains(parent.uuidString.lowercased()) == true
    }

    // MARK: - Offline

    /// "Work offline" means never touch the network, not "try anyway and fall
    /// back on the cache" — the same contract the document lists honour.
    func testWorkOfflineServesTheCacheAndIssuesNoRequest() async {
        defaults.set(true, forKey: "schrift.workOffline")
        let (viewModel, cache) = makeViewModel()
        cache.save([document(childID, title: "Cached page")], for: rootID)
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 200, headers: [:], body: Self.listFixture([]), error: nil)
        }

        await viewModel.loadRoot()

        XCTAssertEqual(viewModel.rows.map(\.document.id), [childID], "the cached level still renders")
        XCTAssertEqual(log.methods.count, 0, "no request may be issued while working offline")
    }

    func testAFailedFetchKeepsTheCachedLevelAndStaysSilent() async {
        let (viewModel, cache) = makeViewModel()
        cache.save([document(childID, title: "Cached page")], for: rootID)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.loadRoot()

        XCTAssertEqual(viewModel.rows.map(\.document.id), [childID])
        XCTAssertNil(viewModel.errorKey, "a cached level to fall back on is not an error the user must be shown")
    }

    // MARK: - Load failures

    /// Left expanded, a level that failed to load renders as a node with no
    /// children — indistinguishable from a leaf, and with no way to retry.
    func testAFailedFetchWithNoCacheCollapsesTheNodeAndReportsIt() async {
        let (viewModel, cache) = makeViewModel()
        let parent = document(childID, title: "Parent", numchild: 2)
        cache.save([parent], for: rootID)
        MockURLProtocol.stubHandler = { [childID] request in
            request.url?.path.contains(childID.uuidString.lowercased()) == true
                ? .init(statusCode: 500, headers: [:], body: Data(), error: nil)
                : .init(statusCode: 200, headers: [:], body: Self.listFixture([]), error: nil)
        }

        await viewModel.toggle(parent)

        XCTAssertFalse(viewModel.expanded.contains(childID), "it collapses, so its arrow — the retry — comes back")
        XCTAssertEqual(viewModel.errorKey, .pages_error_load)
    }

    /// One shared error flag would let a success anywhere in the tree wipe a
    /// message about a level the user is still looking at.
    func testASuccessElsewhereDoesNotClearAnotherLevelsError() async {
        let (viewModel, cache) = makeViewModel()
        let parent = document(childID, title: "Broken", numchild: 1)
        cache.save([parent], for: rootID)
        MockURLProtocol.stubHandler = { [childID] request in
            if request.url?.path.contains(childID.uuidString.lowercased()) == true {
                return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
            }
            return .init(
                statusCode: 200, headers: [:],
                body: Self.listFixture([(childID, "Broken")]), error: nil)
        }
        await viewModel.toggle(parent)
        XCTAssertEqual(viewModel.errorKey, .pages_error_load)

        // A different level now loads cleanly.
        await viewModel.loadRoot()

        XCTAssertEqual(viewModel.errorKey, .pages_error_load, "the broken level is still broken")
    }

    // MARK: - Creating a page

    /// The cache is shared with the editor's Subpages list, so persisting a
    /// one-item level for a parent whose real children were never fetched hides
    /// them — in both places — until something else refetches.
    func testCreatingAPageDoesNotFabricateALevelThatWasNeverLoaded() async {
        let (viewModel, cache) = makeViewModel()
        MockURLProtocol.stubHandler = { [createdID] request in
            request.httpMethod == "POST"
                ? .init(
                    statusCode: 201, headers: [:],
                    body: Data(Self.documentFixture(id: createdID, title: "Untitled subpage").utf8), error: nil)
                : .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }

        let result = await viewModel.addPage(under: rootID)

        XCTAssertEqual(result?.id, createdID, "the page is still created, and handed back to navigate to")
        XCTAssertTrue(viewModel.rows.isEmpty, "an unknown level stays unknown rather than showing one invented row")
        XCTAssertNil(cache.children(for: rootID), "and nothing is written to the shared cache")
    }

    func testCreatingAPageAppendsToALevelThatIsKnown() async {
        let (viewModel, cache) = makeViewModel()
        MockURLProtocol.stubHandler = { [childID, createdID] request in
            request.httpMethod == "POST"
                ? .init(
                    statusCode: 201, headers: [:],
                    body: Data(Self.documentFixture(id: createdID, title: "Untitled subpage").utf8), error: nil)
                : .init(
                    statusCode: 200, headers: [:],
                    body: Self.listFixture([(childID, "Existing")]), error: nil)
        }
        await viewModel.loadRoot()

        _ = await viewModel.addPage(under: rootID)

        XCTAssertEqual(viewModel.rows.map(\.document.id), [childID, createdID])
        XCTAssertEqual(cache.children(for: rootID)?.map(\.id), [childID, createdID])
    }

    /// A list fetch that started before the create carries a pre-create
    /// snapshot; letting it land would drop the page the user just made.
    func testAnInFlightFetchCannotDropAJustCreatedPage() async {
        let (viewModel, cache) = makeViewModel()
        cache.save([document(childID, title: "Existing")], for: rootID)
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { [childID, createdID] request in
            log.record(request)
            if request.httpMethod == "POST" {
                return .init(
                    statusCode: 201, headers: [:],
                    body: Data(Self.documentFixture(id: createdID, title: "Untitled subpage").utf8), error: nil)
            }
            // The pre-create snapshot, held open so the create resolves first.
            return .init(
                statusCode: 200, headers: [:], body: Self.listFixture([(childID, "Existing")]), error: nil,
                delay: 0.3)
        }

        async let slowLoad: Void = viewModel.loadRoot()
        await waitUntil { log.count(ofMethod: "GET") == 1 }
        _ = await viewModel.addPage(under: rootID)
        await slowLoad

        XCTAssertEqual(
            viewModel.rows.map(\.document.id), [childID, createdID],
            "the stale snapshot must not overwrite the level the create added to")
    }

    // MARK: - Duplicate work

    func testASecondExpandWhileOneIsInFlightDoesNotRefetch() async {
        let (viewModel, _) = makeViewModel()
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { [childID] request in
            log.record(request)
            return .init(
                statusCode: 200, headers: [:], body: Self.listFixture([(childID, "Child")]), error: nil,
                delay: 0.2)
        }

        async let first: Void = viewModel.loadRoot()
        await waitUntil { viewModel.loading.contains(self.rootID) }
        await viewModel.loadRoot()
        await first

        XCTAssertEqual(log.methods.count, 1, "the in-flight guard collapses the second call")
    }
}
