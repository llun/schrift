import XCTest

@testable import Schrift

/// The on-device half of Search: results from the cached lists before (and without) the server.
@MainActor
final class SearchViewModelLocalTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let me = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let someoneElse = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
    private var suite: String!
    private var defaults: UserDefaults!
    private var directory: URL!
    private var availability: OnlineAvailability!
    private var listCache: DocumentCacheStore!
    private var childrenCache: DocumentChildrenCacheStore!
    private var contentCache: DocumentContentCacheStore!
    private var signedIn: SignedInUserStore!

    override func setUp() {
        super.setUp()
        suite = "SearchViewModelLocalTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        availability = OnlineAvailability(userDefaults: defaults)
        listCache = DocumentCacheStore(userDefaults: defaults)
        childrenCache = DocumentChildrenCacheStore(userDefaults: defaults)
        contentCache = DocumentContentCacheStore(directory: directory)
        signedIn = SignedInUserStore(userDefaults: defaults)
        signedIn.remember(me)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeViewModel() -> SearchViewModel {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let viewModel = SearchViewModel(
            client: client, store: RecentSearchesStore(userDefaults: defaults), signedInUser: signedIn,
            availability: availability, listCache: listCache, childrenCache: childrenCache,
            contentCache: contentCache)
        viewModel.locale = Locale(identifier: "en_US")
        return viewModel
    }

    private func document(_ id: Int, title: String, excerpt: String? = nil) -> Document {
        Document(
            id: documentID(id), title: title, excerpt: excerpt, abilities: DocumentAbilities(),
            linkReach: .restricted, linkRole: .reader, isFavorite: false, depth: 1, numchild: 0,
            path: String(format: "%04d", id), createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(1_000 + id)), userRole: nil, creator: nil)
    }

    private func documentID(_ id: Int) -> UUID {
        UUID(uuidString: "00000000-0000-4000-8000-\(String(format: "%012d", id))")!
    }

    private func workOffline(_ value: Bool) {
        defaults.set(value, forKey: "schrift.workOffline")
        availability.preferencesChanged()
    }

    private func serverPage(_ documents: [(id: Int, title: String)]) -> Data {
        let rows = documents.map { row in
            """
            {"id":"\(documentID(row.id).uuidString.lowercased())","title":"\(row.title)","excerpt":null,
             "abilities":{},"computed_link_reach":"restricted","computed_link_role":null,
             "created_at":"2026-01-15T10:30:00Z","creator":null,"depth":1,"link_role":"reader",
             "link_reach":"restricted","numchild":0,"path":"\(String(format: "%04d", row.id))",
             "updated_at":"2026-01-15T10:30:00Z","user_role":"owner","is_favorite":false}
            """
        }
        return Data(
            "{\"count\":\(rows.count),\"next\":null,\"previous\":null,\"results\":[\(rows.joined(separator: ","))]}"
                .utf8)
    }

    private func stubServer(_ documents: [(id: Int, title: String)]) {
        let body = serverPage(documents)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }
    }

    // MARK: - Local results

    func testLocalResultsComeFromTheCachedListsWithoutTheServerAnswering() async {
        listCache.saveRecentDocuments(
            [document(1, title: "Hotel shortlist"), document(2, title: "Roadmap")], fetchedFor: me)
        stubServer([])
        let viewModel = makeViewModel()
        viewModel.query = "hotel"

        await viewModel.search()

        // The server answered with nothing; the device's match stays, labelled as local-only.
        XCTAssertTrue(viewModel.resultSet.server.isEmpty)
        XCTAssertEqual(viewModel.resultSet.localOnly.map(\.title), ["Hotel shortlist"])
        XCTAssertEqual(viewModel.results.map(\.title), ["Hotel shortlist"])
    }

    func testLocalResultsAppearBeforeTheServerAnswersAndStayAfterwards() async {
        listCache.savePinnedDocuments([document(1, title: "Hotel shortlist")], fetchedFor: me)
        let gate = MockURLProtocol.ResponseGate()
        let body = serverPage([(id: 2, title: "Hotel server")])
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: body, error: nil, releasedBy: gate)
        }
        let viewModel = makeViewModel()
        viewModel.query = "hotel"

        let task = Task { await viewModel.search() }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }

        // The request is in flight: the device's rows are already on screen, so the screen shows
        // them instead of a skeleton.
        XCTAssertTrue(viewModel.isSearching)
        XCTAssertEqual(viewModel.resultSet.localOnly.map(\.title), ["Hotel shortlist"])
        XCTAssertFalse(
            searchShowsSkeleton(isSearching: viewModel.isSearching, hasResults: !viewModel.resultSet.isEmpty))

        gate.open()
        await task.value

        XCTAssertEqual(viewModel.resultSet.server.map(\.title), ["Hotel server"])
        XCTAssertEqual(viewModel.resultSet.localOnly.map(\.title), ["Hotel shortlist"])
        XCTAssertFalse(viewModel.isSearching)
    }

    func testADocumentBothFoundIsShownOnceInTheServersPosition() async {
        listCache.saveRecentDocuments(
            [document(1, title: "Hotel one"), document(2, title: "Hotel two"), document(3, title: "Hotel three")],
            fetchedFor: me)
        stubServer([(id: 2, title: "Hotel two (server)"), (id: 1, title: "Hotel one (server)")])
        let viewModel = makeViewModel()
        viewModel.query = "hotel"

        await viewModel.search()

        XCTAssertEqual(viewModel.resultSet.server.map(\.id), [documentID(2), documentID(1)])
        XCTAssertEqual(viewModel.resultSet.localOnly.map(\.id), [documentID(3)])
        XCTAssertEqual(viewModel.results.count, 3)
        XCTAssertEqual(Set(viewModel.results.map(\.id)).count, 3)
        XCTAssertEqual(viewModel.results.first?.title, "Hotel two (server)")
    }

    func testRefiningKeepsTheLocalRowsInsteadOfEmptying() async {
        listCache.saveRecentDocuments(
            [document(1, title: "Hotel shortlist"), document(2, title: "Hotel budget")], fetchedFor: me)
        stubServer([])
        let viewModel = makeViewModel()
        viewModel.query = "hotel"
        await viewModel.search()
        XCTAssertEqual(viewModel.results.count, 2)

        let gate = MockURLProtocol.ResponseGate()
        let body = serverPage([])
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: body, error: nil, releasedBy: gate)
        }
        viewModel.query = "hotel b"
        let task = Task { await viewModel.search() }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }

        XCTAssertEqual(viewModel.results.map(\.title), ["Hotel budget"])
        gate.open()
        await task.value
    }

    func testClearingTheQueryClearsEveryResult() async {
        listCache.saveRecentDocuments([document(1, title: "Hotel")], fetchedFor: me)
        stubServer([(id: 2, title: "Hotel server")])
        let viewModel = makeViewModel()
        viewModel.query = "hotel"
        await viewModel.search()
        XCTAssertFalse(viewModel.results.isEmpty)

        viewModel.query = ""
        await viewModel.search()

        XCTAssertTrue(viewModel.results.isEmpty)
        XCTAssertFalse(viewModel.isSearching)
    }

    // MARK: - Offline

    func testOfflineShowsLocalResultsWithoutAnyRequest() async {
        listCache.saveRecentDocuments(
            [document(1, title: "Hotel shortlist"), document(2, title: "Roadmap")], fetchedFor: me)
        workOffline(true)
        MockURLProtocol.stubHandler = { _ in
            XCTFail("offline search must not hit the network")
            return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }
        let viewModel = makeViewModel()
        viewModel.query = "hotel"

        await viewModel.search()

        XCTAssertEqual(viewModel.results.map(\.title), ["Hotel shortlist"])
        XCTAssertEqual(viewModel.resultSet.localOnly.count, 1)
        XCTAssertFalse(viewModel.isSearching, "no request is coming, so no skeleton")
        XCTAssertNil(viewModel.errorKey)
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testOfflineIgnoresServerRowsRetainedFromEarlier() async {
        listCache.saveRecentDocuments([document(1, title: "Hotel shortlist")], fetchedFor: me)
        let viewModel = makeViewModel()
        viewModel.results = [document(9, title: "Retained server row")]
        viewModel.query = "hotel"
        workOffline(true)

        await viewModel.search()

        XCTAssertEqual(viewModel.results.map(\.title), ["Hotel shortlist"])
    }

    func testOfflineWithNoMatchIsEmptyNotAnError() async {
        listCache.saveRecentDocuments([document(1, title: "Roadmap")], fetchedFor: me)
        workOffline(true)
        let viewModel = makeViewModel()
        viewModel.query = "zebra"

        await viewModel.search()

        XCTAssertTrue(viewModel.results.isEmpty)
        XCTAssertNil(viewModel.errorKey)
        XCTAssertFalse(viewModel.isSearching)
    }

    func testReconnectingAddsTheServersRows() async {
        listCache.saveRecentDocuments([document(1, title: "Hotel shortlist")], fetchedFor: me)
        workOffline(true)
        let viewModel = makeViewModel()
        viewModel.query = "hotel"
        await viewModel.search()
        XCTAssertEqual(viewModel.results.count, 1)

        workOffline(false)
        stubServer([(id: 5, title: "Hotel on the server")])
        await viewModel.search()

        XCTAssertEqual(viewModel.resultSet.server.map(\.title), ["Hotel on the server"])
        XCTAssertEqual(viewModel.resultSet.localOnly.map(\.title), ["Hotel shortlist"])
    }

    func testAFailedServerSearchStillKeepsTheLocalRows() async {
        listCache.saveRecentDocuments([document(1, title: "Hotel shortlist")], fetchedFor: me)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        let viewModel = makeViewModel()
        viewModel.query = "hotel"

        await viewModel.search()

        XCTAssertEqual(viewModel.errorKey, .search_error_search)
        XCTAssertEqual(viewModel.results.map(\.title), ["Hotel shortlist"])
    }

    // MARK: - Account scoping

    func testAnotherAccountsListsNeverAppear() async {
        listCache.saveRecentDocuments([document(1, title: "Hotel secret")], fetchedFor: someoneElse)
        listCache.savePinnedDocuments([document(2, title: "Hotel pinned secret")], fetchedFor: someoneElse)
        listCache.saveSharedWithMeDocuments([document(3, title: "Hotel shared secret")], fetchedFor: someoneElse)
        workOffline(true)
        let viewModel = makeViewModel()
        viewModel.query = "hotel"

        await viewModel.search()

        XCTAssertTrue(viewModel.results.isEmpty)
    }

    func testUnstampedListsNeverAppear() async {
        listCache.saveRecentDocuments([document(1, title: "Hotel unknown owner")])
        listCache.savePinnedDocuments([document(2, title: "Hotel unknown pinned")], fetchedFor: nil)
        workOffline(true)
        let viewModel = makeViewModel()
        viewModel.query = "hotel"

        await viewModel.search()

        XCTAssertTrue(viewModel.results.isEmpty)
    }

    func testNothingAppearsWhenTheSignedInAccountIsUnknown() async {
        listCache.saveRecentDocuments([document(1, title: "Hotel shortlist")], fetchedFor: me)
        signedIn.clear()
        workOffline(true)
        let viewModel = makeViewModel()
        viewModel.query = "hotel"

        await viewModel.search()

        XCTAssertTrue(viewModel.results.isEmpty)
    }

    func testOnlyTheSignedInAccountsListsAreSearchedWhenBothAreCached() async {
        listCache.saveRecentDocuments([document(1, title: "Hotel mine")], fetchedFor: me)
        listCache.savePinnedDocuments([document(2, title: "Hotel theirs")], fetchedFor: someoneElse)
        workOffline(true)
        let viewModel = makeViewModel()
        viewModel.query = "hotel"

        await viewModel.search()

        XCTAssertEqual(viewModel.results.map(\.title), ["Hotel mine"])
    }

    func testSubpagesAreSearchedOnlyUnderPagesThisAccountSees() async {
        listCache.saveRecentDocuments([document(1, title: "Trips")], fetchedFor: me)
        childrenCache.save([document(10, title: "Hotel in Chiang Mai")], for: documentID(1))
        childrenCache.save([document(11, title: "Hotel of a stranger")], for: documentID(77))
        workOffline(true)
        let viewModel = makeViewModel()
        viewModel.query = "hotel"

        await viewModel.search()

        XCTAssertEqual(viewModel.results.map(\.title), ["Hotel in Chiang Mai"])
    }

    // MARK: - Cached text

    func testCachedBodyTextMatchesAndShowsTheMatchingLine() async {
        listCache.saveRecentDocuments([document(1, title: "Meeting notes")], fetchedFor: me)
        contentCache.save(
            CachedDocumentContent(
                documentID: documentID(1), title: "Meeting notes",
                markdown: "# Meeting notes\n\nWe should bump fastlane to 2.241.2 soon", syncedAt: Date()))
        workOffline(true)
        let viewModel = makeViewModel()
        viewModel.query = "fastlane"

        await viewModel.search()

        XCTAssertEqual(viewModel.results.map(\.title), ["Meeting notes"])
        XCTAssertEqual(viewModel.results.first?.excerpt, "We should bump fastlane to 2.241.2 soon")
    }

    func testCachedTextOfAnUnlistedDocumentIsNotSearched() async {
        listCache.saveRecentDocuments([document(1, title: "Meeting notes")], fetchedFor: someoneElse)
        contentCache.save(
            CachedDocumentContent(
                documentID: documentID(1), title: "Meeting notes", markdown: "fastlane secrets", syncedAt: Date()))
        contentCache.save(
            CachedDocumentContent(
                documentID: documentID(2), title: "Orphan", markdown: "fastlane orphan", syncedAt: Date()))
        workOffline(true)
        let viewModel = makeViewModel()
        viewModel.query = "fastlane"

        await viewModel.search()

        XCTAssertTrue(viewModel.results.isEmpty)
    }

    // MARK: - Stale queries

    func testACancelledSearchInstallsNothing() async {
        listCache.saveRecentDocuments([document(1, title: "Hotel shortlist")], fetchedFor: me)
        MockURLProtocol.stubHandler = { _ in
            XCTFail("a cancelled search must not reach the server")
            return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }
        let viewModel = makeViewModel()
        viewModel.query = "hotel"

        let task = Task { await viewModel.search() }
        task.cancel()
        await task.value

        XCTAssertTrue(viewModel.results.isEmpty)
        XCTAssertFalse(viewModel.isSearching)
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testASupersededSearchDoesNotOverwriteTheNewerOnesRows() async {
        listCache.saveRecentDocuments(
            [document(1, title: "Alpha notes"), document(2, title: "Beta notes")], fetchedFor: me)
        stubServer([])
        let viewModel = makeViewModel()
        viewModel.query = "alpha"
        let older = Task { await viewModel.search() }
        await waitUntil { viewModel.isSearching }

        viewModel.query = "beta"
        await viewModel.search()
        await older.value

        XCTAssertEqual(viewModel.results.map(\.title), ["Beta notes"])
    }

    // MARK: - Session index

    func testTheIndexIsReusedWithinASessionAndRebuiltAfterTheQueryIsCleared() async {
        listCache.saveRecentDocuments([document(1, title: "Hotel shortlist")], fetchedFor: me)
        workOffline(true)
        let viewModel = makeViewModel()
        viewModel.query = "hotel"
        await viewModel.search()
        XCTAssertEqual(viewModel.results.count, 1)

        listCache.saveRecentDocuments(
            [document(1, title: "Hotel shortlist"), document(2, title: "Hotel budget")], fetchedFor: me)
        viewModel.query = "hotel "
        await viewModel.search()
        XCTAssertEqual(viewModel.results.count, 1, "a keystroke scans the session's index, not the caches")

        viewModel.query = ""
        await viewModel.search()
        viewModel.query = "hotel"
        await viewModel.search()
        XCTAssertEqual(viewModel.results.count, 2, "a new session reads the caches again")
    }
}
