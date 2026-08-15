import XCTest

@testable import Schrift

// Cookie fixtures use obviously fake values; no test prints cookie values.
@MainActor
final class ReauthenticationViewModelTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private let suiteName = "dev.llun.Schrift.tests.ReauthenticationViewModelTests"
    private let serverURL = URL(string: "https://docs.llun.dev")!
    private let cookiesKeychainKey = "dev.llun.Schrift.sessionCookies"

    override func setUp() {
        super.setUp()
        userDefaults = UserDefaults(suiteName: suiteName)
        userDefaults.removePersistentDomain(forName: suiteName)
        MockURLProtocol.reset()
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeViewModel(
        keychain: FakeKeychainStore = FakeKeychainStore(),
        cookieStorage: FakeCookieStorage = FakeCookieStorage(),
        stub: @escaping @Sendable (URLRequest) -> MockURLProtocol.Stub
    ) throws -> ReauthenticationViewModel {
        MockURLProtocol.stubHandler = stub
        let sessionStore = SessionStore(userDefaults: userDefaults, keychain: keychain, cookieStorage: cookieStorage)
        // Reauthentication starts from a signed-in session whose server-side
        // half has died: sign in, then mark the session expired.
        try sessionStore.signIn(serverURL: serverURL)
        sessionStore.noteSessionExpired()
        return ReauthenticationViewModel(
            serverURL: serverURL,
            sessionStore: sessionStore,
            apiClientFactory: { serverURL in
                DocsAPIClient(
                    baseURL: serverURL.appendingPathComponent("api/v1.0/"),
                    session: MockURLProtocol.makeSession(),
                    cookieProvider: { [] }
                )
            }
        )
    }

    func testHandleLoginCompleteSuccessClearsFlagAndRepersistsCookies() async throws {
        let keychain = FakeKeychainStore()
        let cookieStorage = FakeCookieStorage()
        let viewModel = try makeViewModel(keychain: keychain, cookieStorage: cookieStorage) { _ in
            .init(statusCode: 200, headers: [:], body: "{}".data(using: .utf8)!, error: nil)
        }
        // The re-login web view just synced a fresh cookie into the storage.
        cookieStorage.setCookie(
            HTTPCookie(properties: [
                .domain: "docs.llun.dev", .path: "/", .name: "docs_sessionid", .value: "fake-fresh-session",
            ])!)

        await viewModel.handleLoginComplete()

        XCTAssertNil(viewModel.errorKey)
        XCTAssertFalse(viewModel.sessionStore.needsReauthentication)
        XCTAssertTrue(viewModel.sessionStore.isAuthenticated)
        let data = try XCTUnwrap(try keychain.load(forKey: cookiesKeychainKey))
        let stored = try JSONDecoder().decode([StoredCookie].self, from: data)
        XCTAssertEqual(stored.map(\.name), ["docs_sessionid"])
        XCTAssertEqual(stored.first?.value, "fake-fresh-session")
    }

    func testHandleLoginCompleteFailureShowsErrorAndKeepsFlag() async throws {
        let viewModel = try makeViewModel { _ in .init(statusCode: 401, headers: [:], body: Data(), error: nil) }

        await viewModel.handleLoginComplete()

        XCTAssertEqual(viewModel.errorKey, .reauth_error_sign_in_failed)
        XCTAssertTrue(viewModel.sessionStore.needsReauthentication)
        XCTAssertFalse(viewModel.isConfirming)
    }

    /// The sheet can be answered by a **different** account, and by the time it reports back
    /// that account's cookies are already live in the shared storage — `WebLoginView` syncs
    /// them before it calls anything. `signIn`, which is what forgets the previous account,
    /// runs only if the confirming `/users/me/` succeeds; so a 5xx or a dropped connection on
    /// that one request used to leave B's session running under A's identity, with A's
    /// unsynced documents listed to B and everything B created stamped with A. Nothing
    /// re-raises the sheet afterwards, because B's session is perfectly valid.
    func testAFailedConfirmationStillForgetsTheAccountTheCookiesNoLongerBelongTo() async throws {
        let viewModel = try makeViewModel { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        let signedIn = SignedInUserStore(userDefaults: userDefaults)
        let cache = CurrentUserCacheStore(userDefaults: userDefaults)
        let previousUser = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        signedIn.remember(previousUser)
        cache.remember(CurrentUser(id: previousUser, email: "ada@example.org"))

        await viewModel.handleLoginComplete()

        XCTAssertEqual(viewModel.errorKey, .reauth_error_sign_in_failed)
        XCTAssertNil(signedIn.userID, "nothing local may be listed or replayed under an account we cannot name")
        XCTAssertNil(cache.user, "and the previous account's profile must not be displayed inside the new session")
    }

    /// The same `catch` as the 500 above — `handleLoginComplete` does not branch on the error
    /// kind, so this buys no mutation-resistance the previous test lacks and is kept only
    /// because it is the shape the fix is really about: a dropped connection leaves a *valid*
    /// session behind, so unlike a 401 nothing will ever re-present the sheet to correct the
    /// identity. Read it as documentation of the motivating case, not as extra coverage.
    func testATransportFailureOnTheConfirmationAlsoForgetsTheAccount() async throws {
        let viewModel = try makeViewModel { _ in
            .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.networkConnectionLost))
        }
        let signedIn = SignedInUserStore(userDefaults: userDefaults)
        signedIn.remember(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)

        await viewModel.handleLoginComplete()

        XCTAssertEqual(viewModel.errorKey, .reauth_error_sign_in_failed)
        XCTAssertNil(signedIn.userID)
    }
}
