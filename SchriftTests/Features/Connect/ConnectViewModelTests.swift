import XCTest

@testable import Schrift

// File-scope so the `@Sendable` stub handlers can read them off the main actor.
private let identityStub = MockURLProtocol.Stub(
    statusCode: 200, headers: [:],
    body: Data(#"{"id":"11111111-1111-4111-8111-111111111111"}"#.utf8), error: nil)
private let docs6ConfigStub = MockURLProtocol.Stub(
    statusCode: 200, headers: [:], body: Data(#"{"RELEASE_VERSION":"6.0.0"}"#.utf8), error: nil)
/// A Docs 6 config that also names its yhub org, so the remembered config can be checked for
/// the collaboration org the native editor's offline create needs.
private let docs6ConfigWithOrgStub = MockURLProtocol.Stub(
    statusCode: 200, headers: [:],
    body: Data(
        #"{"RELEASE_VERSION":"6.0.0","COLLABORATION_WS_URL":"https://docs.llun.dev/ws/v1/acme"}"#.utf8),
    error: nil)
private let legacyConfigStub = MockURLProtocol.Stub(
    statusCode: 200, headers: [:], body: Data(#"{"RELEASE_VERSION":"5.4.1"}"#.utf8), error: nil)

@MainActor
final class ConnectViewModelTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private let suiteName = "dev.llun.Schrift.tests.ConnectViewModelTests"

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
        serverCapabilities: ServerCapabilityStore? = nil,
        serverConfigStore: ServerConfigStore? = nil,
        stub: @escaping @Sendable (URLRequest) -> MockURLProtocol.Stub
    ) -> ConnectViewModel {
        MockURLProtocol.stubHandler = stub
        let sessionStore = SessionStore(userDefaults: userDefaults, keychain: FakeKeychainStore())
        let recentServers = RecentServersStore(userDefaults: userDefaults)
        return ConnectViewModel(
            sessionStore: sessionStore,
            recentServers: recentServers,
            serverCapabilities: serverCapabilities ?? ServerCapabilityStore(userDefaults: userDefaults),
            serverConfigStore: serverConfigStore ?? ServerConfigStore(userDefaults: userDefaults),
            apiClientFactory: { serverURL in
                DocsAPIClient(
                    baseURL: serverURL.appendingPathComponent("api/v1.0/"),
                    session: MockURLProtocol.makeSession(),
                    cookieProvider: { [] }
                )
            }
        )
    }

    /// Answers `/users/me/` and `/config/` separately: sign-in now asks both, and one blanket
    /// response would make the config answer depend on the identity fixture.
    /// Matched on `absoluteString`: `URL.path` drops the trailing slash.
    private func signInStub(
        identity: MockURLProtocol.Stub, config: MockURLProtocol.Stub
    ) -> @Sendable (URLRequest) -> MockURLProtocol.Stub {
        { request in
            request.url?.absoluteString.hasSuffix("/config/") == true ? config : identity
        }
    }

    func testStartSignInWithValidInputPresentsWebLogin() {
        let viewModel = makeViewModel { _ in .init(statusCode: 200, headers: [:], body: Data(), error: nil) }
        viewModel.serverURLInput = "docs.llun.dev"

        viewModel.startSignIn()

        XCTAssertTrue(viewModel.isPresentingWebLogin)
        XCTAssertEqual(viewModel.pendingServerURL?.absoluteString, "https://docs.llun.dev")
        XCTAssertNil(viewModel.errorKey)
    }

    func testStartSignInWithInvalidInputShowsErrorAndDoesNotPresent() {
        let viewModel = makeViewModel { _ in .init(statusCode: 200, headers: [:], body: Data(), error: nil) }
        viewModel.serverURLInput = "   "

        viewModel.startSignIn()

        XCTAssertFalse(viewModel.isPresentingWebLogin)
        XCTAssertEqual(viewModel.errorKey, .connect_error_invalid_server)
    }

    func testHandleLoginCompleteSuccessSignsInAndRecordsRecentServer() async throws {
        let viewModel = makeViewModel(
            stub: signInStub(
                identity: .init(statusCode: 200, headers: [:], body: "{}".data(using: .utf8)!, error: nil),
                config: docs6ConfigStub))
        viewModel.serverURLInput = "docs.llun.dev"
        viewModel.startSignIn()

        await viewModel.handleLoginComplete()

        XCTAssertFalse(viewModel.isPresentingWebLogin)
        XCTAssertTrue(viewModel.sessionStore.isAuthenticated)
        XCTAssertEqual(viewModel.sessionStore.serverURL?.absoluteString, "https://docs.llun.dev")
        XCTAssertEqual(viewModel.recentServers.servers.map(\.absoluteString), ["https://docs.llun.dev"])
        XCTAssertNil(viewModel.errorKey)
    }

    func testHandleLoginCompleteFailureShowsErrorAndDoesNotSignIn() async throws {
        let viewModel = makeViewModel { _ in .init(statusCode: 401, headers: [:], body: Data(), error: nil) }
        viewModel.serverURLInput = "docs.llun.dev"
        viewModel.startSignIn()

        await viewModel.handleLoginComplete()

        XCTAssertFalse(viewModel.sessionStore.isAuthenticated)
        XCTAssertEqual(viewModel.errorKey, .connect_error_sign_in_failed)
        XCTAssertTrue(viewModel.recentServers.servers.isEmpty)
    }

    /// The same handover the re-login sheet makes, and it goes through the same call for the
    /// same reason. Reaching this screen normally means a sign-out has already emptied both
    /// identity stores, so there is usually nothing to forget — but the cookies are live either
    /// way, and a rule that holds only because of what some *other* path happens to have done
    /// is one a later path can quietly break.
    func testAFailedConfirmationForgetsWhoeverTheIdentityStoresStillName() async throws {
        let viewModel = makeViewModel { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        let signedIn = SignedInUserStore(userDefaults: userDefaults)
        let previousUser = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        signedIn.remember(previousUser)
        CurrentUserCacheStore(userDefaults: userDefaults)
            .remember(CurrentUser(id: previousUser, email: "ada@example.org"))
        viewModel.serverURLInput = "docs.llun.dev"
        viewModel.startSignIn()

        await viewModel.handleLoginComplete()

        XCTAssertEqual(viewModel.errorKey, .connect_error_sign_in_failed)
        XCTAssertNil(signedIn.userID)
        XCTAssertNil(CurrentUserCacheStore(userDefaults: userDefaults).user)
    }

    func testSelectRecentServerPresentsWebLoginForThatServer() {
        let viewModel = makeViewModel { _ in .init(statusCode: 200, headers: [:], body: Data(), error: nil) }
        let url = URL(string: "https://old.example.com")!

        viewModel.selectRecentServer(url)

        XCTAssertTrue(viewModel.isPresentingWebLogin)
        XCTAssertEqual(viewModel.pendingServerURL, url)
    }

    /// An identity the client cannot parse is "signed in, identity unknown", never a blocked
    /// sign-in: the old confirmation accepted any JSON object, and Home learns the id later.
    func testAnUnparseableIdentitySignsInWithTheIdentityUnknown() async throws {
        let viewModel = makeViewModel(
            stub: signInStub(
                identity: .init(statusCode: 200, headers: [:], body: Data(#"{"id":"not-a-uuid"}"#.utf8), error: nil),
                config: docs6ConfigStub))
        viewModel.serverURLInput = "docs.llun.dev"
        viewModel.startSignIn()

        await viewModel.handleLoginComplete()

        XCTAssertNil(viewModel.errorKey)
        XCTAssertTrue(viewModel.sessionStore.isAuthenticated)
        XCTAssertNil(SignedInUserStore(userDefaults: userDefaults).userID)
    }

    // MARK: - Docs 6 requirement

    func testADocs6ServerSignsInAndRecordsTheCapability() async throws {
        let capabilities = ServerCapabilityStore(userDefaults: userDefaults)
        let log = RequestRecorder()
        let viewModel = makeViewModel(serverCapabilities: capabilities) { request in
            log.record(request)
            return request.url?.absoluteString.hasSuffix("/config/") == true ? docs6ConfigStub : identityStub
        }
        viewModel.serverURLInput = "docs.llun.dev"
        viewModel.startSignIn()

        await viewModel.handleLoginComplete()

        XCTAssertTrue(viewModel.sessionStore.isAuthenticated)
        XCTAssertNil(viewModel.errorKey)
        XCTAssertEqual(capabilities.capability(forServerOrigin: "https://docs.llun.dev"), .docs6)
        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "/api/v1.0/config/"), 1)
    }

    /// The whole config is kept, not just the capability: the native editor's offline create
    /// needs the collaboration org, and RootView's hook only fills it later.
    func testADocs6SignInRemembersTheFullConfigForTheOrigin() async throws {
        let configs = ServerConfigStore(userDefaults: userDefaults)
        let viewModel = makeViewModel(serverConfigStore: configs) { request in
            request.url?.absoluteString.hasSuffix("/config/") == true ? docs6ConfigWithOrgStub : identityStub
        }
        viewModel.serverURLInput = "docs.llun.dev"
        viewModel.startSignIn()

        await viewModel.handleLoginComplete()

        let config = configs.config(forServerOrigin: "https://docs.llun.dev")
        XCTAssertEqual(config?.releaseVersion, "6.0.0")
        XCTAssertEqual(config?.collaborationOrg, "acme")
    }

    func testALegacyServerRefusesSignInWithTheUnsupportedErrorAndRecordsLegacy() async throws {
        let capabilities = ServerCapabilityStore(userDefaults: userDefaults)
        let viewModel = makeViewModel(serverCapabilities: capabilities) { request in
            request.url?.absoluteString.hasSuffix("/config/") == true ? legacyConfigStub : identityStub
        }
        viewModel.serverURLInput = "docs.llun.dev"
        viewModel.startSignIn()

        await viewModel.handleLoginComplete()

        XCTAssertFalse(viewModel.sessionStore.isAuthenticated)
        XCTAssertEqual(viewModel.errorKey, .server_unsupported)
        XCTAssertTrue(viewModel.recentServers.servers.isEmpty)
        XCTAssertEqual(capabilities.capability(forServerOrigin: "https://docs.llun.dev"), .legacy)
    }

    /// A 404 for `config/` proves nothing (a proxy mid-rollout answers one too): the sign-in
    /// proceeds, and a stale cached legacy for the server is cleared rather than kept.
    func testAConfigRoute404SignsInAndClearsAStaleLegacy() async throws {
        let capabilities = ServerCapabilityStore(userDefaults: userDefaults)
        capabilities.record(.legacy, forServerOrigin: "https://docs.llun.dev")
        let viewModel = makeViewModel(serverCapabilities: capabilities) { request in
            request.url?.absoluteString.hasSuffix("/config/") == true
                ? .init(statusCode: 404, headers: ["Content-Type": "text/html"], body: Data(), error: nil)
                : identityStub
        }
        viewModel.serverURLInput = "docs.llun.dev"
        viewModel.startSignIn()

        await viewModel.handleLoginComplete()

        XCTAssertTrue(viewModel.sessionStore.isAuthenticated)
        XCTAssertNil(viewModel.errorKey)
        XCTAssertNil(capabilities.capability(forServerOrigin: "https://docs.llun.dev"))
    }

    /// A config fetch that proves nothing is *unknown*, never legacy: the sign-in proceeds and
    /// the launch gate re-checks next time.
    func testAConfigFetchFailureSignsInAndRecordsUnknown() async throws {
        let capabilities = ServerCapabilityStore(userDefaults: userDefaults)
        let viewModel = makeViewModel(serverCapabilities: capabilities) { request in
            request.url?.absoluteString.hasSuffix("/config/") == true
                ? .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
                : identityStub
        }
        viewModel.serverURLInput = "docs.llun.dev"
        viewModel.startSignIn()

        await viewModel.handleLoginComplete()

        XCTAssertTrue(viewModel.sessionStore.isAuthenticated)
        XCTAssertNil(viewModel.errorKey)
        XCTAssertNil(capabilities.capability(forServerOrigin: "https://docs.llun.dev"))
    }
}
