import XCTest

@testable import Schrift

final class ShareMemberRowTests: XCTestCase {
    func testCurrentUserGetsYouSuffix() {
        XCTAssertEqual(shareMemberDisplaySuffix(isCurrentUser: true, youLabel: "(you)"), "(you)")
    }

    func testOtherUserGetsNoSuffix() {
        XCTAssertNil(shareMemberDisplaySuffix(isCurrentUser: false, youLabel: "(you)"))
    }
}
