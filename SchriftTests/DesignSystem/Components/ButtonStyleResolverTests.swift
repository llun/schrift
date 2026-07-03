import XCTest

@testable import Schrift

final class ButtonStyleResolverTests: XCTestCase {
    func testPrimaryBrandUsesFillBackground() {
        let style = ButtonStyleResolver.style(variant: .primary, color: .brand, isDisabled: false)
        XCTAssertEqual(
            style,
            ButtonStyleHex(
                backgroundHex: DocsColorHex.brandFill, foregroundHex: DocsColorHex.textOnBrand, borderHex: nil))
    }

    func testSecondaryBrandUsesSoftBackground() {
        let style = ButtonStyleResolver.style(variant: .secondary, color: .brand, isDisabled: false)
        XCTAssertEqual(
            style,
            ButtonStyleHex(
                backgroundHex: DocsColorHex.brandFillSoft, foregroundHex: DocsColorHex.textBrand, borderHex: nil))
    }

    func testTertiaryHasNoBackground() {
        let style = ButtonStyleResolver.style(variant: .tertiary, color: .brand, isDisabled: false)
        XCTAssertNil(style.backgroundHex)
        XCTAssertEqual(style.foregroundHex, DocsColorHex.textBrand)
    }

    func testOutlineUsesRaisedSurfaceAndHairlineBorder() {
        let style = ButtonStyleResolver.style(variant: .outline, color: .danger, isDisabled: false)
        XCTAssertEqual(style.backgroundHex, DocsColorHex.surfaceRaised)
        XCTAssertEqual(style.foregroundHex, DocsColorHex.danger)
        XCTAssertEqual(style.borderHex, DocsColorHex.borderDefault)
    }

    func testDisabledKeepsVariantColors() {
        // Disabled is rendered by lowering opacity at the view level, so the
        // resolved colors stay identical to the enabled state.
        let enabled = ButtonStyleResolver.style(variant: .primary, color: .danger, isDisabled: false)
        let disabled = ButtonStyleResolver.style(variant: .primary, color: .danger, isDisabled: true)
        XCTAssertEqual(disabled, enabled)
    }

    func testNeutralPrimaryUsesTextPrimaryAsFill() {
        let style = ButtonStyleResolver.style(variant: .primary, color: .neutral, isDisabled: false)
        XCTAssertEqual(
            style,
            ButtonStyleHex(
                backgroundHex: DocsColorHex.textPrimary, foregroundHex: DocsColorHex.textOnBrand, borderHex: nil))
    }
}
