import XCTest
@testable import DocsIOS

final class BadgeStyleResolverTests: XCTestCase {
    func testAccentToneUsesBrandSoftColors() {
        XCTAssertEqual(BadgeStyleResolver.style(tone: .accent), BadgeStyleHex(backgroundHex: DocsColorHex.brandFillSoft, foregroundHex: DocsColorHex.textBrandSecondary))
    }

    func testNeutralToneUsesSurfaceMuted() {
        XCTAssertEqual(BadgeStyleResolver.style(tone: .neutral), BadgeStyleHex(backgroundHex: DocsColorHex.surfaceMuted, foregroundHex: DocsColorHex.textSecondary))
    }

    func testDangerToneUsesDangerSoftColors() {
        XCTAssertEqual(BadgeStyleResolver.style(tone: .danger), BadgeStyleHex(backgroundHex: DocsColorHex.dangerSoft, foregroundHex: DocsColorHex.danger))
    }

    func testSuccessToneUsesSuccessSoftColors() {
        XCTAssertEqual(BadgeStyleResolver.style(tone: .success), BadgeStyleHex(backgroundHex: DocsColorHex.successSoft, foregroundHex: DocsColorHex.success))
    }

    func testWarningToneUsesWarningSoftColors() {
        XCTAssertEqual(BadgeStyleResolver.style(tone: .warning), BadgeStyleHex(backgroundHex: DocsColorHex.warningSoft, foregroundHex: DocsColorHex.warning))
    }

    func testInfoToneUsesInfoSoftColors() {
        XCTAssertEqual(BadgeStyleResolver.style(tone: .info), BadgeStyleHex(backgroundHex: DocsColorHex.infoSoft, foregroundHex: DocsColorHex.info))
    }
}
