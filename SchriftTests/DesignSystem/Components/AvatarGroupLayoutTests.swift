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

    // MARK: Face identities

    func testFacesWithoutIdentitiesAreTrackedByPosition() {
        XCTAssertEqual(
            avatarGroupFaces(names: ["A", "B"], identities: nil),
            [AvatarGroupFace(id: 0, name: "A"), AvatarGroupFace(id: 1, name: "B")])
    }

    /// The point of the identities: a collaborator who joins ahead of the others in the list
    /// is a new face, and the existing ones keep theirs — so only the newcomer transitions.
    func testFacesKeepTheirCollaboratorsIdentityWhenSomeoneJoinsAhead() {
        let before = avatarGroupFaces(names: ["B", "C"], identities: [20, 30])
        let after = avatarGroupFaces(names: ["A", "B", "C"], identities: [10, 20, 30])
        XCTAssertEqual(after.map(\.id), [10, 20, 30])
        XCTAssertEqual(before.map(\.id), [20, 30])
        XCTAssertEqual(Set(after.map(\.id)).subtracting(before.map(\.id)), [10])
    }

    func testAShortIdentitiesArrayFallsBackToPositionInsteadOfTrapping() {
        XCTAssertEqual(avatarGroupFaces(names: ["A", "B", "C"], identities: [7]).map(\.id), [7, 1, 2])
        XCTAssertEqual(avatarGroupFaces(names: [], identities: [7]), [])
    }
}
