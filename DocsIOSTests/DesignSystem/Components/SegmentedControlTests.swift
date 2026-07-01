import XCTest
@testable import DocsIOS

final class SegmentedControlTests: XCTestCase {
    func testFirstOfThreeSegmentsHasZeroOffset() {
        let layout = segmentedControlLayout(segmentCount: 3, selectedIndex: 0)
        XCTAssertEqual(layout.segmentFraction, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(layout.thumbOffsetFraction, 0.0, accuracy: 0.0001)
    }

    func testMiddleOfThreeSegments() {
        let layout = segmentedControlLayout(segmentCount: 3, selectedIndex: 1)
        XCTAssertEqual(layout.thumbOffsetFraction, 1.0 / 3.0, accuracy: 0.0001)
    }

    func testLastOfFourSegments() {
        let layout = segmentedControlLayout(segmentCount: 4, selectedIndex: 3)
        XCTAssertEqual(layout.segmentFraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(layout.thumbOffsetFraction, 0.75, accuracy: 0.0001)
    }

    func testOutOfRangeIndexIsClampedToLastSegment() {
        let layout = segmentedControlLayout(segmentCount: 3, selectedIndex: 99)
        XCTAssertEqual(layout.thumbOffsetFraction, 2.0 / 3.0, accuracy: 0.0001)
    }

    func testNegativeIndexIsClampedToFirstSegment() {
        let layout = segmentedControlLayout(segmentCount: 3, selectedIndex: -5)
        XCTAssertEqual(layout.thumbOffsetFraction, 0.0, accuracy: 0.0001)
    }

    func testZeroSegmentsReturnsZeroedLayout() {
        let layout = segmentedControlLayout(segmentCount: 0, selectedIndex: 0)
        XCTAssertEqual(layout, SegmentedControlLayout(segmentFraction: 0, thumbOffsetFraction: 0))
    }
}
