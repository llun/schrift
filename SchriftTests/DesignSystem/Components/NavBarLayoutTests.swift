import XCTest

@testable import Schrift

final class NavBarLayoutTests: XCTestCase {
    func testLargeTitleWithoutBackOrLeadingCollapsesTopRow() {
        XCTAssertFalse(navBarShowsTopRow(largeTitle: true, hasBack: false, hasLeading: false))
    }

    func testLargeTitleWithBackShowsTopRow() {
        XCTAssertTrue(navBarShowsTopRow(largeTitle: true, hasBack: true, hasLeading: false))
    }

    func testLargeTitleWithLeadingShowsTopRow() {
        XCTAssertTrue(navBarShowsTopRow(largeTitle: true, hasBack: false, hasLeading: true))
    }

    func testStandardModeAlwaysShowsTopRow() {
        XCTAssertTrue(navBarShowsTopRow(largeTitle: false, hasBack: false, hasLeading: false))
    }
}
