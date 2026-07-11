import XCTest

@testable import Schrift

final class ButtonStyleResolverTests: XCTestCase {
    func testPrimaryBrandUsesFillBackground() {
        let style = ButtonStyleResolver.style(variant: .primary, color: .brand, isDisabled: false)
        XCTAssertEqual(
            style,
            ButtonStyleHex(
                backgroundLightHex: DocsColorHex.brandFill, backgroundDarkHex: DocsColorHexDark.brandFill,
                foregroundLightHex: DocsColorHex.textOnBrand, foregroundDarkHex: DocsColorHexDark.textOnBrand,
                borderLightHex: nil, borderDarkHex: nil))
    }

    func testSecondaryBrandUsesSoftBackground() {
        let style = ButtonStyleResolver.style(variant: .secondary, color: .brand, isDisabled: false)
        XCTAssertEqual(
            style,
            ButtonStyleHex(
                backgroundLightHex: DocsColorHex.brandFillSoft, backgroundDarkHex: DocsColorHexDark.brandFillSoft,
                foregroundLightHex: DocsColorHex.textBrand, foregroundDarkHex: DocsColorHexDark.textBrand,
                borderLightHex: nil, borderDarkHex: nil))
    }

    func testTertiaryHasNoBackground() {
        let style = ButtonStyleResolver.style(variant: .tertiary, color: .brand, isDisabled: false)
        XCTAssertNil(style.backgroundLightHex)
        XCTAssertNil(style.backgroundDarkHex)
        XCTAssertEqual(style.foregroundLightHex, DocsColorHex.textBrand)
        XCTAssertEqual(style.foregroundDarkHex, DocsColorHexDark.textBrand)
    }

    func testOutlineUsesRaisedSurfaceAndHairlineBorder() {
        let style = ButtonStyleResolver.style(variant: .outline, color: .danger, isDisabled: false)
        XCTAssertEqual(style.backgroundLightHex, DocsColorHex.surfaceRaised)
        XCTAssertEqual(style.backgroundDarkHex, DocsColorHexDark.surfaceRaised)
        XCTAssertEqual(style.foregroundLightHex, DocsColorHex.danger)
        XCTAssertEqual(style.foregroundDarkHex, DocsColorHexDark.danger)
        XCTAssertEqual(style.borderLightHex, DocsColorHex.borderDefault)
        XCTAssertEqual(style.borderDarkHex, DocsColorHexDark.borderDefault)
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
                backgroundLightHex: DocsColorHex.textPrimary, backgroundDarkHex: DocsColorHexDark.textPrimary,
                foregroundLightHex: DocsColorHex.textOnBrand, foregroundDarkHex: DocsColorHexDark.textOnBrand,
                borderLightHex: nil, borderDarkHex: nil))
    }
}
