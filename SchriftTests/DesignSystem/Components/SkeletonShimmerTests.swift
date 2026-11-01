import CoreGraphics
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

    /// The band is laid out as wide as the bar; the transform squeezes it to `bandFraction` and slides
    /// it, so at phase 0 it sits just before the leading edge and at phase 1 just past the trailing one.
    func testTheBandTransformSqueezesTheBandAndSweepsItAcrossTheBar() {
        let width: CGFloat = 200
        let start = skeletonShimmerBandTransform(phase: 0, width: width, bandFraction: 0.5)
        XCTAssertEqual(CGPoint(x: 0, y: 0).applying(start).x, -100, accuracy: 0.0001)
        XCTAssertEqual(CGPoint(x: width, y: 0).applying(start).x, 0, accuracy: 0.0001)

        let end = skeletonShimmerBandTransform(phase: 1, width: width, bandFraction: 0.5)
        XCTAssertEqual(CGPoint(x: 0, y: 0).applying(end).x, width, accuracy: 0.0001)
        XCTAssertEqual(CGPoint(x: width, y: 0).applying(end).x, 300, accuracy: 0.0001)
    }

    /// Vertical placement is untouched; only x moves.
    func testTheBandTransformLeavesYAlone() {
        let transform = skeletonShimmerBandTransform(phase: 0.5, width: 120)
        XCTAssertEqual(CGPoint(x: 10, y: 7).applying(transform).y, 7, accuracy: 0.0001)
    }

    /// The transform is computed from the size the band has right now, so a bar that widens mid-sweep
    /// is still crossed edge to edge at the same phase, and a zero-width bar (layout not settled yet)
    /// gives a degenerate but finite transform rather than a stuck one.
    func testTheBandTransformFollowsTheLiveWidth() {
        let narrow = skeletonShimmerBandTransform(phase: 1, width: 100)
        let wide = skeletonShimmerBandTransform(phase: 1, width: 300)
        XCTAssertEqual(CGPoint(x: 0, y: 0).applying(narrow).x, 100, accuracy: 0.0001)
        XCTAssertEqual(CGPoint(x: 0, y: 0).applying(wide).x, 300, accuracy: 0.0001)

        let empty = skeletonShimmerBandTransform(phase: 0.5, width: 0)
        XCTAssertEqual(empty.tx, 0, accuracy: 0.0001)
        XCTAssertTrue(empty.a.isFinite)
    }
}
