import XCTest

@testable import Schrift

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
        MockURLProtocol.reset()
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

    // MARK: - Legacy backends have no formatted-content route

    private static let contentBody = """
        {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "# md", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
        """.data(using: .utf8)!

    /// Older docs releases expose the markdown projection at `content/?content_format=…` and
    /// have no `formatted-content/` route at all — the request 404s with an HTML body. Every
    /// 404 maps to `.notFound`, which the editor reads as "this document was deleted", so an
    /// entire server's documents rendered as "This document is no longer available."
    func testFallsBackToTheContentRouteWhenFormattedContentIs404() async throws {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let isFormatted = request.url?.path.contains("formatted-content") == true
            return isFormatted
                ? .init(statusCode: 404, headers: [:], body: Data("<html>Not Found</html>".utf8), error: nil)
                : .init(statusCode: 200, headers: [:], body: Self.contentBody, error: nil)
        }
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let id = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!

        let result = try await client.formattedContent(documentID: id)

        XCTAssertEqual(result.content, "# md")
        XCTAssertEqual(
            MockURLProtocol.lastRequest?.url?.absoluteString,
            "https://docs.example.org/api/v1.0/documents/8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b/content/?content_format=markdown"
        )
        XCTAssertEqual(log.count(ofMethod: "GET"), 2, "should try formatted-content, then fall back")
    }

    /// Once the legacy route has answered, the client must stop paying for a 404 on every
    /// single content load.
    func testTheLegacyRouteIsRememberedForSubsequentLoads() async throws {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let isFormatted = request.url?.path.contains("formatted-content") == true
            return isFormatted
                ? .init(statusCode: 404, headers: [:], body: Data(), error: nil)
                : .init(statusCode: 200, headers: [:], body: Self.contentBody, error: nil)
        }
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let id = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!

        _ = try await client.formattedContent(documentID: id)
        _ = try await client.formattedContent(documentID: id)

        // 2 for the first load (404 + fallback), 1 for the second (straight to the fallback).
        XCTAssertEqual(log.count(ofMethod: "GET"), 3)
        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "formatted-content"), 1)
    }

    /// A genuinely deleted document 404s on both routes. It must still surface `.notFound`,
    /// not the fallback's decoding error — the editor's delete/teardown path depends on it.
    func testADeletedDocumentStillThrowsNotFound() async {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 404, headers: [:], body: Data(), error: nil) }
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let id = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!

        do {
            _ = try await client.formattedContent(documentID: id)
            XCTFail("Expected notFound")
        } catch let error as DocsAPIError {
            XCTAssertEqual(error, .notFound)
        } catch {
            XCTFail("Expected DocsAPIError, got \(error)")
        }
    }

    /// A 403 is revoked access, not a missing route. It must not trigger the fallback.
    func testForbiddenDoesNotFallBack() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 403, headers: [:], body: Data(), error: nil)
        }
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let id = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!

        do {
            _ = try await client.formattedContent(documentID: id)
            XCTFail("Expected forbidden")
        } catch let error as DocsAPIError {
            XCTAssertEqual(error, .forbidden)
        } catch {
            XCTFail("Expected DocsAPIError, got \(error)")
        }
        XCTAssertEqual(log.count(ofMethod: "GET"), 1)
    }
}
