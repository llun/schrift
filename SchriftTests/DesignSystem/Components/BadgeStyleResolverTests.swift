import XCTest

@testable import Schrift

final class BadgeStyleResolverTests: XCTestCase {
    func testAccentToneUsesBrandSoftColors() {
        let s = BadgeStyleResolver.style(tone: .accent)
        XCTAssertEqual(s.backgroundLightHex, DocsColorHex.brandFillSoft)
        XCTAssertEqual(s.foregroundLightHex, DocsColorHex.textBrandSecondary)
    }

    func testNeutralToneFlipsForegroundLightInDark() {
        let s = BadgeStyleResolver.style(tone: .neutral)
        XCTAssertEqual(s.backgroundLightHex, DocsColorHex.gray100)
        XCTAssertEqual(s.backgroundDarkHex, DocsColorHexDark.gray100)
        XCTAssertEqual(s.foregroundLightHex, DocsColorHex.gray600)
        XCTAssertEqual(s.foregroundDarkHex, DocsColorHexDark.gray600)
    }

    func testDangerToneUsesDangerSoftWithStrongInk() {
        let s = BadgeStyleResolver.style(tone: .danger)
        XCTAssertEqual(s.backgroundLightHex, DocsColorHex.dangerSoft)
        XCTAssertEqual(s.foregroundLightHex, DocsColorHex.dangerStrong)
    }

    func testSuccessToneCarriesLightAndDark() {
        let s = BadgeStyleResolver.style(tone: .success)
        XCTAssertEqual(s.backgroundLightHex, DocsColorHex.successSoft)
        XCTAssertEqual(s.backgroundDarkHex, DocsColorHexDark.successSoft)
        XCTAssertEqual(s.foregroundLightHex, DocsColorHex.success650)
        XCTAssertEqual(s.foregroundDarkHex, DocsColorHexDark.success650)
    }

    func testWarningToneUsesWarningSoftWith650Ink() {
        let s = BadgeStyleResolver.style(tone: .warning)
        XCTAssertEqual(s.backgroundLightHex, DocsColorHex.warningSoft)
        XCTAssertEqual(s.foregroundLightHex, DocsColorHex.warning650)
    }

    func testInfoToneUsesInfoSoftWith650Ink() {
        let s = BadgeStyleResolver.style(tone: .info)
        XCTAssertEqual(s.backgroundLightHex, DocsColorHex.infoSoft)
        XCTAssertEqual(s.foregroundLightHex, DocsColorHex.info650)
    }
}
