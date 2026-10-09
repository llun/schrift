import XCTest

@testable import Schrift

@MainActor
final class HomeViewModelPinSwipeTests: HomeViewModelTestCase {
    func testPinningARowUpdatesEveryListAndTheCache() async {
        let cache = makeCache()
        let viewModel = makeViewModel(cache: cache)
        let document = documentFixture(UUID(uuidString: "44444444-4444-4444-8444-444444444444")!)
        viewModel.fetchedRecentDocuments = [document]
        viewModel.searchResults = [document]
        cache.saveRecentDocuments([document])
        cache.savePinnedDocuments([])
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 201, headers: [:], body: Data(), error: nil) }

        await viewModel.toggleFavorite(document)

        XCTAssertEqual(viewModel.pinnedDocuments.map(\.id), [document.id])
        XCTAssertTrue(viewModel.fetchedRecentDocuments[0].isFavorite)
        XCTAssertTrue(viewModel.searchResults[0].isFavorite, "or one screen shows the row pinned and not pinned")
        XCTAssertEqual(cache.loadPinnedDocuments().map(\.id), [document.id])
        XCTAssertEqual(cache.loadRecentDocuments()?.first?.isFavorite, true)
    }

    func testUnpinningARowRemovesItFromPinned() async {
        let cache = makeCache()
        let viewModel = makeViewModel(cache: cache)
        var document = documentFixture(UUID(uuidString: "44444444-4444-4444-8444-444444444444")!)
        document.isFavorite = true
        viewModel.pinnedDocuments = [document]
        viewModel.fetchedRecentDocuments = [document]
        cache.savePinnedDocuments([document])
        cache.saveRecentDocuments([document])
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 204, headers: [:], body: Data(), error: nil) }

        await viewModel.toggleFavorite(document)

        XCTAssertTrue(viewModel.pinnedDocuments.isEmpty)
        XCTAssertFalse(viewModel.fetchedRecentDocuments[0].isFavorite)
        XCTAssertTrue(cache.loadPinnedDocuments().isEmpty)
    }

    /// **Never fabricates a list that was never cached.** nil and `[]` are read as different
    /// everywhere — nil is what lets Home show its one first-run placeholder — so a pin must
    /// not turn "never fetched" into "fetched and empty".
    func testPinningNeverFabricatesARecentsCacheThatWasNeverFetched() async {
        let cache = makeCache()
        let viewModel = makeViewModel(cache: cache)
        let document = documentFixture(UUID(uuidString: "44444444-4444-4444-8444-444444444444")!)
        viewModel.fetchedRecentDocuments = [document]
        XCTAssertNil(cache.loadRecentDocuments(), "precondition")
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 201, headers: [:], body: Data(), error: nil) }

        await viewModel.toggleFavorite(document)

        XCTAssertNil(cache.loadRecentDocuments())
    }

    func testAFailedPinReportsAndLeavesEveryListUnchanged() async {
        let viewModel = makeViewModel()
        let document = documentFixture(UUID(uuidString: "44444444-4444-4444-8444-444444444444")!)
        viewModel.fetchedRecentDocuments = [document]
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.toggleFavorite(document)

        XCTAssertTrue(viewModel.pinnedDocuments.isEmpty)
        XCTAssertFalse(viewModel.fetchedRecentDocuments[0].isFavorite)
        XCTAssertEqual(viewModel.errorKey, .options_error_toggle_favorite)
    }

    /// A document the server has never seen has no `…/favorite/` route to POST to, so the
    /// request would 404 and `retryableSaveFailure` rightly refuses to retry it.
    func testPinningIsWithheldForALocallyCreatedRow() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 201, headers: [:], body: Data(), error: nil)
        }
        let user = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let viewModel = makeViewModel(signedInUser: makeSignedInUser(userID: user))
        let local = viewModel.saveCoordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)

        await viewModel.toggleFavorite(local)

        XCTAssertEqual(log.count(ofMethod: "POST"), 0)
        XCTAssertEqual(log.count(ofMethod: "DELETE"), 0)
    }

    /// **A pin must survive a list fetch that predates it** — the same race the deletion path
    /// handles, and with the same answer: filter, never bump `loadGeneration`.
    func testAPinSurvivesAListFetchThatPredatesIt() async {
        let viewModel = makeViewModel()
        let id = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let document = documentFixture(id)
        viewModel.fetchedRecentDocuments = [document]
        let recentBody = Self.paginatedFixture(id: id.uuidString.lowercased(), title: "Doomed", isFavorite: false)
        let empty = Self.emptyFixture
        let log = RequestRecorder()
        let gate = MockURLProtocol.ResponseGate()
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/favorite/") {
                return .init(statusCode: 201, headers: [:], body: Data(), error: nil)
            }
            if url.hasSuffix("/config/") {
                return .init(
                    statusCode: 200, headers: [:], body: Data(#"{"RELEASE_VERSION":"5.6.1"}"#.utf8), error: nil)
            }
            log.record(request)
            // The pre-pin list answers: not a favorite, and absent from `favorite_list/`.
            return .init(
                statusCode: 200, headers: [:],
                body: url.contains("favorite_list") ? empty : recentBody, error: nil, releasedBy: gate)
        }

        let loading = Task { await viewModel.load() }
        // Both stale document responses must be registered as held before pinning.
        // Recorder arrival alone precedes registration; the explicit gate prevents either
        // response from completing during a scheduler pause before the pin finishes.
        await waitUntil {
            log.count(ofMethod: "GET", urlContaining: "/documents/favorite_list/") == 1
                && log.count(ofMethod: "GET", urlContaining: "/documents/?") == 1
                && MockURLProtocol.deferredDeliveryCount == 2
        }
        await viewModel.toggleFavorite(document)
        gate.open()
        await loading.value

        XCTAssertEqual(
            viewModel.pinnedDocuments.map(\.id), [id],
            "the stale fetch must not undo a pin made after it was issued")
        XCTAssertEqual(viewModel.fetchedRecentDocuments.first?.isFavorite, true)
        XCTAssertFalse(viewModel.isLoading, "and the load still finished — filter, never cancel")
    }

    /// **The difference from `deletedSinceLoad`, which is never cleared.** An override kept
    /// past the point the server agrees with it would veto the *next* change made from
    /// another client for the life of the process.
    func testTheOverrideRetiresOnceTheServerAgreesSoALaterUnpinElsewhereWins() async {
        let viewModel = makeViewModel()
        let id = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let document = documentFixture(id)
        viewModel.fetchedRecentDocuments = [document]

        MockURLProtocol.stubHandler = { _ in .init(statusCode: 201, headers: [:], body: Data(), error: nil) }
        await viewModel.toggleFavorite(document)
        XCTAssertEqual(viewModel.pinnedDocuments.map(\.id), [id], "precondition: pinned here")

        // A fetch that agrees — the server now reports it as a favorite. This retires the override.
        let pinnedBody = Self.paginatedFixture(id: id.uuidString.lowercased(), title: "Doomed", isFavorite: true)
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            return .init(
                statusCode: 200, headers: [:],
                body: url.contains("favorite_list") ? pinnedBody : pinnedBody, error: nil)
        }
        await viewModel.load()
        XCTAssertEqual(viewModel.pinnedDocuments.map(\.id), [id])

        // Now someone unpins it on the web. With the override retired, the server wins.
        let unpinnedBody = Self.paginatedFixture(id: id.uuidString.lowercased(), title: "Doomed", isFavorite: false)
        let empty = Self.emptyFixture
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            return .init(
                statusCode: 200, headers: [:],
                body: url.contains("favorite_list") ? empty : unpinnedBody, error: nil)
        }
        await viewModel.load()

        XCTAssertTrue(
            viewModel.pinnedDocuments.isEmpty,
            "a stale override would re-pin it forever, vetoing every later change from the web")
        XCTAssertEqual(viewModel.fetchedRecentDocuments.first?.isFavorite, false)
    }

    /// **The failure `testPinningARowUpdatesEveryListAndTheCache` names in its own message,
    /// from the other direction.** A pin made while a query is active has to reach the inline
    /// results too, or the same document reads pinned in Recents and unpinned in Results on
    /// one screen. Covered here because the overlay is applied in `search()`, which that test
    /// never calls.
    func testAPinReachesResultsOfASearchRunAfterIt() async {
        let viewModel = makeViewModel()
        let id = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let document = documentFixture(id)
        viewModel.fetchedRecentDocuments = [document]
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 201, headers: [:], body: Data(), error: nil) }
        await viewModel.toggleFavorite(document)

        // The search endpoint still reports the pre-pin state.
        let body = Self.paginatedFixture(id: id.uuidString.lowercased(), title: "Doomed", isFavorite: false)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }
        viewModel.searchQuery = "doomed"
        await viewModel.search()

        XCTAssertEqual(
            viewModel.searchResults.first?.isFavorite, true,
            "the row would read pinned in Recents and unpinned in Results on the same screen")
    }
}
