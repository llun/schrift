import XCTest
@testable import Schrift

@MainActor
final class ConnectViewModelTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private let suiteName = "dev.llun.Schrift.tests.ConnectViewModelTests"

    override func setUp() {
        super.setUp()
        userDefaults = UserDefaults(suiteName: suiteName)
        userDefaults.removePersistentDomain(forName: suiteName)
        MockURLProtocol.stubHandler = nil
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        MockURLProtocol.stubHandler = nil
        super.tearDown()
    }

    private func makeViewModel(stub: @escaping @Sendable (URLRequest) -> MockURLProtocol.Stub) -> ConnectViewModel {
        MockURLProtocol.stubHandler = stub
        let sessionStore = SessionStore(userDefaults: userDefaults, keychain: FakeKeychainStore())
        let recentServers = RecentServersStore(userDefaults: userDefaults)
        return ConnectViewModel(
            sessionStore: sessionStore,
            recentServers: recentServers,
            apiClientFactory: { serverURL in
                DocsAPIClient(
                    baseURL: serverURL.appendingPathComponent("api/v1.0/"),
                    session: MockURLProtocol.makeSession(),
                    cookieProvider: { [] }
                )
            }
        )
    }

    func testStartSignInWithValidInputPresentsWebLogin() {
        let viewModel = makeViewModel { _ in .init(statusCode: 200, headers: [:], body: Data(), error: nil) }
        viewModel.serverURLInput = "docs.llun.dev"

        viewModel.startSignIn()

        XCTAssertTrue(viewModel.isPresentingWebLogin)
        XCTAssertEqual(viewModel.pendingServerURL?.absoluteString, "https://docs.llun.dev")
        XCTAssertNil(viewModel.errorMessage)
    }

    func testStartSignInWithInvalidInputShowsErrorAndDoesNotPresent() {
        let viewModel = makeViewModel { _ in .init(statusCode: 200, headers: [:], body: Data(), error: nil) }
        viewModel.serverURLInput = "   "

        viewModel.startSignIn()

        XCTAssertFalse(viewModel.isPresentingWebLogin)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testHandleLoginCompleteSuccessSignsInAndRecordsRecentServer() async throws {
        let viewModel = makeViewModel { _ in .init(statusCode: 200, headers: [:], body: "{}".data(using: .utf8)!, error: nil) }
        viewModel.serverURLInput = "docs.llun.dev"
        viewModel.startSignIn()

        await viewModel.handleLoginComplete()

        XCTAssertFalse(viewModel.isPresentingWebLogin)
        XCTAssertTrue(viewModel.sessionStore.isAuthenticated)
        XCTAssertEqual(viewModel.sessionStore.serverURL?.absoluteString, "https://docs.llun.dev")
        XCTAssertEqual(viewModel.recentServers.servers.map(\.absoluteString), ["https://docs.llun.dev"])
        XCTAssertNil(viewModel.errorMessage)
    }

    func testHandleLoginCompleteFailureShowsErrorAndDoesNotSignIn() async throws {
        let viewModel = makeViewModel { _ in .init(statusCode: 401, headers: [:], body: Data(), error: nil) }
        viewModel.serverURLInput = "docs.llun.dev"
        viewModel.startSignIn()

        await viewModel.handleLoginComplete()

        XCTAssertFalse(viewModel.sessionStore.isAuthenticated)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.recentServers.servers.isEmpty)
    }

    func testSelectRecentServerPresentsWebLoginForThatServer() {
        let viewModel = makeViewModel { _ in .init(statusCode: 200, headers: [:], body: Data(), error: nil) }
        let url = URL(string: "https://old.example.com")!

        viewModel.selectRecentServer(url)

        XCTAssertTrue(viewModel.isPresentingWebLogin)
        XCTAssertEqual(viewModel.pendingServerURL, url)
    }
}
