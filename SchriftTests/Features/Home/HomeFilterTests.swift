import XCTest

@testable import Schrift

final class HomeFilterTests: XCTestCase {
    func testAllFilterHasNoQueryParameters() {
        XCTAssertEqual(homeFilterQueryParameters(.all), HomeFilterQueryParameters(isFavorite: nil, isCreatorMe: nil))
    }

    func testSharedFilterExcludesDocumentsCreatedByMe() {
        XCTAssertEqual(
            homeFilterQueryParameters(.shared), HomeFilterQueryParameters(isFavorite: nil, isCreatorMe: false))
    }

    func testPinnedFilterOnlyIncludesFavorites() {
        XCTAssertEqual(
            homeFilterQueryParameters(.pinned), HomeFilterQueryParameters(isFavorite: true, isCreatorMe: nil))
    }

    func testPinnedSectionHiddenWhenFilterIsPinned() {
        XCTAssertFalse(shouldShowPinnedSection(filter: .pinned, pinnedCount: 3))
    }

    func testPinnedSectionHiddenWhenNoPinnedDocuments() {
        XCTAssertFalse(shouldShowPinnedSection(filter: .all, pinnedCount: 0))
    }

    func testPinnedSectionShownForAllFilterWithPinnedDocuments() {
        XCTAssertTrue(shouldShowPinnedSection(filter: .all, pinnedCount: 2))
    }

    func testPinnedSectionShownForSharedFilterWithPinnedDocuments() {
        XCTAssertTrue(shouldShowPinnedSection(filter: .shared, pinnedCount: 1))
    }

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
