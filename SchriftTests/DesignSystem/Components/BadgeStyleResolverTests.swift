import XCTest

@testable import Schrift

final class BadgeStyleResolverTests: XCTestCase {
    func testAccentToneUsesBrandSoftColors() {
        XCTAssertEqual(
            BadgeStyleResolver.style(tone: .accent),
            BadgeStyleHex(backgroundHex: DocsColorHex.brandFillSoft, foregroundHex: DocsColorHex.textBrandSecondary))
    }

    func testNeutralToneUsesGrayHundredWithGraySixHundredInk() {
        XCTAssertEqual(
            BadgeStyleResolver.style(tone: .neutral),
            BadgeStyleHex(backgroundHex: DocsColorHex.gray100, foregroundHex: DocsColorHex.gray600))
    }

    func testDangerToneUsesDangerSoftWithStrongInk() {
        XCTAssertEqual(
            BadgeStyleResolver.style(tone: .danger),
            BadgeStyleHex(backgroundHex: DocsColorHex.dangerSoft, foregroundHex: DocsColorHex.dangerStrong))
    }

    func testSuccessToneUsesSuccessSoftWith650Ink() {
        XCTAssertEqual(
            BadgeStyleResolver.style(tone: .success),
            BadgeStyleHex(backgroundHex: DocsColorHex.successSoft, foregroundHex: DocsColorHex.success650))
    }

    func testWarningToneUsesWarningSoftWith650Ink() {
        XCTAssertEqual(
            BadgeStyleResolver.style(tone: .warning),
            BadgeStyleHex(backgroundHex: DocsColorHex.warningSoft, foregroundHex: DocsColorHex.warning650))
    }

    func testInfoToneUsesInfoSoftWith650Ink() {
        XCTAssertEqual(
            BadgeStyleResolver.style(tone: .info),
            BadgeStyleHex(backgroundHex: DocsColorHex.infoSoft, foregroundHex: DocsColorHex.info650))
    }
}
