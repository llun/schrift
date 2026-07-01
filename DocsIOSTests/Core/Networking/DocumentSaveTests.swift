import XCTest
@testable import DocsIOS

final class MultipartFormDataTests: XCTestCase {
    func testBuildsExpectedWireFormat() throws {
        let body = multipartFormData(
            boundary: "TestBoundary",
            fieldName: "file",
            filename: "Doc.md",
            contentType: "text/markdown",
            content: "# Hi".data(using: .utf8)!
        )
        let string = String(data: body, encoding: .utf8)!
        XCTAssertEqual(string, "--TestBoundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"Doc.md\"\r\nContent-Type: text/markdown\r\n\r\n# Hi\r\n--TestBoundary--\r\n")
    }
}

private final class RequestLog: @unchecked Sendable {
    var requests: [URLRequest] = []
}

private func bodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 4096
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    while stream.hasBytesAvailable {
        let bytesRead = stream.read(&buffer, maxLength: bufferSize)
        if bytesRead > 0 {
            data.append(buffer, count: bytesRead)
        } else {
            break
        }
    }
    return data
}

final class DocumentSaveClientTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let realDocumentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let tempDocumentID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    override func tearDown() {
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
        super.tearDown()
    }

    private func makeClient() -> DocsAPIClient {
        DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
    }

    private func tempDocumentFixture() -> Data {
        """
        {
            "id": "22222222-2222-4222-8222-222222222222",
            "title": "Doc.md",
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

    func testCreateDocumentFromMarkdownSendsMultipartRequest() async throws {
        let fixture = tempDocumentFixture()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 201, headers: [:], body: fixture, error: nil) }
        let client = makeClient()

        let document = try await client.createDocumentFromMarkdown(title: "Doc", markdown: "# Hi")

        XCTAssertEqual(document.id, tempDocumentID)
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.absoluteString, "https://docs.example.org/api/v1.0/documents/")
        let contentType = MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Content-Type") ?? ""
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
    }

    func testRawContentReturnsUndecodedBytes() async throws {
        let rawBytes = Data([0x01, 0x02, 0x03, 0xFF])
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: rawBytes, error: nil) }
        let client = makeClient()

        let result = try await client.rawContent(documentID: tempDocumentID)

        XCTAssertEqual(result, rawBytes)
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.absoluteString, "https://docs.example.org/api/v1.0/documents/22222222-2222-4222-8222-222222222222/content/")
    }

    func testSetContentSendsBase64EncodedJSONBody() async throws {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 204, headers: [:], body: Data(), error: nil) }
        let client = makeClient()
        let rawBytes = Data([0x01, 0x02, 0x03])

        try await client.setContent(documentID: realDocumentID, rawContent: rawBytes)

        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "PATCH")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.absoluteString, "https://docs.example.org/api/v1.0/documents/11111111-1111-4111-8111-111111111111/content/")
        let sentBody = MockURLProtocol.lastRequest.flatMap(bodyData(from:))
        let json = try XCTUnwrap(sentBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] })
        XCTAssertEqual(json["content"], rawBytes.base64EncodedString())
    }

    func testDeleteDocumentSendsDeleteRequest() async throws {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 204, headers: [:], body: Data(), error: nil) }
        let client = makeClient()

        try await client.deleteDocument(documentID: tempDocumentID)

        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.absoluteString, "https://docs.example.org/api/v1.0/documents/22222222-2222-4222-8222-222222222222/")
    }

    func testSaveDocumentContentHappyPathCallsAllFourStepsInOrder() async throws {
        let fixture = tempDocumentFixture()
        let log = RequestLog()
        MockURLProtocol.stubHandler = { request in
            log.requests.append(request)
            if request.httpMethod == "POST" {
                return .init(statusCode: 201, headers: [:], body: fixture, error: nil)
            }
            if request.httpMethod == "GET" {
                return .init(statusCode: 200, headers: [:], body: Data([0xAA, 0xBB]), error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        let client = makeClient()

        try await client.saveDocumentContent(documentID: realDocumentID, title: "Doc", markdown: "# Hi")

        XCTAssertEqual(log.requests.map(\.httpMethod), ["POST", "GET", "PATCH", "DELETE"])
        XCTAssertTrue(log.requests[1].url?.absoluteString.contains("22222222") ?? false)
        XCTAssertTrue(log.requests[2].url?.absoluteString.contains("11111111") ?? false)
        XCTAssertTrue(log.requests[3].url?.absoluteString.contains("22222222") ?? false)
    }

    func testSaveDocumentContentDeletesTempDocumentEvenWhenGetContentFails() async throws {
        let fixture = tempDocumentFixture()
        let log = RequestLog()
        MockURLProtocol.stubHandler = { request in
            log.requests.append(request)
            if request.httpMethod == "POST" {
                return .init(statusCode: 201, headers: [:], body: fixture, error: nil)
            }
            if request.httpMethod == "GET" {
                return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        let client = makeClient()

        do {
            try await client.saveDocumentContent(documentID: realDocumentID, title: "Doc", markdown: "# Hi")
            XCTFail("Expected error to be thrown")
        } catch {
            // expected
        }

        XCTAssertEqual(log.requests.map(\.httpMethod), ["POST", "GET", "DELETE"])
    }

    func testSaveDocumentContentDeletesTempDocumentEvenWhenPatchContentFails() async throws {
        let fixture = tempDocumentFixture()
        let log = RequestLog()
        MockURLProtocol.stubHandler = { request in
            log.requests.append(request)
            if request.httpMethod == "POST" {
                return .init(statusCode: 201, headers: [:], body: fixture, error: nil)
            }
            if request.httpMethod == "GET" {
                return .init(statusCode: 200, headers: [:], body: Data([0xAA]), error: nil)
            }
            if request.httpMethod == "PATCH" {
                return .init(statusCode: 403, headers: [:], body: Data(), error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        let client = makeClient()

        do {
            try await client.saveDocumentContent(documentID: realDocumentID, title: "Doc", markdown: "# Hi")
            XCTFail("Expected error to be thrown")
        } catch let error as DocsAPIError {
            XCTAssertEqual(error, .forbidden)
        }

        XCTAssertEqual(log.requests.map(\.httpMethod), ["POST", "GET", "PATCH", "DELETE"])
    }
}
