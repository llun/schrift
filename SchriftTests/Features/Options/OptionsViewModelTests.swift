import XCTest

@testable import Schrift

final class DocumentShareURLTests: XCTestCase {
    func testBuildsExpectedURL() {
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        XCTAssertEqual(
            documentShareURL(serverHost: "docs.llun.dev", documentID: id)?.absoluteString,
            "https://docs.llun.dev/docs/11111111-1111-4111-8111-111111111111/"
        )
    }
}

@MainActor
final class OptionsViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeViewModel(isFavorite: Bool = false) -> OptionsViewModel {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        return OptionsViewModel(client: client, documentID: documentID, isFavorite: isFavorite)
    }

    func testToggleFavoriteFlipsStateOnSuccess() async {
        let viewModel = makeViewModel(isFavorite: false)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 201, headers: [:], body: Data(), error: nil) }

        await viewModel.toggleFavorite()

        XCTAssertTrue(viewModel.isFavorite)
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertNil(viewModel.errorKey)
    }

    func testToggleFavoriteFailureKeepsStateAndSetsError() async {
        let viewModel = makeViewModel(isFavorite: false)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.toggleFavorite()

        XCTAssertFalse(viewModel.isFavorite)
        XCTAssertEqual(viewModel.errorKey, .options_error_toggle_favorite)
    }

    func testDuplicateReturnsNewDocumentIDOnSuccess() async {
        let viewModel = makeViewModel()
        let body = #"{"id": "22222222-2222-4222-8222-222222222222"}"#.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 201, headers: [:], body: body, error: nil) }

        let result = await viewModel.duplicate()

        XCTAssertEqual(result, UUID(uuidString: "22222222-2222-4222-8222-222222222222")!)
        XCTAssertFalse(viewModel.isDuplicating)
        XCTAssertNil(viewModel.errorKey)
    }

    func testDuplicateFailureSetsErrorAndReturnsNil() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        let result = await viewModel.duplicate()

        XCTAssertNil(result)
        XCTAssertEqual(viewModel.errorKey, .options_error_duplicate)
    }

    func testDeleteSetsDidDeleteOnSuccess() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 204, headers: [:], body: Data(), error: nil) }

        await viewModel.delete()

        XCTAssertTrue(viewModel.didDelete)
        XCTAssertFalse(viewModel.isDeleting)
        XCTAssertNil(viewModel.errorKey)
    }

    func testDeleteFailureSetsErrorAndDoesNotSetDidDelete() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.delete()

        XCTAssertFalse(viewModel.didDelete)
        XCTAssertEqual(viewModel.errorKey, .options_error_delete)
    }
}
