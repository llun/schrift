import XCTest

@testable import Schrift

@MainActor
final class ProfileViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeViewModel() -> ProfileViewModel {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        return ProfileViewModel(client: client)
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
        XCTAssertNil(viewModel.errorMessage)
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
