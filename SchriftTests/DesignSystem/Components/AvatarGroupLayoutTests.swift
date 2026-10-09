import XCTest

@testable import Schrift

/// Kept apart from `AvatarGroupTests` so the regression lives in its own file.
final class AvatarGroupLayoutTests: XCTestCase {
    /// `prefix(_:)` traps on a negative length, so before the clamp this crashed
    /// the process instead of returning.
    func testANegativeMaxShowsNoAvatarsAndCountsEveryNameAsOverflow() {
        XCTAssertEqual(
            avatarGroupLayout(names: ["A", "B", "C"], max: -1), AvatarGroupLayout(visibleNames: [], overflowCount: 3))
        XCTAssertEqual(
            avatarGroupLayout(names: ["A"], max: Int.min), AvatarGroupLayout(visibleNames: [], overflowCount: 1))
    }

    func testANegativeMaxWithNoNamesShowsNothing() {
        XCTAssertEqual(avatarGroupLayout(names: [], max: -5), AvatarGroupLayout(visibleNames: [], overflowCount: 0))
    }
}
