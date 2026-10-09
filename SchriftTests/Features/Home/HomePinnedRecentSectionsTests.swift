import XCTest

@testable import Schrift

@MainActor
final class HomePinnedRecentSectionsTests: HomeViewModelTestCase {
    /// **The recents feed is fetched unfiltered**, so the server returns pinned documents in
    /// both responses and the same row rendered in both sections. Pinned wins; Recent is what
    /// is left.
    func testAPinnedDocumentIsNotAlsoListedUnderRecent() async {
        let viewModel = makeViewModel()
        let pinnedID = "11111111-1111-4111-8111-111111111111"
        let pinnedBody = Self.paginatedFixture(id: pinnedID, title: "Pinned Doc", isFavorite: true)
        let recentBody = Self.paginatedFixture(
            entries: [
                (id: pinnedID, title: "Pinned Doc", isFavorite: true),
                (id: "22222222-2222-4222-8222-222222222222", title: "Recent Doc", isFavorite: false),
            ])
        MockURLProtocol.stubHandler = { request in
            let path = request.url?.path ?? ""
            return .init(
                statusCode: 200, headers: [:],
                body: path.contains("favorite_list") ? pinnedBody : recentBody, error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.pinnedDocuments.map(\.title), ["Pinned Doc"])
        XCTAssertEqual(viewModel.recentDocuments.map(\.title), ["Recent Doc"])
        XCTAssertEqual(
            viewModel.fetchedRecentDocuments.map(\.title), ["Pinned Doc", "Recent Doc"],
            "the fetched list — and so the cache — still holds the server's own answer")
    }

    /// **Every recent row pinned leaves the Pinned section alone on screen**, which before this
    /// change was unreachable: `recentDocuments.isEmpty` used to imply "no documents". It now
    /// promotes two pre-existing guards to load-bearing — `DocumentListView`'s
    /// `!showsPinnedSection` conjunct, the only thing between this state and a wrong "No
    /// documents yet", and `documentSection`'s own emptiness check, the only thing preventing an
    /// orphan RECENT header.
    func testEveryRecentRowBeingPinnedLeavesOnlyThePinnedSection() async {
        let viewModel = makeViewModel()
        let id = "11111111-1111-4111-8111-111111111111"
        let body = Self.paginatedFixture(id: id, title: "Pinned Doc", isFavorite: true)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }

        await viewModel.load()

        XCTAssertTrue(viewModel.showsPinnedSection, "so the empty state stays suppressed")
        XCTAssertTrue(viewModel.recentDocuments.isEmpty, "and the Recent section draws nothing at all")
        // No `isCurrentListKnown` assertion: `load()` sets `hasKnownFetchedList` on success, and
        // that disjunct alone satisfies it, so it could not fail for anything this change makes
        // reachable — an assertion that cannot fail reads as coverage without being any.
    }

    /// The filter is on **membership of the rendered Pinned section**, never on `isFavorite`.
    /// The two can disagree: `favorite_list/` is paginated, so a favorite beyond its first page
    /// is flagged `true` in the recents feed and simply absent from `pinnedDocuments`. Filtering
    /// on the flag would hide such a document from *both* sections.
    func testAFavoriteRowStillShowsUnderRecentWhenNothingIsPinned() {
        let cache = makeCache()
        let favorite = documentFixture(UUID(uuidString: "44444444-4444-4444-8444-444444444444")!)
        var pinnedFlagOnly = favorite
        pinnedFlagOnly.isFavorite = true
        cache.saveRecentDocuments([pinnedFlagOnly])
        let viewModel = makeViewModel(cache: cache)

        XCTAssertTrue(viewModel.pinnedDocuments.isEmpty, "precondition: nothing in the Pinned section")
        XCTAssertEqual(
            viewModel.recentDocuments.map(\.id), [favorite.id],
            "it renders in no section at all if the flag decides this")
    }

    /// The ordinary cold start, which the test above does not cover: **both** caches populated
    /// and overlapping, since `load()` writes them together. This is the state most launches
    /// begin in, and the one where a document vanishing from Home is visible on first paint.
    func testTheCacheSeededColdStartSplitsTheTwoSections() {
        let cache = makeCache()
        var pinned = documentFixture(UUID(uuidString: "44444444-4444-4444-8444-444444444444")!)
        pinned.isFavorite = true
        let plain = documentFixture(UUID(uuidString: "55555555-5555-4555-8555-555555555555")!)
        cache.savePinnedDocuments([pinned])
        cache.saveRecentDocuments([pinned, plain])

        let viewModel = makeViewModel(cache: cache)

        XCTAssertEqual(viewModel.pinnedDocuments.map(\.id), [pinned.id])
        XCTAssertEqual(viewModel.recentDocuments.map(\.id), [plain.id], "no row is drawn twice on first paint")
    }

    /// The memo behind `recentDocuments` is keyed on the pinned list too, so a pin made on this
    /// device moves the row between sections with no fetch — the same immediacy
    /// `applyFavoriteChange` already gives the Pinned section.
    func testPinningARowMovesItOutOfRecentWithoutAFetch() async {
        let viewModel = makeViewModel()
        let id = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let document = documentFixture(id)
        viewModel.fetchedRecentDocuments = [document]
        XCTAssertEqual(viewModel.recentDocuments.map(\.id), [id], "precondition: under Recent")

        MockURLProtocol.stubHandler = { _ in .init(statusCode: 201, headers: [:], body: Data(), error: nil) }
        await viewModel.toggleFavorite(document)

        XCTAssertEqual(viewModel.pinnedDocuments.map(\.id), [id])
        XCTAssertTrue(viewModel.recentDocuments.isEmpty)
    }

    /// …and unpinning hands it straight back, which is why the recents array keeps carrying
    /// pinned documents rather than the fetch filtering them out server-side.
    ///
    /// **This test also holds the memo's `pinnedIDs` key** — it and
    /// `testAPendingPinSurvivesAWorkOfflineReseed` are the two that fail when the
    /// conjunct is dropped. The read between the two assignments primes the memo while nothing
    /// is pinned, so the pin that follows changes `pinnedDocuments` **without** touching
    /// `fetchedRecentDocuments` — and that conjunct is then the only thing that can invalidate
    /// it. Written the obvious way round, the assertion is inert: `applyFavoriteChange` rewrites
    /// the row's flag through `applyingFavoriteFlag`, so the older `fetched` conjunct
    /// invalidates the memo and `pinnedIDs` never gets a chance to matter.
    func testUnpinningARowHandsItBackToRecentWithoutAFetch() async {
        let viewModel = makeViewModel()
        let id = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        var document = documentFixture(id)
        document.isFavorite = true
        viewModel.fetchedRecentDocuments = [document]
        XCTAssertEqual(viewModel.recentDocuments.map(\.id), [id], "primes the memo while nothing is pinned")
        viewModel.pinnedDocuments = [document]
        XCTAssertTrue(viewModel.recentDocuments.isEmpty, "precondition: under Pinned only")

        MockURLProtocol.stubHandler = { _ in .init(statusCode: 204, headers: [:], body: Data(), error: nil) }
        await viewModel.toggleFavorite(document)

        XCTAssertTrue(viewModel.pinnedDocuments.isEmpty)
        XCTAssertEqual(
            viewModel.recentDocuments.map(\.id), [id],
            "otherwise the row is in no section until the next successful fetch")
    }

    /// Durable intent survives a Work Offline reseed even when no pinned cache exists.
    func testAPendingPinSurvivesAWorkOfflineReseed() async {
        let cache = makeCache()
        let viewModel = makeViewModel(cache: cache, signedInUser: makeSignedInUser())
        let id = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let document = documentFixture(id)
        // The in-memory row a migration leaves behind, with no cache entry of its own.
        viewModel.fetchedRecentDocuments = [document]

        MockURLProtocol.stubHandler = { _ in .init(statusCode: 201, headers: [:], body: Data(), error: nil) }
        await viewModel.toggleFavorite(document)
        XCTAssertTrue(viewModel.recentDocuments.isEmpty, "precondition: under Pinned only")
        XCTAssertTrue(cache.loadPinnedDocuments().isEmpty, "setFavorite never fabricates a pinned cache")

        preferences.set(true, forKey: "schrift.workOffline")
        await viewModel.load()

        XCTAssertEqual(viewModel.pinnedDocuments.map(\.id), [id], "the durable intent supplies the real row")
        XCTAssertTrue(viewModel.recentDocuments.isEmpty, "the row remains in exactly one section")
    }

    /// A document created here is never a favorite, so the filter can never swallow the one row
    /// that exists nowhere else — while the pinned document it sits beside is still deduped.
    ///
    /// The pinned document is in **both** arrays on purpose: that is the shape the server
    /// actually returns, and without it the assertion is inert (a local row is `isFavorite`
    /// false and never in `pinned`, so no mutation of the filter could fail it).
    func testALocallyCreatedRowIsNeverFilteredOut() {
        let user = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let viewModel = makeViewModel(signedInUser: makeSignedInUser(userID: user))
        var pinned = documentFixture(UUID(uuidString: "44444444-4444-4444-8444-444444444444")!)
        pinned.isFavorite = true
        viewModel.pinnedDocuments = [pinned]
        viewModel.fetchedRecentDocuments = [pinned]

        let local = viewModel.saveCoordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)

        XCTAssertEqual(viewModel.recentDocuments.map(\.id), [local.id])
    }
}
