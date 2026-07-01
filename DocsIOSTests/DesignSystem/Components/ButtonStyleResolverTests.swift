import XCTest
@testable import DocsIOS

final class ButtonStyleResolverTests: XCTestCase {
    func testPrimaryBrandUsesFillBackground() {
        let style = ButtonStyleResolver.style(variant: .primary, color: .brand, isDisabled: false)
        XCTAssertEqual(style, ButtonStyleHex(backgroundHex: DocsColorHex.brandFill, foregroundHex: DocsColorHex.textOnBrand, borderHex: nil))
    }

    func testSecondaryBrandUsesSoftBackground() {
        let style = ButtonStyleResolver.style(variant: .secondary, color: .brand, isDisabled: false)
        XCTAssertEqual(style, ButtonStyleHex(backgroundHex: DocsColorHex.brandFillSoft, foregroundHex: DocsColorHex.textBrandSecondary, borderHex: nil))
    }

    func testTertiaryHasNoBackground() {
        let style = ButtonStyleResolver.style(variant: .tertiary, color: .brand, isDisabled: false)
        XCTAssertNil(style.backgroundHex)
        XCTAssertEqual(style.foregroundHex, DocsColorHex.textBrandSecondary)
    }

    func testOutlineHasMatchingBorderAndForeground() {
        let style = ButtonStyleResolver.style(variant: .outline, color: .danger, isDisabled: false)
        XCTAssertNil(style.backgroundHex)
        XCTAssertEqual(style.foregroundHex, DocsColorHex.danger)
        XCTAssertEqual(style.borderHex, DocsColorHex.danger)
    }

    func testDisabledIgnoresVariantAndColor() {
        let style = ButtonStyleResolver.style(variant: .primary, color: .danger, isDisabled: true)
        XCTAssertEqual(style, ButtonStyleHex(backgroundHex: DocsColorHex.surfaceMuted, foregroundHex: DocsColorHex.textDisabled, borderHex: nil))
    }

    func testNeutralPrimaryUsesTextPrimaryAsFill() {
        let style = ButtonStyleResolver.style(variant: .primary, color: .neutral, isDisabled: false)
        XCTAssertEqual(style, ButtonStyleHex(backgroundHex: DocsColorHex.textPrimary, foregroundHex: DocsColorHex.textOnBrand, borderHex: nil))
    }
}
