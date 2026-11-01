import XCTest

@testable import Schrift

final class SearchSkeletonTests: XCTestCase {
    func testSkeletonShowsWhileSearchingWithNothingToShow() {
        XCTAssertTrue(searchShowsSkeleton(isSearching: true, hasResults: false))
    }

    func testPreviousResultsStayWhileRefining() {
        XCTAssertFalse(searchShowsSkeleton(isSearching: true, hasResults: true))
    }

    func testNoSkeletonWhenIdle() {
        XCTAssertFalse(searchShowsSkeleton(isSearching: false, hasResults: false))
        XCTAssertFalse(searchShowsSkeleton(isSearching: false, hasResults: true))
    }
}
