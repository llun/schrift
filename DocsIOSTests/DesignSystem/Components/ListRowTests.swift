import XCTest
@testable import DocsIOS

final class ListRowTests: XCTestCase {
    func testNormalRowUsesTextPrimary() {
        XCTAssertEqual(listRowTitleColorHex(isDestructive: false), DocsColorHex.textPrimary)
    }

    func testDestructiveRowUsesDanger() {
        XCTAssertEqual(listRowTitleColorHex(isDestructive: true), DocsColorHex.danger)
    }
}
