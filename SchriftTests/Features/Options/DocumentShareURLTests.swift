import XCTest

@testable import Schrift

final class DocumentShareURLTests: XCTestCase {
    func testTheDocumentIDIsLowercasedAndTheURLEndsInASlash() {
        // Alphabetic hex: a dropped `.lowercased()` would change the output.
        let id = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEFFFF0000")!
        XCTAssertEqual(
            documentShareURL(serverHost: "docs.example.org", documentID: id)?.absoluteString,
            "https://docs.example.org/docs/aaaaaaaa-bbbb-4ccc-8ddd-eeeeffff0000/")
    }

    func testAHostWithAPortIsKept() {
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let url = documentShareURL(serverHost: "localhost:8080", documentID: id)
        XCTAssertEqual(url?.port, 8080)
        XCTAssertEqual(url?.host, "localhost")
        XCTAssertEqual(url?.scheme, "https")
    }
}
