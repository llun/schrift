import XCTest

@testable import Schrift

final class ListRowTests: XCTestCase {
    func testNormalRowUsesTextPrimary() {
        XCTAssertEqual(listRowTitleColorHex(isDestructive: false), DocsColorHex.textPrimary)
    }

    func testDestructiveRowUsesDanger() {
        XCTAssertEqual(listRowTitleColorHex(isDestructive: true), DocsColorHex.danger)
    }
}
