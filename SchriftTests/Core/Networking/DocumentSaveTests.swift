import XCTest

@testable import Schrift

private final class RequestLog: @unchecked Sendable {
    var requests: [URLRequest] = []
}

// `bodyData(from:)` now lives in SchriftTests/Support/RequestBodyHelpers.swift.

private func jsonBody(_ request: URLRequest?) -> [String: String]? {
    request.flatMap(bodyData(from:)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
}

final class DocumentSaveClientTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let realDocumentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> DocsAPIClient {
        DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
    }

    private func documentFixture() -> Data {
        """
        {
            "id": "22222222-2222-4222-8222-222222222222",
            "title": "Untitled document",
            "excerpt": null,
            "abilities": {},
            "computed_link_reach": "restricted",
            "computed_link_role": null,
            "created_at": "2026-01-15T10:30:00Z",
            "creator": null,
            "depth": 1,
            "link_role": "reader",
            "link_reach": "restricted",
            "numchild": 0,
            "path": "0002",
            "updated_at": "2026-01-15T10:30:00Z",
            "user_role": "owner",
            "is_favorite": false
        }
        """.data(using: .utf8)!
    }

    func testCreateDocumentSendsJSONTitle() async throws {
        let fixture = documentFixture()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 201, headers: [:], body: fixture, error: nil) }
        let client = makeClient()

        let document = try await client.createDocument(title: "My doc")

        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.absoluteString, "https://docs.example.org/api/v1.0/documents/")
        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(jsonBody(MockURLProtocol.lastRequest)?["title"], "My doc")
        XCTAssertEqual(document.title, "Untitled document")
    }

    func testSetContentSendsBase64EncodedYjs() async throws {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 204, headers: [:], body: Data(), error: nil) }
        let client = makeClient()
        let yjs = Data([0x01, 0x02, 0x03])

        try await client.setContent(documentID: realDocumentID, yjsUpdate: yjs)

        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "PATCH")
        XCTAssertEqual(
            MockURLProtocol.lastRequest?.url?.absoluteString,
            "https://docs.example.org/api/v1.0/documents/11111111-1111-4111-8111-111111111111/content/")
        XCTAssertEqual(jsonBody(MockURLProtocol.lastRequest)?["content"], yjs.base64EncodedString())
    }

    func testUpdateTitleSendsPatchToDocument() async throws {
        let fixture = documentFixture()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: fixture, error: nil) }
        let client = makeClient()

        try await client.updateTitle(documentID: realDocumentID, title: "Renamed")

        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "PATCH")
        XCTAssertEqual(
            MockURLProtocol.lastRequest?.url?.absoluteString,
            "https://docs.example.org/api/v1.0/documents/11111111-1111-4111-8111-111111111111/")
        XCTAssertEqual(jsonBody(MockURLProtocol.lastRequest)?["title"], "Renamed")
    }

    func testDeleteDocumentSendsDeleteRequest() async throws {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 204, headers: [:], body: Data(), error: nil) }
        let client = makeClient()

        try await client.deleteDocument(documentID: realDocumentID)

        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(
            MockURLProtocol.lastRequest?.url?.absoluteString,
            "https://docs.example.org/api/v1.0/documents/11111111-1111-4111-8111-111111111111/")
    }

    func testSaveDocumentContentPatchesValidYjsContentThenTitle() async throws {
        let log = RequestLog()
        MockURLProtocol.stubHandler = { request in
            log.requests.append(request)
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        let client = makeClient()

        let titleFailure = try await client.saveDocumentContent(
            documentID: realDocumentID, title: "Notes", markdown: "# Hi\n\nHello **world**")

        XCTAssertNil(titleFailure, "both PATCHes landed")

        // Content is written first, then the title.
        XCTAssertEqual(log.requests.map(\.httpMethod), ["PATCH", "PATCH"])
        XCTAssertEqual(
            log.requests[0].url?.absoluteString,
            "https://docs.example.org/api/v1.0/documents/11111111-1111-4111-8111-111111111111/content/")
        XCTAssertEqual(
            log.requests[1].url?.absoluteString,
            "https://docs.example.org/api/v1.0/documents/11111111-1111-4111-8111-111111111111/")

        // The content field must be base64 that decodes to a real Yjs update
        // (a v1 update begins with the client count varUint, 0x01 for one client).
        let contentBody = try XCTUnwrap(bodyData(from: log.requests[0]))
        let content = try XCTUnwrap((try? JSONSerialization.jsonObject(with: contentBody)) as? [String: String])
        let decoded = try XCTUnwrap(Data(base64Encoded: content["content"] ?? ""))
        XCTAssertFalse(decoded.isEmpty)
        XCTAssertEqual(decoded.first, 0x01)

        XCTAssertEqual(jsonBody(log.requests[1])?["title"], "Notes")
    }

    // MARK: - The split return: a save is two requests and can half-land

    /// The contract the offline stack depends on. If the connection drops **between** the two
    /// PATCHes, the server already holds the new body while the save failed — and a caller that
    /// only learns "it failed" would compare its own write against a stale baseline on the next
    /// reconcile and raise a **sync conflict against the user's own writing**. So a title-only
    /// failure must NOT throw: it comes back as a value, with the content confirmed landed.
    func testATitleOnlyFailureReturnsTheErrorInsteadOfThrowing() async throws {
        let log = RequestLog()
        MockURLProtocol.stubHandler = { request in
            log.requests.append(request)
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("/content/") {
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
            }
            return .init(statusCode: 500, headers: [:], body: Data(), error: nil)  // the title PATCH
        }
        let client = makeClient()

        let titleFailure = try await client.saveDocumentContent(
            documentID: realDocumentID, title: "Notes", markdown: "# Hi")

        XCTAssertEqual(
            titleFailure, .server(statusCode: 500), "the content landed — report the title failure, do not throw")
        XCTAssertEqual(log.requests.map(\.httpMethod), ["PATCH", "PATCH"], "both were attempted")
    }

    /// The other half: a **content** PATCH failure throws, because nothing was confirmed — and
    /// the title PATCH must not even be attempted.
    func testAContentFailureThrowsAndNeverAttemptsTheTitle() async {
        let log = RequestLog()
        MockURLProtocol.stubHandler = { request in
            log.requests.append(request)
            return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }
        let client = makeClient()

        do {
            _ = try await client.saveDocumentContent(documentID: realDocumentID, title: "Notes", markdown: "# Hi")
            XCTFail("a failed content PATCH must throw")
        } catch let error as DocsAPIError {
            XCTAssertEqual(error, .server(statusCode: 500))
        } catch {
            XCTFail("expected DocsAPIError, got \(error)")
        }
        XCTAssertEqual(log.requests.count, 1, "the title PATCH must not be attempted after the content failed")
    }
}
