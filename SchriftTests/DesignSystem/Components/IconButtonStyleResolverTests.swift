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

    func testDisabledIgnoresVariantAndColor() {
        let style = IconButtonStyleResolver.style(variant: .soft, color: .brand, isDisabled: true)
        XCTAssertEqual(style, IconButtonStyleHex(backgroundHex: nil, foregroundHex: DocsColorHex.textDisabled, borderHex: nil))
    }
}
