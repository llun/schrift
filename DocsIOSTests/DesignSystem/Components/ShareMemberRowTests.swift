import XCTest
@testable import DocsIOS

final class ShareMemberRowTests: XCTestCase {
    func testCurrentUserGetsYouSuffix() {
        XCTAssertEqual(shareMemberDisplaySuffix(isCurrentUser: true), "(you)")
    }

    func testOtherUserGetsNoSuffix() {
        XCTAssertNil(shareMemberDisplaySuffix(isCurrentUser: false))
    }
}
