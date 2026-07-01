import XCTest
@testable import Schrift

@MainActor
final class EditorViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!

    override func tearDown() {
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
        super.tearDown()
    }

    private func makeViewModel(title: String = "Untitled document") -> EditorViewModel {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        return EditorViewModel(client: client, documentID: documentID, title: title)
    }

    func testLoadParsesMarkdownContentIntoBlocks() async {
        let viewModel = makeViewModel()
        let body = """
        {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Q3 Planning", "content": "# Heading\\n\\nA paragraph.", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }

        await viewModel.load()

        XCTAssertEqual(viewModel.blocks, [.heading(level: 1, text: "Heading"), .paragraph(text: "A paragraph.")])
        XCTAssertEqual(viewModel.title, "Q3 Planning")
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testLoadWithNullContentProducesNoBlocks() async {
        let viewModel = makeViewModel()
        let body = """
        {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": null, "content": null, "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }

        await viewModel.load()

        XCTAssertTrue(viewModel.blocks.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testLoadKeepsOriginalTitleWhenServerTitleIsNull() async {
        let viewModel = makeViewModel(title: "Original Title")
        let body = """
        {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": null, "content": "Text", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }

        await viewModel.load()

        XCTAssertEqual(viewModel.title, "Original Title")
    }

    func testLoadFailureSetsErrorMessage() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.load()

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertTrue(viewModel.blocks.isEmpty)
    }

    func testStartEditingSetsIsEditingTrue() async {
        let viewModel = makeViewModel()
        let body = """
        {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "Original text", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }
        await viewModel.load()

        viewModel.startEditing()

        XCTAssertTrue(viewModel.isEditing)
    }

    func testCancelEditingRevertsUnsavedChanges() async {
        let viewModel = makeViewModel()
        let body = """
        {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "Original text", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }
        await viewModel.load()
        viewModel.startEditing()
        viewModel.rawMarkdown = "Edited but not saved"

        viewModel.cancelEditing()

        XCTAssertEqual(viewModel.rawMarkdown, "Original text")
        XCTAssertFalse(viewModel.isEditing)
    }

    func testSaveSuccessUpdatesBlocksAndExitsEditingMode() async {
        let viewModel = makeViewModel()
        let loadBody = """
        {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "Original", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
        """.data(using: .utf8)!
        let tempDocBody = """
        {"id": "22222222-2222-4222-8222-222222222222", "title": "Doc.md", "excerpt": null, "abilities": {}, "computed_link_reach": "restricted", "computed_link_role": null, "created_at": "2026-01-15T10:30:00Z", "creator": null, "depth": 1, "link_role": "reader", "link_reach": "restricted", "numchild": 0, "path": "0002", "updated_at": "2026-01-15T10:30:00Z", "user_role": "owner", "is_favorite": false}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { request in
            switch request.httpMethod {
            case "POST": return .init(statusCode: 201, headers: [:], body: tempDocBody, error: nil)
            case "GET" where request.url?.absoluteString.contains("formatted-content") == true:
                return .init(statusCode: 200, headers: [:], body: loadBody, error: nil)
            case "GET": return .init(statusCode: 200, headers: [:], body: Data([0xAA]), error: nil)
            default: return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
            }
        }
        await viewModel.load()
        viewModel.startEditing()
        viewModel.rawMarkdown = "# New Heading"

        await viewModel.save()

        XCTAssertEqual(viewModel.blocks, [.heading(level: 1, text: "New Heading")])
        XCTAssertFalse(viewModel.isEditing)
        XCTAssertFalse(viewModel.isSaving)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testSaveFailureSetsErrorMessageAndStaysInEditingMode() async {
        let viewModel = makeViewModel()
        let loadBody = """
        {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "Original", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { request in
            if request.url?.absoluteString.contains("formatted-content") == true {
                return .init(statusCode: 200, headers: [:], body: loadBody, error: nil)
            }
            return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }
        await viewModel.load()
        viewModel.startEditing()
        viewModel.rawMarkdown = "# New Heading"

        await viewModel.save()

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.isEditing)
        XCTAssertFalse(viewModel.isSaving)
    }
}
