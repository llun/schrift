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

    func testRefiningOnlineKeepsTheServersRowsUntilItsNewAnswerLands() async {
        listCache.saveRecentDocuments(
            [document(1, title: "Hotel shortlist"), document(2, title: "Hotel budget")], fetchedFor: me)
        stubServer([(id: 3, title: "Hotel server"), (id: 1, title: "Hotel shortlist")])
        let viewModel = makeViewModel()
        viewModel.query = "hotel"
        await viewModel.search()
        XCTAssertEqual(viewModel.resultSet.server.map(\.id), [documentID(3), documentID(1)])
        XCTAssertEqual(viewModel.resultSet.localOnly.map(\.id), [documentID(2)])

        let gate = MockURLProtocol.ResponseGate()
        let body = serverPage([(id: 1, title: "Hotel shortlist")])
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: body, error: nil, releasedBy: gate)
        }
        viewModel.query = "hotel s"
        let task = Task { await viewModel.search() }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }

        // The device has answered "hotel s" and the server is still on "hotel": its section keeps
        // its rows rather than collapsing, and the device's match is shown once, in its place.
        XCTAssertEqual(viewModel.localResultsQuery, "hotel s")
        XCTAssertEqual(viewModel.serverResultsQuery, "hotel")
        XCTAssertEqual(viewModel.resultSet.server.map(\.id), [documentID(3), documentID(1)])
        XCTAssertTrue(viewModel.resultSet.localOnly.isEmpty)
        XCTAssertFalse(
            searchShowsSkeleton(isSearching: viewModel.isSearching, hasResults: !viewModel.resultSet.isEmpty))

        gate.open()
        await task.value

        XCTAssertEqual(viewModel.serverResultsQuery, "hotel s")
        XCTAssertEqual(viewModel.resultSet.server.map(\.id), [documentID(1)])
        XCTAssertTrue(viewModel.resultSet.localOnly.isEmpty)
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

    func testOfflineTheSkeletonCoversTheGapUntilTheDeviceAnswers() async {
        listCache.saveRecentDocuments([document(1, title: "Roadmap")], fetchedFor: me)
        workOffline(true)
        let viewModel = makeViewModel()
        viewModel.query = "zebra"

        let task = Task { await viewModel.search() }
        // Let it start reading the caches. Until the device has answered, the screen draws
        // placeholder rows rather than "No documents found".
        await Task.yield()
        if viewModel.localResultsQuery == nil {
            XCTAssertTrue(
                searchShowsSkeleton(isSearching: viewModel.isSearching, hasResults: !viewModel.resultSet.isEmpty))
        }
        await task.value

        // The device answered with no match: now, and only now, the empty state.
        XCTAssertEqual(viewModel.localResultsQuery, "zebra")
        XCTAssertFalse(viewModel.isSearching)
        XCTAssertTrue(viewModel.resultSet.isEmpty)
        XCTAssertNil(viewModel.errorKey)
    }

    func testOfflineARefinementKeepsThePreviousRowsRatherThanTheSkeleton() async {
        listCache.saveRecentDocuments([document(1, title: "Hotel shortlist")], fetchedFor: me)
        workOffline(true)
        let viewModel = makeViewModel()
        viewModel.query = "hotel"
        await viewModel.search()

        // A refinement typed offline keeps the previous rows on screen (no skeleton) while it scans.
        viewModel.query = "hotel s"
        let refined = Task { await viewModel.search() }
        await Task.yield()
        XCTAssertFalse(
            searchShowsSkeleton(isSearching: viewModel.isSearching, hasResults: !viewModel.resultSet.isEmpty))
        await refined.value
        XCTAssertFalse(viewModel.isSearching)
        XCTAssertEqual(viewModel.results.map(\.title), ["Hotel shortlist"])
    }

    // MARK: - Retiring the server's rows

    func testAFailedRefinementRetiresThePreviousQuerysServerRows() async {
        listCache.saveRecentDocuments([document(1, title: "Hotel shortlist")], fetchedFor: me)
        stubServer([(id: 3, title: "Hotel server")])
        let viewModel = makeViewModel()
        viewModel.query = "hotel"
        await viewModel.search()
        XCTAssertEqual(viewModel.resultSet.server.map(\.title), ["Hotel server"])

        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        viewModel.query = "hotel s"
        await viewModel.search()

        // No answer for "hotel s" is coming, so "hotel"'s rows are not presented as its results.
        XCTAssertEqual(viewModel.errorKey, .search_error_search)
        XCTAssertTrue(viewModel.resultSet.server.isEmpty)
        XCTAssertNil(viewModel.serverResultsQuery)
        XCTAssertEqual(viewModel.resultSet.localOnly.map(\.title), ["Hotel shortlist"])

        // Backing out to "hotel" does not bring them back either: they were dropped, not hidden.
        viewModel.query = "hotel"
        XCTAssertTrue(viewModel.resultSet.server.isEmpty)
    }

    func testAFailureForTheSameQueryKeepsItsServerRows() async {
        stubServer([(id: 3, title: "Hotel server")])
        let viewModel = makeViewModel()
        viewModel.query = "hotel"
        await viewModel.search()

        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        await viewModel.search()

        XCTAssertEqual(viewModel.errorKey, .search_error_search)
        XCTAssertEqual(viewModel.resultSet.server.map(\.title), ["Hotel server"], "they still answer this query")
    }

    func testServerRowsShowOnlyForTheirQueryOrARefinementOfIt() async {
        stubServer([(id: 3, title: "Hotel server")])
        let viewModel = makeViewModel()
        viewModel.query = "hotel"
        await viewModel.search()

        viewModel.query = "hotel s"
        XCTAssertEqual(viewModel.resultSet.server.map(\.title), ["Hotel server"], "typing on keeps them in place")
        viewModel.query = "hote"
        XCTAssertTrue(viewModel.resultSet.server.isEmpty, "a deleted character is another question")
        viewModel.query = "roadmap"
        XCTAssertTrue(viewModel.resultSet.server.isEmpty, "a recent term or a new word is another question")
        viewModel.query = "hotel"
        XCTAssertEqual(viewModel.resultSet.server.map(\.title), ["Hotel server"])
    }

    func testReconnectingDoesNotBringBackAnotherQuerysServerRows() async {
        listCache.saveRecentDocuments([document(1, title: "Banana bread")], fetchedFor: me)
        stubServer([(id: 5, title: "Apple pie")])
        let viewModel = makeViewModel()
        viewModel.query = "apple"
        await viewModel.search()
        XCTAssertEqual(viewModel.resultSet.server.map(\.title), ["Apple pie"])

        workOffline(true)
        viewModel.query = "banana"
        await viewModel.search()
        XCTAssertEqual(viewModel.results.map(\.title), ["Banana bread"])

        workOffline(false)
        let gate = MockURLProtocol.ResponseGate()
        let body = serverPage([(id: 6, title: "Banana split")])
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: body, error: nil, releasedBy: gate)
        }
        let task = Task { await viewModel.search() }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }

        // Back online and the server is still answering "banana": "apple"'s rows stay retired.
        XCTAssertTrue(viewModel.resultSet.server.isEmpty)
        XCTAssertEqual(viewModel.resultSet.localOnly.map(\.title), ["Banana bread"])

        gate.open()
        await task.value
        XCTAssertEqual(viewModel.resultSet.server.map(\.title), ["Banana split"])
        XCTAssertEqual(viewModel.resultSet.localOnly.map(\.title), ["Banana bread"])
    }

    func testAnOnlineErrorDoesNotFollowTheUserOffline() async {
        listCache.saveRecentDocuments([document(1, title: "Hotel shortlist")], fetchedFor: me)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        let viewModel = makeViewModel()
        viewModel.query = "zebra"
        await viewModel.search()
        XCTAssertEqual(viewModel.errorKey, .search_error_search)

        workOffline(true)
        await viewModel.search()
        XCTAssertNil(viewModel.errorKey, "offline, no request failed: no matches is the empty state")
        XCTAssertTrue(viewModel.results.isEmpty)

        viewModel.query = "hotel"
        await viewModel.search()
        XCTAssertNil(viewModel.errorKey)
        XCTAssertEqual(viewModel.results.map(\.title), ["Hotel shortlist"])
    }

    func testANewQueryClearsThePreviousQuerysErrorBeforeTheServerIsAsked() async {
        listCache.saveRecentDocuments([document(1, title: "Hotel shortlist")], fetchedFor: me)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        let viewModel = makeViewModel()
        viewModel.query = "hotel"
        await viewModel.search()
        XCTAssertEqual(viewModel.errorKey, .search_error_search)

        let gate = MockURLProtocol.ResponseGate()
        let body = serverPage([])
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: body, error: nil, releasedBy: gate)
        }
        viewModel.query = "hotel s"
        let task = Task { await viewModel.search() }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }

        XCTAssertNil(viewModel.errorKey)
        gate.open()
        await task.value
    }

    // MARK: - Account scoping

    func testAnAccountSwitchHidesTheRowsFoundForThePreviousAccount() async {
        listCache.saveRecentDocuments([document(1, title: "Meeting notes")], fetchedFor: me)
        contentCache.save(
            CachedDocumentContent(
                documentID: documentID(1), title: "Meeting notes", markdown: "hotel booking secrets",
                syncedAt: Date()))
        stubServer([(id: 2, title: "Hotel server")])
        let viewModel = makeViewModel()
        viewModel.query = "hotel"
        await viewModel.search()
        XCTAssertEqual(viewModel.resultSet.server.map(\.title), ["Hotel server"])
        XCTAssertEqual(viewModel.resultSet.localOnly.map(\.title), ["Meeting notes"])

        // The re-login sheet signs another account in without rebuilding the screen.
        signedIn.remember(someoneElse)

        XCTAssertTrue(viewModel.resultSet.isEmpty, "nothing found for the previous account is shown, before any search")

        // The screen searches again for the new session: only its own answers come back.
        stubServer([(id: 5, title: "Hotel of the new account")])
        await viewModel.search()
        XCTAssertEqual(viewModel.resultSet.server.map(\.title), ["Hotel of the new account"])
        XCTAssertTrue(viewModel.resultSet.localOnly.isEmpty)
    }

    func testAServerAnswerLandingAfterAnAccountSwitchIsDropped() async {
        let gate = MockURLProtocol.ResponseGate()
        let body = serverPage([(id: 2, title: "Hotel server")])
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: body, error: nil, releasedBy: gate)
        }
        let viewModel = makeViewModel()
        viewModel.query = "hotel"
        let task = Task { await viewModel.search() }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }

        signedIn.remember(someoneElse)
        gate.open()
        await task.value

        XCTAssertNil(viewModel.serverResultsQuery, "the previous account's answer is not installed")
        XCTAssertTrue(viewModel.results.isEmpty)
    }

    func testQuickAccessIsHiddenAfterAnAccountSwitch() async {
        stubServer([(id: 2, title: "Pinned of mine")])
        let viewModel = makeViewModel()
        await viewModel.loadQuickAccess()
        XCTAssertEqual(viewModel.quickAccess.map(\.title), ["Pinned of mine"])

        signedIn.remember(someoneElse)

        XCTAssertTrue(viewModel.quickAccess.isEmpty)
    }

    /// The real re-login: the id is cleared, the session's generation bumps, and the id is learned
    /// again from `/users/me/` only later — here while the new session's request is in flight.
    func testAReLoginThroughAnUnknownIdentityShowsTheNewSessionsRows() async {
        listCache.saveRecentDocuments([document(1, title: "Hotel of mine")], fetchedFor: me)
        listCache.savePinnedDocuments([document(2, title: "Hotel of theirs")], fetchedFor: someoneElse)
        stubServer([(id: 3, title: "Hotel server, mine")])
        let viewModel = makeViewModel()
        viewModel.query = "hotel"
        await viewModel.search(signInGeneration: 1)
        XCTAssertEqual(viewModel.resultSet.server.map(\.title), ["Hotel server, mine"])
        XCTAssertEqual(viewModel.resultSet.localOnly.map(\.title), ["Hotel of mine"])

        // The login hands its cookies over: the id is forgotten and a new session begins.
        signedIn.clear()
        XCTAssertTrue(viewModel.resultSet.isEmpty, "the previous account's rows go at once")
        viewModel.beginSession(signInGeneration: 2)

        let gate = MockURLProtocol.ResponseGate()
        let body = serverPage([(id: 4, title: "Hotel server, theirs")])
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: body, error: nil, releasedBy: gate)
        }
        let task = Task { await viewModel.search(signInGeneration: 2) }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        XCTAssertTrue(viewModel.resultSet.isEmpty)
        XCTAssertTrue(
            searchShowsSkeleton(isSearching: viewModel.isSearching, hasResults: !viewModel.resultSet.isEmpty))

        // `/users/me/` answers before the search does.
        signedIn.remember(someoneElse)
        gate.open()
        await task.value

        XCTAssertEqual(
            viewModel.resultSet.server.map(\.title), ["Hotel server, theirs"], "the session's answer is kept")
        XCTAssertTrue(viewModel.resultSet.localOnly.isEmpty, "the device was searched while the id was unknown")

        // The screen searches again once the id is known (`signedInUserID` is in its task id), and
        // now the device's documents of the new account are found too — never the previous one's.
        stubServer([(id: 4, title: "Hotel server, theirs")])
        await viewModel.search(signInGeneration: 2)
        XCTAssertEqual(viewModel.resultSet.server.map(\.title), ["Hotel server, theirs"])
        XCTAssertEqual(viewModel.resultSet.localOnly.map(\.title), ["Hotel of theirs"])
    }

    func testAnAnswerThatLandsBeforeTheIdIsLearnedStaysOnceItIs() async {
        signedIn.clear()
        stubServer([(id: 4, title: "Hotel server")])
        let viewModel = makeViewModel()
        viewModel.query = "hotel"
        await viewModel.search(signInGeneration: 2)
        XCTAssertEqual(viewModel.resultSet.server.map(\.title), ["Hotel server"])

        signedIn.remember(someoneElse)

        XCTAssertEqual(viewModel.resultSet.server.map(\.title), ["Hotel server"])
    }

    func testQuickAccessLoadedWhileTheIdIsUnknownIsKeptOnceItIsLearned() async {
        stubServer([(id: 2, title: "Pinned of mine")])
        let viewModel = makeViewModel()
        await viewModel.loadQuickAccess(signInGeneration: 1)
        XCTAssertEqual(viewModel.quickAccess.map(\.title), ["Pinned of mine"])

        signedIn.clear()
        XCTAssertTrue(viewModel.quickAccess.isEmpty)

        let gate = MockURLProtocol.ResponseGate()
        let body = serverPage([(id: 5, title: "Pinned of theirs")])
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: body, error: nil, releasedBy: gate)
        }
        let task = Task { await viewModel.loadQuickAccess(signInGeneration: 2) }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        signedIn.remember(someoneElse)
        gate.open()
        await task.value

        XCTAssertEqual(viewModel.quickAccess.map(\.title), ["Pinned of theirs"])
    }

    func testTheSameAccountSigningBackInDoesNotShowTheRowsFromBeforeTheReLogin() async {
        stubServer([(id: 3, title: "Hotel server")])
        let viewModel = makeViewModel()
        viewModel.query = "hotel"
        await viewModel.search(signInGeneration: 1)
        await viewModel.loadQuickAccess(signInGeneration: 1)
        XCTAssertFalse(viewModel.resultSet.server.isEmpty)
        XCTAssertFalse(viewModel.quickAccess.isEmpty)

        signedIn.clear()
        signedIn.remember(me)
        viewModel.beginSession(signInGeneration: 2)

        XCTAssertTrue(viewModel.resultSet.server.isEmpty, "the new session asks again")
        XCTAssertTrue(viewModel.quickAccess.isEmpty)
    }

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

    func testTheIndexIsRebuiltWhenSearchAppearsAgain() async {
        listCache.saveRecentDocuments([document(1, title: "Hotel shortlist")], fetchedFor: me)
        workOffline(true)
        let viewModel = makeViewModel()
        viewModel.query = "hotel"
        await viewModel.search()
        XCTAssertEqual(viewModel.results.count, 1)

        // Meanwhile Home cached another document, and the user comes back with the query kept.
        listCache.saveRecentDocuments(
            [document(1, title: "Hotel shortlist"), document(2, title: "Hotel budget")], fetchedFor: me)
        viewModel.invalidateLocalIndex()
        await viewModel.search()

        XCTAssertEqual(viewModel.results.count, 2)
    }

    func testTheIndexIsRebuiltWhenAvailabilityChanges() async {
        listCache.saveRecentDocuments([document(1, title: "Hotel shortlist")], fetchedFor: me)
        workOffline(true)
        let viewModel = makeViewModel()
        viewModel.query = "hotel"
        await viewModel.search()
        XCTAssertEqual(viewModel.results.count, 1)

        listCache.saveRecentDocuments(
            [document(1, title: "Hotel shortlist"), document(2, title: "Hotel budget")], fetchedFor: me)
        workOffline(false)
        stubServer([])
        await viewModel.search()

        XCTAssertEqual(viewModel.resultSet.localOnly.count, 2)
    }

    func testTheIndexIsRebuiltForAnotherAccount() async {
        listCache.saveRecentDocuments([document(1, title: "Hotel mine")], fetchedFor: me)
        listCache.savePinnedDocuments([document(2, title: "Hotel theirs")], fetchedFor: someoneElse)
        workOffline(true)
        let viewModel = makeViewModel()
        viewModel.query = "hotel"
        await viewModel.search()
        XCTAssertEqual(viewModel.results.map(\.title), ["Hotel mine"])

        signedIn.remember(someoneElse)
        await viewModel.search()

        XCTAssertEqual(viewModel.results.map(\.title), ["Hotel theirs"])
    }

    func testASearchTypedDuringTheFirstBuildGetsItsRows() async {
        listCache.saveRecentDocuments(
            [document(1, title: "Hotel shortlist"), document(2, title: "Hotel budget")], fetchedFor: me)
        workOffline(true)
        let viewModel = makeViewModel()
        viewModel.query = "hotel"
        let first = Task { await viewModel.search() }
        // Let it start the build; the next keystroke awaits that build rather than starting another.
        await Task.yield()
        viewModel.query = "hotel b"
        let second = Task { await viewModel.search() }
        await first.value
        await second.value

        XCTAssertEqual(viewModel.results.map(\.title), ["Hotel budget"])
        XCTAssertEqual(viewModel.localResultsQuery, "hotel b")
    }

    func testAnIndexBuiltBeforeTheQueryWasClearedIsNotReused() async {
        listCache.saveRecentDocuments([document(1, title: "Hotel shortlist")], fetchedFor: me)
        workOffline(true)
        let viewModel = makeViewModel()
        viewModel.query = "hotel"
        let first = Task { await viewModel.search() }
        // Let it start its build, then clear the query while that build is in flight.
        await Task.yield()
        viewModel.query = ""
        await viewModel.search()
        await first.value
        listCache.saveRecentDocuments(
            [document(1, title: "Hotel shortlist"), document(2, title: "Hotel budget")], fetchedFor: me)

        viewModel.query = "hotel"
        await viewModel.search()

        XCTAssertEqual(viewModel.results.count, 2, "the new session reads the caches as they are now")
    }
}
