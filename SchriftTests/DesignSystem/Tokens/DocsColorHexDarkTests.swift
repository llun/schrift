import XCTest

@testable import Schrift

final class DocsColorHexDarkTests: XCTestCase {
    func testDarkBrandTokensMatchDesignSpec() {
        XCTAssertEqual(DocsColorHexDark.brandFill, 0x7B79E8)
        XCTAssertEqual(DocsColorHexDark.brandFillHover, 0x8F8DF2)
        XCTAssertEqual(DocsColorHexDark.brandFillSoft, 0x2C2C50)
        XCTAssertEqual(DocsColorHexDark.brandFillSubtle, 0x1E1E33)
        XCTAssertEqual(DocsColorHexDark.textBrand, 0xA9ADF9)
        XCTAssertEqual(DocsColorHexDark.textBrandSecondary, 0x9195FC)
    }

    func testDarkTextTokensMatchDesignSpec() {
        XCTAssertEqual(DocsColorHexDark.textPrimary, 0xF4F4F6)
        XCTAssertEqual(DocsColorHexDark.textSecondary, 0xB4B4C6)
        XCTAssertEqual(DocsColorHexDark.textTertiary, 0x9494AA)
        XCTAssertEqual(DocsColorHexDark.textDisabled, 0x5A5A6B)
        XCTAssertEqual(DocsColorHexDark.textOnBrand, 0xFFFFFF)
    }

    func testDarkSurfaceTokensMatchDesignSpec() {
        XCTAssertEqual(DocsColorHexDark.surfacePage, 0x16161C)
        XCTAssertEqual(DocsColorHexDark.surfaceSunken, 0x0E0E13)
        XCTAssertEqual(DocsColorHexDark.surfaceMuted, 0x2A2A34)
        XCTAssertEqual(DocsColorHexDark.surfaceRaised, 0x202028)
        XCTAssertEqual(DocsColorHexDark.surfaceScrim, 0x000000)
    }

    func testDarkBorderTokensMatchDesignSpec() {
        XCTAssertEqual(DocsColorHexDark.borderDefault, 0x2E2E38)
        XCTAssertEqual(DocsColorHexDark.borderStrong, 0x3C3C48)
        XCTAssertEqual(DocsColorHexDark.borderFocus, 0x9CA0FF)
    }

    func testDarkFeedbackTokensMatchDesignSpec() {
        XCTAssertEqual(DocsColorHexDark.info, 0x5AA9F0)
        XCTAssertEqual(DocsColorHexDark.success, 0x4FB878)
        XCTAssertEqual(DocsColorHexDark.warning, 0xE6915F)
        XCTAssertEqual(DocsColorHexDark.danger, 0xF4796E)
    }

    func testDarkFeedbackSoftTokensMatchDesignSpec() {
        XCTAssertEqual(DocsColorHexDark.infoSoft, 0x12283F)
        XCTAssertEqual(DocsColorHexDark.successSoft, 0x12301E)
        XCTAssertEqual(DocsColorHexDark.warningSoft, 0x35220F)
        XCTAssertEqual(DocsColorHexDark.dangerSoft, 0x3A1A17)
    }

    func testDarkFeedbackStrongTokensMatchDesignSpec() {
        XCTAssertEqual(DocsColorHexDark.dangerStrong, 0xF4796E)
        XCTAssertEqual(DocsColorHexDark.info650, 0x5AA9F0)
        XCTAssertEqual(DocsColorHexDark.success650, 0x4FB878)
        XCTAssertEqual(DocsColorHexDark.warning650, 0xE6915F)
    }

    func testDarkBrandLogoMatchesDesignSpec() {
        XCTAssertEqual(DocsColorHexDark.brandLogo, 0x7C79F2)
    }

    func testDarkGrayRampMatchesDesignSpec() {
        XCTAssertEqual(DocsColorHexDark.gray050, 0x202028)
        XCTAssertEqual(DocsColorHexDark.gray100, 0x2E2E38)
        XCTAssertEqual(DocsColorHexDark.gray300, 0x565663)
        XCTAssertEqual(DocsColorHexDark.gray350, 0x6C6C80)
        XCTAssertEqual(DocsColorHexDark.gray450, 0x8A8A9E)
        XCTAssertEqual(DocsColorHexDark.gray600, 0xB7B7CB)
    }

    func testAccentPaletteIsUnchangedInDark() {
        XCTAssertEqual(DocsColorHexDark.accentOrange, DocsColorHex.accentOrange)
        XCTAssertEqual(DocsColorHexDark.accentBrown, DocsColorHex.accentBrown)
        XCTAssertEqual(DocsColorHexDark.accentGreen, DocsColorHex.accentGreen)
        XCTAssertEqual(DocsColorHexDark.accentBlue1, DocsColorHex.accentBlue1)
        XCTAssertEqual(DocsColorHexDark.accentBlue2, DocsColorHex.accentBlue2)
        XCTAssertEqual(DocsColorHexDark.accentPurple, DocsColorHex.accentPurple)
        XCTAssertEqual(DocsColorHexDark.accentPink, DocsColorHex.accentPink)
    }
}
