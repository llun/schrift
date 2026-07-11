import XCTest

@testable import Schrift

final class ShareSheetLayoutTests: XCTestCase {
    func testMembersMaxHeightIs208() {
        XCTAssertEqual(ShareSheetLayout.membersMaxHeight, 208)
    }
}
