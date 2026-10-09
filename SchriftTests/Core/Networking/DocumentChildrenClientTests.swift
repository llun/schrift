import XCTest

@testable import Schrift

final class DocumentChildrenClientTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    // Alphabetic hex on purpose: the backend requires the lowercase form.
    private let parentID = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEFFFF0000")!
    private let parentPath = "documents/aaaaaaaa-bbbb-4ccc-8ddd-eeeeffff0000/children/"

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> DocsAPIClient {
        DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
    }

    private static func documentJSON(id: String, title: String) -> String {
        """
        {
            "id": "\(id)",
            "title": "\(title)",
            "excerpt": null,
            "abilities": {},
            "computed_link_reach": "restricted",
            "computed_link_role": null,
            "created_at": "2026-01-15T10:30:00Z",
            "creator": null,
            "depth": 2,
            "link_role": "reader",
            "link_reach": "restricted",
            "numchild": 0,
            "path": "00010001",
            "updated_at": "2026-01-15T10:30:00Z",
            "user_role": "owner"
        }
        """
    }

    func testListChildrenGetsTheLowercasedChildrenPathAndDecodesThePage() async throws {
        let body = """
            {"count": 2, "next": null, "previous": null, "results": [
                \(Self.documentJSON(id: "11111111-1111-4111-8111-111111111111", title: "First")),
                \(Self.documentJSON(id: "22222222-2222-4222-8222-222222222222", title: "Second"))
            ]}
            """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }

        let page = try await makeClient().listChildren(documentID: parentID)

        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "GET")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.absoluteString, baseURL.absoluteString + parentPath)
        XCTAssertEqual(page.results.map(\.title), ["First", "Second"])
        // A create response omits `is_favorite`; the list fixture does too and must still decode.
        XCTAssertEqual(page.results.map(\.isFavorite), [false, false])
    }

    func testListChildrenOfAChildlessDocumentDecodesAnEmptyPage() async throws {
        let body = #"{"count": 0, "next": null, "previous": null, "results": []}"#.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }

        let page = try await makeClient().listChildren(documentID: parentID)

        XCTAssertTrue(page.results.isEmpty)
    }

    func testCreateChildPostsOnlyTheTitleAndDecodesTheNewDocument() async throws {
        let body = Self.documentJSON(id: "33333333-3333-4333-8333-333333333333", title: "Sub page")
            .data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 201, headers: [:], body: body, error: nil) }

        let child = try await makeClient().createChild(documentID: parentID, title: "Sub page")

        XCTAssertEqual(child.id, UUID(uuidString: "33333333-3333-4333-8333-333333333333"))
        XCTAssertEqual(child.title, "Sub page")
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.absoluteString, baseURL.absoluteString + parentPath)
        let sentBody = MockURLProtocol.lastRequest.flatMap(bodyData(from:))
        let json = try XCTUnwrap(sentBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] })
        XCTAssertEqual(json, ["title": "Sub page"])
    }

    func testCreateChildMapsAForbiddenResponse() async {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 403, headers: [:], body: Data(), error: nil) }

        do {
            _ = try await makeClient().createChild(documentID: parentID, title: "x")
            XCTFail("expected a thrown error")
        } catch let error as DocsAPIError {
            XCTAssertEqual(error, .forbidden)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
