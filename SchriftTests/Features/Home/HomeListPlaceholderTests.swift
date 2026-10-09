import XCTest

@testable import Schrift

final class HomeListPlaceholderTests: XCTestCase {
    /// The skeleton stands in only for a first load with nothing cached and nothing on screen. A cached
    /// empty list is a real fetch result, so it gets no placeholder.
    func testLoadingPlaceholderShowsOnlyWithNeitherACachedListNorVisibleRows() {
        let cases: [(hasCachedList: Bool, visibleRowCount: Int, shown: Bool)] = [
            (false, 0, true),
            (true, 0, false),
            (false, 2, false),
            (true, 2, false),
        ]
        for testCase in cases {
            XCTAssertEqual(
                shouldShowLoadingPlaceholder(
                    hasCachedList: testCase.hasCachedList, visibleRowCount: testCase.visibleRowCount),
                testCase.shown, "\(testCase)")
        }
    }
}
