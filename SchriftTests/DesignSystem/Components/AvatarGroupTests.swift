import XCTest
@testable import Schrift

final class AvatarGroupTests: XCTestCase {
    func testFewerNamesThanMaxShowsAllWithNoOverflow() {
        let layout = avatarGroupLayout(names: ["A", "B"], max: 4)
        XCTAssertEqual(layout, AvatarGroupLayout(visibleNames: ["A", "B"], overflowCount: 0))
    }

    func testExactlyMaxNamesShowsAllWithNoOverflow() {
        let layout = avatarGroupLayout(names: ["A", "B", "C", "D"], max: 4)
        XCTAssertEqual(layout, AvatarGroupLayout(visibleNames: ["A", "B", "C", "D"], overflowCount: 0))
    }

    func testMoreNamesThanMaxReservesLastSlotForOverflowBadge() {
        let layout = avatarGroupLayout(names: ["A", "B", "C", "D", "E"], max: 3)
        XCTAssertEqual(layout, AvatarGroupLayout(visibleNames: ["A", "B"], overflowCount: 3))
    }

    func testLargeOverflowCount() {
        let layout = avatarGroupLayout(names: (1...10).map { "User \($0)" }, max: 3)
        XCTAssertEqual(layout.visibleNames.count, 2)
        XCTAssertEqual(layout.overflowCount, 8)
    }
}
