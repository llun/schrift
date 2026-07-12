import XCTest

@testable import Schrift

final class HomeListPlaceholderTests: XCTestCase {
    func testLoadingPlaceholderShownOnlyOnFirstEverRun() {
        XCTAssertTrue(shouldShowLoadingPlaceholder(hasCachedList: false, visibleRowCount: 0))
    }

    func testLoadingPlaceholderHiddenWhenListWasCached() {
        // A cached empty list is a real fetch result — no spinner.
        XCTAssertFalse(shouldShowLoadingPlaceholder(hasCachedList: true, visibleRowCount: 0))
    }

    func testLoadingPlaceholderHiddenWhenRowsAreOnScreen() {
        XCTAssertFalse(shouldShowLoadingPlaceholder(hasCachedList: false, visibleRowCount: 2))
    }
}
