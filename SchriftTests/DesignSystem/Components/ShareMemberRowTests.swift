import XCTest

@testable import Schrift

final class ShareMemberRowTests: XCTestCase {
    func testOnlyTheCurrentUserGetsTheYouSuffix() {
        XCTAssertEqual(shareMemberDisplaySuffix(isCurrentUser: true, youLabel: "(you)"), "(you)")
        XCTAssertNil(shareMemberDisplaySuffix(isCurrentUser: false, youLabel: "(you)"))
    }
}
