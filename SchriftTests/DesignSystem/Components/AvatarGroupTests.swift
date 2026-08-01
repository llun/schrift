import XCTest

@testable import Schrift

/// The stack's lengths all come from one diameter, so the thing worth pinning is
/// that they move *together*: a scaled disc beside a fixed overlap is what makes
/// the row come apart at large text sizes.
final class AvatarGroupMetricsTests: XCTestCase {
    func testAtTheDefaultTextSizeTheMetricsAreTheHandoffValues() {
        let metrics = avatarGroupMetrics(size: 32, scale: 1)
        XCTAssertEqual(metrics.diameter, 32)
        XCTAssertEqual(metrics.overlap, -32 * 0.32, accuracy: 0.001)
        XCTAssertEqual(metrics.overflowFontSize, 32 * 0.36, accuracy: 0.001)
    }

    func testEveryLengthScalesByTheSameFactor() {
        let base = avatarGroupMetrics(size: 32, scale: 1)
        let scaled = avatarGroupMetrics(size: 32, scale: 2)
        XCTAssertEqual(scaled.diameter, base.diameter * 2, accuracy: 0.001)
        XCTAssertEqual(scaled.overlap, base.overlap * 2, accuracy: 0.001)
        XCTAssertEqual(scaled.overflowFontSize, base.overflowFontSize * 2, accuracy: 0.001)
    }

    /// The discs overlap, so this is negative by construction — a positive value
    /// would space them apart instead of stacking them.
    func testTheOverlapIsNegativeAtEverySize() {
        for size in [24.0, 32.0, 48.0] as [CGFloat] {
            XCTAssertLessThan(avatarGroupMetrics(size: size, scale: 1.6).overlap, 0)
        }
    }
}

final class AvatarGroupTests: XCTestCase {
    func testFewerNamesThanMaxShowsAllWithNoOverflow() {
        let layout = avatarGroupLayout(names: ["A", "B"], max: 4)
        XCTAssertEqual(layout, AvatarGroupLayout(visibleNames: ["A", "B"], overflowCount: 0))
    }

    func testExactlyMaxNamesShowsAllWithNoOverflow() {
        let layout = avatarGroupLayout(names: ["A", "B", "C", "D"], max: 4)
        XCTAssertEqual(layout, AvatarGroupLayout(visibleNames: ["A", "B", "C", "D"], overflowCount: 0))
    }

    func testMoreNamesThanMaxShowsMaxAvatarsThenOverflowBadge() {
        let layout = avatarGroupLayout(names: ["A", "B", "C", "D", "E"], max: 3)
        XCTAssertEqual(layout, AvatarGroupLayout(visibleNames: ["A", "B", "C"], overflowCount: 2))
    }

    func testLargeOverflowCount() {
        let layout = avatarGroupLayout(names: (1...10).map { "User \($0)" }, max: 3)
        XCTAssertEqual(layout.visibleNames.count, 3)
        XCTAssertEqual(layout.overflowCount, 7)
    }
}
