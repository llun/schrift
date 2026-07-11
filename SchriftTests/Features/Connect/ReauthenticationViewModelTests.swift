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
}
