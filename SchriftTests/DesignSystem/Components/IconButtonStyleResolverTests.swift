import XCTest

@testable import Schrift

final class IconButtonStyleResolverTests: XCTestCase {
    func testGhostHasNoBackground() {
        let style = IconButtonStyleResolver.style(variant: .ghost, color: .neutral, isDisabled: false)
        XCTAssertNil(style.backgroundLightHex)
        XCTAssertNil(style.backgroundDarkHex)
        XCTAssertEqual(style.foregroundLightHex, DocsColorHex.textSecondary)
        XCTAssertEqual(style.foregroundDarkHex, DocsColorHexDark.textSecondary)
    }

    func testSoftBrandUsesBrandSoftBackground() {
        let style = IconButtonStyleResolver.style(variant: .soft, color: .brand, isDisabled: false)
        XCTAssertEqual(style.backgroundLightHex, DocsColorHex.brandFillSoft)
        XCTAssertEqual(style.backgroundDarkHex, DocsColorHexDark.brandFillSoft)
        XCTAssertEqual(style.foregroundLightHex, DocsColorHex.textBrand)
        XCTAssertEqual(style.foregroundDarkHex, DocsColorHexDark.textBrand)
    }

    func testOutlineDangerUsesRaisedSurfaceAndHairlineBorder() {
        let style = IconButtonStyleResolver.style(variant: .outline, color: .danger, isDisabled: false)
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
        let enabled = IconButtonStyleResolver.style(variant: .soft, color: .brand, isDisabled: false)
        let disabled = IconButtonStyleResolver.style(variant: .soft, color: .brand, isDisabled: true)
        XCTAssertEqual(disabled, enabled)
    }
}
