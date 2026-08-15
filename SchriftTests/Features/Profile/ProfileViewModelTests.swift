import XCTest

@testable import Schrift

@MainActor
final class ProfileViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!

    private var signedInSuiteNames: [String] = []

    override func tearDown() {
        MockURLProtocol.reset()
        for name in signedInSuiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        signedInSuiteNames.removeAll()
        super.tearDown()
    }

    /// Isolated defaults for the two on-disk stores the screen writes. `load()` writes the
    /// fetched user's id and profile through, and the production default is
    /// `UserDefaults.standard` — where they would persist on the simulator and hand *other*
    /// suites a signed-in account they never set up, silently enabling the offline-create
    /// fallbacks in tests written before those existed.
    private func makeIsolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: makeIsolatedSuiteName())!
    }

    /// The name as well as the store, for the one test that has to reach these defaults from
    /// inside a `@Sendable` stub handler.
    private func makeIsolatedSuiteName() -> String {
        let suiteName = "ProfileViewModelTests.\(UUID().uuidString)"
        signedInSuiteNames.append(suiteName)
        return suiteName
    }

    private func makeViewModel(defaults: UserDefaults? = nil) -> ProfileViewModel {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let defaults = defaults ?? makeIsolatedDefaults()
        return ProfileViewModel(
            client: client,
            signedInUser: SignedInUserStore(userDefaults: defaults),
            cachedUser: CurrentUserCacheStore(userDefaults: defaults))
    }

    private static let adaID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    private nonisolated static let userFixture: Data = """
        {
            "id": "11111111-1111-4111-8111-111111111111",
            "email": "ada@example.org",
            "full_name": "Ada Lovelace",
            "short_name": "Ada",
            "language": "en-us"
        }
        """.data(using: .utf8)!

    func testLoadPopulatesUser() async {
        let defaults = makeIsolatedDefaults()
        let viewModel = makeViewModel(defaults: defaults)
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: Self.userFixture, error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.user?.email, "ada@example.org")
        XCTAssertEqual(viewModel.user?.displayName, "Ada Lovelace")
        XCTAssertEqual(viewModel.user?.languageLabel, "English")
        XCTAssertFalse(viewModel.isLoading)
        // The other write-through, and the direction nothing else pins: round 3 moved this
        // line to sit before the second await, and only its nil case was covered.
        XCTAssertEqual(SignedInUserStore(userDefaults: defaults).userID, Self.adaID)
    }

    func testLoadTolerates500WithoutThrowing() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }

        await viewModel.load()

        XCTAssertNil(viewModel.user)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testDisplayNameFallsBackToEmail() {
        let user = CurrentUser(email: "only@example.org")
        XCTAssertEqual(user.displayName, "only@example.org")
    }

    func testLanguageLabelUsesRawCodeWhenUnknown() {
        let user = CurrentUser(language: "de")
        XCTAssertEqual(user.languageLabel, "de")
    }

    func testLoadSetsServerVersionFromConfig() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { request in
            if request.url!.absoluteString.contains("/config/") {
                return .init(
                    statusCode: 200, headers: [:], body: #"{"RELEASE_VERSION":"5.4.1"}"#.data(using: .utf8)!,
                    error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: Self.userFixture, error: nil)
        }

        await viewModel.load()

        await waitUntil { viewModel.serverVersion == "5.4.1" }
        XCTAssertEqual(viewModel.user?.email, "ada@example.org")
    }

    // MARK: - Offline

    /// The screen renders `user` in its `body`, and `.task` only runs after the first frame —
    /// so a fetch, even a fast one, is too late to be the *only* source. Seeding in `init` is
    /// what makes a cold offline launch show the account instead of the "—" placeholder.
    func testShowsTheCachedUserBeforeAnyFetch() {
        let defaults = makeIsolatedDefaults()
        CurrentUserCacheStore(userDefaults: defaults).remember(
            CurrentUser(id: Self.adaID, email: "ada@example.org", fullName: "Ada Lovelace"))

        let viewModel = makeViewModel(defaults: defaults)

        XCTAssertEqual(viewModel.user?.email, "ada@example.org")
        XCTAssertEqual(viewModel.user?.displayName, "Ada Lovelace")
    }

    /// Offline is the case this whole cache exists for, and it arrives as a failed fetch.
    /// Assigning the fetch's `nil` over a good cached value would blank the row the moment
    /// the screen appeared — the visible bug, one frame later.
    func testAFailedFetchKeepsTheCachedUser() async {
        let defaults = makeIsolatedDefaults()
        CurrentUserCacheStore(userDefaults: defaults).remember(
            CurrentUser(id: Self.adaID, email: "ada@example.org", fullName: "Ada Lovelace"))
        let viewModel = makeViewModel(defaults: defaults)
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.user?.email, "ada@example.org")
        XCTAssertEqual(
            CurrentUserCacheStore(userDefaults: defaults).user?.email, "ada@example.org",
            "and the cache was not emptied either")
    }

    func testASuccessfulFetchWritesTheUserThroughToTheCache() async {
        let defaults = makeIsolatedDefaults()
        let viewModel = makeViewModel(defaults: defaults)
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: Self.userFixture, error: nil)
        }

        await viewModel.load()

        let cached = CurrentUserCacheStore(userDefaults: defaults).user
        XCTAssertEqual(cached?.email, "ada@example.org")
        XCTAssertEqual(cached?.fullName, "Ada Lovelace")
        XCTAssertEqual(cached?.language, "en-us")
    }

    /// The direction the "keep the cached copy" rule must not swallow: a rename made on the web
    /// still has to reach the screen *and* the disk. Without a stale starting value, an
    /// over-correction like `if user == nil { user = freshUser }` passes every other test here.
    func testASuccessfulFetchReplacesAStaleCachedProfile() async {
        let defaults = makeIsolatedDefaults()
        CurrentUserCacheStore(userDefaults: defaults).remember(
            CurrentUser(id: Self.adaID, email: "ada@old.example.org", fullName: "Ada Byron"))
        let viewModel = makeViewModel(defaults: defaults)
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: Self.userFixture, error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.user?.fullName, "Ada Lovelace")
        XCTAssertEqual(CurrentUserCacheStore(userDefaults: defaults).user?.fullName, "Ada Lovelace")
    }

    /// This view model is `@State` in `MainTabView`, which is **not** rebuilt across a
    /// re-login — the sheet is presented over it while `isAuthenticated` stays true — so its
    /// in-memory user can belong to the account that just went away. Re-reading the store
    /// (which `SessionStore.signIn` clears) instead of keeping that copy is what stops one
    /// account's email being displayed inside another's session when the fetch fails.
    func testAFailedFetchDropsAProfileTheSessionHasForgotten() async {
        let defaults = makeIsolatedDefaults()
        let cache = CurrentUserCacheStore(userDefaults: defaults)
        cache.remember(CurrentUser(id: Self.adaID, email: "ada@example.org"))
        let viewModel = makeViewModel(defaults: defaults)
        XCTAssertNotNil(viewModel.user, "precondition: the previous account is on screen")
        // Re-authenticated as somebody else: `SessionStore.signIn` cleared the store, and the
        // refresh that would name the new account has not landed (or failed).
        cache.clear()
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        await viewModel.load()

        XCTAssertNil(viewModel.user)
    }

    /// The launch order this has to survive: `MainTabView.init` builds this view model before
    /// `RootView`'s task runs the `/users/me/` that first fills the cache. Seeding once and
    /// never looking again would leave Profile empty for the whole session if the network died
    /// in between — the original bug, reached by a different route.
    ///
    /// The cache is filled from **inside the stub**, i.e. while `load()` is suspended on its
    /// own fetch, because that is the only window the re-read after the fetch still covers:
    /// anything cached *before* `load()` is picked up by the pre-fetch seed instead, and a
    /// test written that way keeps passing with the post-fetch re-read deleted.
    func testAFailedFetchPicksUpAProfileCachedWhileItWasInFlight() async {
        let suiteName = makeIsolatedSuiteName()
        let defaults = UserDefaults(suiteName: suiteName)!
        let viewModel = makeViewModel(defaults: defaults)
        XCTAssertNil(viewModel.user, "precondition: nothing cached when the screen was built")
        MockURLProtocol.stubHandler = { _ in
            // What `HomeViewModel.refreshSignedInUser` does at launch, racing this very load.
            CurrentUserCacheStore(userDefaults: UserDefaults(suiteName: suiteName)!).remember(
                CurrentUser(
                    id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, email: "ada@example.org"))
            return .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.user?.email, "ada@example.org")
    }

    /// The row must stop naming the previous account the moment the session changes, not when
    /// the reload settles — that is a whole round trip, or a ~60s timeout if connectivity died
    /// right after the re-login, spent displaying an account that is gone (and offering its
    /// detail screen). So `load()` re-seeds from the store *before* it fetches.
    func testLoadDropsAForgottenAccountImmediatelyRatherThanWhenTheFetchSettles() async {
        let defaults = makeIsolatedDefaults()
        let cache = CurrentUserCacheStore(userDefaults: defaults)
        cache.remember(CurrentUser(id: Self.adaID, email: "ada@example.org"))
        let viewModel = makeViewModel(defaults: defaults)
        XCTAssertNotNil(viewModel.user, "precondition")
        // What `SessionStore.signIn` did while the sheet was up.
        cache.clear()
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: Self.userFixture, error: nil, delay: 0.2)
        }

        let load = Task { await viewModel.load() }

        // Before the response can arrive: the re-seed runs ahead of the first suspension.
        await waitUntil { viewModel.user == nil }
        await load.value
        XCTAssertEqual(viewModel.user?.email, "ada@example.org", "and the reload then names the new session")
    }

    /// A `200` whose body carries no account detail is as uninformative as a failed fetch —
    /// every field is `decodeIfPresent`, so `{}` is a valid `CurrentUser` — and must not
    /// replace a good profile on screen or on disk.
    func testAnEmptyUserPayloadDoesNotReplaceAGoodProfile() async {
        let defaults = makeIsolatedDefaults()
        CurrentUserCacheStore(userDefaults: defaults).remember(
            CurrentUser(id: Self.adaID, email: "ada@example.org"))
        let viewModel = makeViewModel(defaults: defaults)
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: Data("{}".utf8), error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.user?.email, "ada@example.org")
        XCTAssertEqual(CurrentUserCacheStore(userDefaults: defaults).user?.email, "ada@example.org")
    }

    /// `SignedInUserStore` gates what may be *listed and sent* for offline-created documents,
    /// and its contract is that only a live `/users/me/` writes it. A cached profile is a
    /// display convenience and no evidence about the session, so it must not stand in for one.
    func testACachedUserIsNotRememberedAsAFreshlyFetchedAccount() async {
        let defaults = makeIsolatedDefaults()
        CurrentUserCacheStore(userDefaults: defaults).remember(
            CurrentUser(id: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!, email: "ada@example.org"))
        let viewModel = makeViewModel(defaults: defaults)
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        await viewModel.load()

        XCTAssertNil(SignedInUserStore(userDefaults: defaults).userID)
    }

    func testLoadToleratesConfigFailureWhileStillLoadingUser() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { request in
            if request.url!.absoluteString.contains("/config/") {
                return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: Self.userFixture, error: nil)
        }

        await viewModel.load()

        XCTAssertNil(viewModel.serverVersion)
        XCTAssertEqual(viewModel.user?.email, "ada@example.org")
    }
}
