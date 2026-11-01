import XCTest

@testable import Schrift

/// The pure pieces of `Skeleton`'s shimmer. That the sweep looks right is a device question;
/// that it stops under Reduce Motion and stays inside one pass is not.
final class SkeletonShimmerTests: XCTestCase {
    func testShimmerIsDisabledUnderReduceMotion() {
        XCTAssertFalse(skeletonShimmerIsEnabled(reduceMotion: true))
        XCTAssertTrue(skeletonShimmerIsEnabled(reduceMotion: false))
    }

    func testPhaseWrapsOncePerPeriod() {
        XCTAssertEqual(skeletonShimmerPhase(at: 0, period: 2), 0, accuracy: 0.0001)
        XCTAssertEqual(skeletonShimmerPhase(at: 0.5, period: 2), 0.25, accuracy: 0.0001)
        XCTAssertEqual(skeletonShimmerPhase(at: 2, period: 2), 0, accuracy: 0.0001)
        XCTAssertEqual(skeletonShimmerPhase(at: 3, period: 2), 0.5, accuracy: 0.0001)
    }

    func testPhaseIsAlwaysWithinOnePass() {
        for time in stride(from: -5.0, through: 5.0, by: 0.37) {
            let phase = skeletonShimmerPhase(at: time)
            XCTAssertGreaterThanOrEqual(phase, 0)
            XCTAssertLessThan(phase, 1)
        }
    }

    func testAZeroPeriodHasNoPhase() {
        XCTAssertEqual(skeletonShimmerPhase(at: 3, period: 0), 0)
    }

    func testEveryBarReadsTheSameClockSoTheyShimmerTogether() {
        XCTAssertEqual(skeletonShimmerPhase(at: 123.4), skeletonShimmerPhase(at: 123.4))
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
