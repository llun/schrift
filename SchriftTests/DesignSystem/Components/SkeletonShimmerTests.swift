import XCTest

@testable import Schrift

/// The pure pieces of `Skeleton`'s shimmer. That the sweep looks right is a device question;
/// that it stops under Reduce Motion and stays inside one pass is not.
final class SkeletonShimmerTests: XCTestCase {
    func testShimmerIsDisabledUnderReduceMotion() {
        XCTAssertFalse(skeletonShimmerIsEnabled(reduceMotion: true))
        XCTAssertTrue(skeletonShimmerIsEnabled(reduceMotion: false))
    }

    func testTheBandStartsOffTheLeadingEdgeAndEndsOffTheTrailingEdge() {
        let width: CGFloat = 100
        let band = width * 0.6
        XCTAssertEqual(skeletonShimmerBandOffset(phase: 0, width: width, bandFraction: 0.6), -band, accuracy: 0.0001)
        XCTAssertEqual(skeletonShimmerBandOffset(phase: 1, width: width, bandFraction: 0.6), width, accuracy: 0.0001)
    }

    func testTheBandMovesForwardThroughThePass() {
        let early = skeletonShimmerBandOffset(phase: 0.2, width: 80)
        let late = skeletonShimmerBandOffset(phase: 0.8, width: 80)
        XCTAssertLessThan(early, late)
    }
}
