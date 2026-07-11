import XCTest

@testable import Schrift

@MainActor
final class VersionHistoryViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeViewModel() -> VersionHistoryViewModel {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        return VersionHistoryViewModel(client: client, documentID: documentID)
    }

    func testLoadSuccessPopulatesVersionsAndClearsError() async {
        let responseBody = #"""
            {"versions":[{"version_id":"v1","last_modified":"2026-07-11T15:04:00Z","is_current":true},{"version_id":"v2","last_modified":"2026-07-11T14:32:00Z"}]}
            """#.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: responseBody, error: nil) }
        let viewModel = makeViewModel()

        await viewModel.load()

        XCTAssertEqual(viewModel.versions.count, 2)
        XCTAssertNil(viewModel.errorKey)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testLoadFailureSetsErrorKeyAndLeavesVersionsEmpty() async {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        let viewModel = makeViewModel()

        await viewModel.load()

        XCTAssertTrue(viewModel.versions.isEmpty)
        XCTAssertEqual(viewModel.errorKey, .versions_error)
        XCTAssertFalse(viewModel.isLoading)
    }
}
