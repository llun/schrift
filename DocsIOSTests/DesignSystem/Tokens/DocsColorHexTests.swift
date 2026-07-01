import XCTest
@testable import DocsIOS

final class DocsColorHexTests: XCTestCase {
    func testBrandTokensMatchDesignSpec() {
        XCTAssertEqual(DocsColorHex.brandFill, 0x5E5CD0)
        XCTAssertEqual(DocsColorHex.brandFillHover, 0x4844AD)
        XCTAssertEqual(DocsColorHex.brandFillSoft, 0xDDE2F5)
        XCTAssertEqual(DocsColorHex.brandFillSubtle, 0xEEF1FA)
        XCTAssertEqual(DocsColorHex.textBrand, 0x3E3B98)
        XCTAssertEqual(DocsColorHex.textBrandSecondary, 0x534FC2)
    }

    func testTextTokensMatchDesignSpec() {
        XCTAssertEqual(DocsColorHex.textPrimary, 0x25252F)
        XCTAssertEqual(DocsColorHex.textSecondary, 0x5D5D70)
        XCTAssertEqual(DocsColorHex.textTertiary, 0x69697D)
        XCTAssertEqual(DocsColorHex.textDisabled, 0xA9A9BF)
        XCTAssertEqual(DocsColorHex.textOnBrand, 0xFFFFFF)
    }

    func testSurfaceTokensMatchDesignSpec() {
        XCTAssertEqual(DocsColorHex.surfacePage, 0xFFFFFF)
        XCTAssertEqual(DocsColorHex.surfaceSunken, 0xF8F8F9)
        XCTAssertEqual(DocsColorHex.surfaceMuted, 0xF0F0F3)
    }

    func testBorderTokensMatchDesignSpec() {
        XCTAssertEqual(DocsColorHex.borderDefault, 0xE2E2EA)
        XCTAssertEqual(DocsColorHex.borderStrong, 0xD3D4E0)
        XCTAssertEqual(DocsColorHex.borderFocus, 0x8184FC)
    }

    func testFeedbackTokensMatchDesignSpec() {
        XCTAssertEqual(DocsColorHex.info, 0x0069CF)
        XCTAssertEqual(DocsColorHex.success, 0x027B3E)
        XCTAssertEqual(DocsColorHex.warning, 0xBC4200)
        XCTAssertEqual(DocsColorHex.danger, 0xD7010E)
    }

    func testFeedbackSoftTokensMatchDesignSpec() {
        XCTAssertEqual(DocsColorHex.infoSoft, 0xD5E4F3)
        XCTAssertEqual(DocsColorHex.successSoft, 0xCFE4D4)
        XCTAssertEqual(DocsColorHex.warningSoft, 0xF1E0D3)
        XCTAssertEqual(DocsColorHex.dangerSoft, 0xF4DFD9)
    }
}
