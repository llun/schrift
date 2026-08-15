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
        let suiteName = "ProfileViewModelTests.\(UUID().uuidString)"
        signedInSuiteNames.append(suiteName)
        return UserDefaults(suiteName: suiteName)!
    }

    private func makeViewModel(defaults: UserDefaults? = nil) -> ProfileViewModel {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let defaults = defaults ?? makeIsolatedDefaults()
        return ProfileViewModel(
            client: client,
            signedInUser: SignedInUserStore(userDefaults: defaults),
            cachedUser: CurrentUserCacheStore(userDefaults: defaults))
    }

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
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: Self.userFixture, error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.user?.email, "ada@example.org")
        XCTAssertEqual(viewModel.user?.displayName, "Ada Lovelace")
        XCTAssertEqual(viewModel.user?.languageLabel, "English")
        XCTAssertFalse(viewModel.isLoading)
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
            CurrentUser(id: UUID(), email: "ada@example.org", fullName: "Ada Lovelace"))

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
            CurrentUser(id: UUID(), email: "ada@example.org", fullName: "Ada Lovelace"))
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
