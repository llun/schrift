import XCTest

@testable import Schrift

final class ListRowTests: XCTestCase {
    func testNormalRowUsesPrimaryColor() {
        XCTAssertEqual(listRowTitleColor(isDestructive: false), .primary)
    }

    func testDestructiveRowUsesDangerColor() {
        XCTAssertEqual(listRowTitleColor(isDestructive: true), .danger)
    }
}
