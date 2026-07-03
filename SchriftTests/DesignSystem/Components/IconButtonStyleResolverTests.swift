import XCTest
@testable import Schrift

final class IconButtonStyleResolverTests: XCTestCase {
    func testGhostHasNoBackground() {
        let style = IconButtonStyleResolver.style(variant: .ghost, color: .neutral, isDisabled: false)
        XCTAssertNil(style.backgroundHex)
        XCTAssertEqual(style.foregroundHex, DocsColorHex.textSecondary)
    }

    func testSoftBrandUsesBrandSoftBackground() {
        let style = IconButtonStyleResolver.style(variant: .soft, color: .brand, isDisabled: false)
        XCTAssertEqual(style.backgroundHex, DocsColorHex.brandFillSoft)
        XCTAssertEqual(style.foregroundHex, DocsColorHex.textBrand)
    }

    func testOutlineDangerUsesRaisedSurfaceAndHairlineBorder() {
        let style = IconButtonStyleResolver.style(variant: .outline, color: .danger, isDisabled: false)
        XCTAssertEqual(style.backgroundHex, DocsColorHex.surfaceRaised)
        XCTAssertEqual(style.foregroundHex, DocsColorHex.danger)
        XCTAssertEqual(style.borderHex, DocsColorHex.borderDefault)
    }

    func testDisabledKeepsVariantColors() {
        // Disabled is rendered by lowering opacity at the view level, so the
        // resolved colors stay identical to the enabled state.
        let enabled = IconButtonStyleResolver.style(variant: .soft, color: .brand, isDisabled: false)
        let disabled = IconButtonStyleResolver.style(variant: .soft, color: .brand, isDisabled: true)
        XCTAssertEqual(disabled, enabled)
    }
}
