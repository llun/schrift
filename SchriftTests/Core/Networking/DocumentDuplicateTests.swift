import XCTest

@testable import Schrift

final class DocumentDuplicateTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    override func tearDown() {
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
        super.tearDown()
    }

    func testDuplicateDocumentSendsRequestAndReturnsNewID() async throws {
        let newID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let body = #"{"id": "22222222-2222-4222-8222-222222222222"}"#.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 201, headers: [:], body: body, error: nil) }
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })

        let result = try await client.duplicateDocument(documentID: documentID)

        XCTAssertEqual(result, newID)
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(
            MockURLProtocol.lastRequest?.url?.absoluteString,
            "https://docs.example.org/api/v1.0/documents/11111111-1111-4111-8111-111111111111/duplicate/")
    }
}
