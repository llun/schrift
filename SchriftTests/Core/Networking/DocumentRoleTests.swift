import XCTest
@testable import Schrift

final class DocumentRoleTests: XCTestCase {
    func testDocumentRoleRawValuesMatchBackendAPIStrings() {
        XCTAssertEqual(DocumentRole.reader.rawValue, "reader")
        XCTAssertEqual(DocumentRole.commenter.rawValue, "commenter")
        XCTAssertEqual(DocumentRole.editor.rawValue, "editor")
        XCTAssertEqual(DocumentRole.administrator.rawValue, "administrator")
        XCTAssertEqual(DocumentRole.owner.rawValue, "owner")
    }

    func testLinkRoleRawValuesMatchBackendAPIStrings() {
        XCTAssertEqual(LinkRole.reader.rawValue, "reader")
        XCTAssertEqual(LinkRole.commenter.rawValue, "commenter")
        XCTAssertEqual(LinkRole.editor.rawValue, "editor")
    }
}
