import XCTest
@testable import DocsIOS

final class FormattedDocumentContentDecodingTests: XCTestCase {
    func testDecodesFullFixture() throws {
        let json = """
        {
            "id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b",
            "title": "Q3 Planning",
            "content": "# Heading\\n\\nBody text",
            "created_at": "2026-01-15T10:30:00Z",
            "updated_at": "2026-01-16T11:00:00Z"
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder.docsAPI.decode(FormattedDocumentContent.self, from: json)
        XCTAssertEqual(result.title, "Q3 Planning")
        XCTAssertEqual(result.content, "# Heading\n\nBody text")
    }

    func testDecodesNullContentForEmptyDocument() throws {
        let json = """
        {
            "id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b",
            "title": null,
            "content": null,
            "created_at": "2026-01-15T10:30:00Z",
            "updated_at": "2026-01-15T10:30:00Z"
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder.docsAPI.decode(FormattedDocumentContent.self, from: json)
        XCTAssertNil(result.title)
        XCTAssertNil(result.content)
    }
}

final class FormattedDocumentContentClientTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!

    override func tearDown() {
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
        super.tearDown()
    }

    func testFormattedContentRequestsCorrectURLWithMarkdownFormat() async throws {
        let body = """
        {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "text", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let id = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!

        let result = try await client.formattedContent(documentID: id)

        XCTAssertEqual(result.content, "text")
        XCTAssertEqual(
            MockURLProtocol.lastRequest?.url?.absoluteString,
            "https://docs.example.org/api/v1.0/documents/8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b/formatted-content/?content_format=markdown"
        )
    }
}
