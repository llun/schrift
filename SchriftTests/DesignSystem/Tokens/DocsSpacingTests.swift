import XCTest

@testable import Schrift

final class DocsSpacingTests: XCTestCase {
    func testDesignScaleMatchesSpec() {
        XCTAssertEqual(DocsSpacing.space4xs, 2)
        XCTAssertEqual(DocsSpacing.space3xs, 4)
        XCTAssertEqual(DocsSpacing.space2xs, 6)
        XCTAssertEqual(DocsSpacing.spaceXS, 8)
        XCTAssertEqual(DocsSpacing.spaceSM, 12)
        XCTAssertEqual(DocsSpacing.spaceBase, 16)
        XCTAssertEqual(DocsSpacing.spaceMD, 24)
        XCTAssertEqual(DocsSpacing.spaceLG, 32)
        XCTAssertEqual(DocsSpacing.spaceXL, 40)
        XCTAssertEqual(DocsSpacing.space2XL, 48)
        XCTAssertEqual(DocsSpacing.space3XL, 56)
        XCTAssertEqual(DocsSpacing.space4XL, 64)
        XCTAssertEqual(DocsSpacing.space5XL, 72)
    }

    func testIOSLayoutConstantsMatchSpec() {
        XCTAssertEqual(DocsSpacing.statusBarHeight, 54)
        XCTAssertEqual(DocsSpacing.navBarHeight, 44)
        XCTAssertEqual(DocsSpacing.largeTitleBarHeight, 96)
        XCTAssertEqual(DocsSpacing.tabBarHeight, 49)
        XCTAssertEqual(DocsSpacing.homeIndicatorHeight, 34)
        XCTAssertEqual(DocsSpacing.rowMinHeight, 44)
        XCTAssertEqual(DocsSpacing.toolbarHeight, 44)
        XCTAssertEqual(DocsSpacing.gutter, 16)
        XCTAssertEqual(DocsSpacing.gutterGrouped, 20)
    }
}
