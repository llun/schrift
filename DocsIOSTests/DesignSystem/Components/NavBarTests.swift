import XCTest
@testable import DocsIOS

final class NavBarTests: XCTestCase {
    func testStandardHeightUsesNavBarHeight() {
        XCTAssertEqual(navBarHeight(largeTitle: false), DocsSpacing.navBarHeight)
    }

    func testLargeTitleHeightUsesLargeTitleBarHeight() {
        XCTAssertEqual(navBarHeight(largeTitle: true), DocsSpacing.largeTitleBarHeight)
    }
}
