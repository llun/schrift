import XCTest

@testable import Schrift

final class DocumentMoveClientTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    // Alphabetic hex on purpose: an all-digit UUID would pass these assertions even if the
    // endpoint forgot `.lowercased()`, and the backend requires the lowercase form.
    private let documentID = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEFFFF0000")!
    private let targetID = UUID(uuidString: "BBBBBBBB-CCCC-4DDD-8EEE-FFFF00001111")!

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> DocsAPIClient {
        DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
    }

    private func stubMoveSuccess() {
        let responseBody = #"{"message": "Document moved successfully."}"#.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: responseBody, error: nil) }
    }

    func testMoveDocumentPostsToLowercasedMovePathWithTrailingSlash() async throws {
        stubMoveSuccess()

        try await makeClient().moveDocument(
            documentID: documentID, targetDocumentID: targetID, position: .lastChild)

        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(
            MockURLProtocol.lastRequest?.url?.absoluteString,
            "https://docs.example.org/api/v1.0/documents/aaaaaaaa-bbbb-4ccc-8ddd-eeeeffff0000/move/")
    }

    func testMoveDocumentBodySendsSnakeCaseTargetAndPosition() async throws {
        stubMoveSuccess()

        try await makeClient().moveDocument(
            documentID: documentID, targetDocumentID: targetID, position: .lastChild)

        let sentBody = MockURLProtocol.lastRequest.flatMap(bodyData(from:))
        let json = try XCTUnwrap(sentBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] })
        XCTAssertEqual(json["target_document_id"], "bbbbbbbb-cccc-4ddd-8eee-ffff00001111")
        XCTAssertEqual(json["position"], "last-child")
    }

    func testMoveDocumentSendsTheSiblingPositionThatPromotesToRoot() async throws {
        stubMoveSuccess()

        try await makeClient().moveDocument(
            documentID: documentID, targetDocumentID: targetID, position: .lastSibling)

        let sentBody = MockURLProtocol.lastRequest.flatMap(bodyData(from:))
        let json = try XCTUnwrap(sentBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] })
        XCTAssertEqual(json["position"], "last-sibling")
    }

    func testEveryPositionSpellsItsBackendWireValue() {
        // These raw values are the backend's `MoveNodePositionChoices`; a rename here would be
        // a 400 at runtime, which no other test in this file would catch.
        XCTAssertEqual(DocumentMovePosition.firstChild.rawValue, "first-child")
        XCTAssertEqual(DocumentMovePosition.lastChild.rawValue, "last-child")
        XCTAssertEqual(DocumentMovePosition.firstSibling.rawValue, "first-sibling")
        XCTAssertEqual(DocumentMovePosition.lastSibling.rawValue, "last-sibling")
        XCTAssertEqual(DocumentMovePosition.left.rawValue, "left")
        XCTAssertEqual(DocumentMovePosition.right.rawValue, "right")
    }

    func testMoveDocumentAcceptsTheAcknowledgementBodyWithoutDecodingIt() async throws {
        stubMoveSuccess()

        // `sendVoid`, so the `{"message": …}` payload must not be decoded into anything.
        try await makeClient().moveDocument(
            documentID: documentID, targetDocumentID: targetID, position: .lastChild)
    }

    func testMoveDocumentSurfacesARejectionAsAServerError() async throws {
        // Every move rejection — no permission, unknown target, move into own descendant — is
        // a 400 carrying `{"target_document_id": …}`, not a 403/404.
        let responseBody = #"{"target_document_id": "Cannot move a document to its own descendant."}"#
            .data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 400, headers: [:], body: responseBody, error: nil) }

        do {
            try await makeClient().moveDocument(
                documentID: documentID, targetDocumentID: targetID, position: .lastChild)
            XCTFail("Expected the move to throw")
        } catch let error as DocsAPIError {
            XCTAssertEqual(error, .server(statusCode: 400))
        }
    }
}
