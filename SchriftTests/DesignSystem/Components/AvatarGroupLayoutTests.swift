import XCTest

@testable import Schrift

/// The out-of-range `max` cases for `avatarGroupLayout`; the in-range ones live in `AvatarGroupTests`.
final class AvatarGroupLayoutTests: XCTestCase {
    /// `prefix(_:)` traps on a negative length, so before the clamp this crashed
    /// the process instead of returning.
    func testANegativeMaxShowsNoAvatarsAndCountsEveryNameAsOverflow() {
        XCTAssertEqual(
            avatarGroupLayout(names: ["A", "B", "C"], max: -1), AvatarGroupLayout(visibleNames: [], overflowCount: 3))
        XCTAssertEqual(
            avatarGroupLayout(names: ["A"], max: Int.min), AvatarGroupLayout(visibleNames: [], overflowCount: 1))
    }

    /// The boundary a negative `max` is clamped onto.
    func testAZeroMaxShowsNoAvatarsAndCountsEveryNameAsOverflow() {
        XCTAssertEqual(
            avatarGroupLayout(names: ["A", "B"], max: 0), AvatarGroupLayout(visibleNames: [], overflowCount: 2))
    }

    func testANegativeMaxWithNoNamesShowsNothing() {
        XCTAssertEqual(avatarGroupLayout(names: [], max: -5), AvatarGroupLayout(visibleNames: [], overflowCount: 0))
    }
}
