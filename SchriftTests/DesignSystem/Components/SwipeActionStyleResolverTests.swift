import XCTest

@testable import Schrift

final class SwipeActionStyleResolverTests: XCTestCase {
    func testNeutralUsesTheMutedSurfaceAndSecondaryInk() {
        let style = SwipeActionStyleResolver.style(role: .neutral)
        XCTAssertEqual(style.backgroundLightHex, DocsColorHex.surfaceMuted)
        XCTAssertEqual(style.backgroundDarkHex, DocsColorHexDark.surfaceMuted)
        XCTAssertEqual(style.foregroundLightHex, DocsColorHex.textSecondary)
        XCTAssertEqual(style.foregroundDarkHex, DocsColorHexDark.textSecondary)
    }

    func testBrandUsesTheBrandFill() {
        let style = SwipeActionStyleResolver.style(role: .brand)
        XCTAssertEqual(style.backgroundLightHex, DocsColorHex.brandFill)
        XCTAssertEqual(style.backgroundDarkHex, DocsColorHexDark.brandFill)
        XCTAssertEqual(style.foregroundLightHex, DocsColorHex.textOnBrand)
        XCTAssertEqual(style.foregroundDarkHex, DocsColorHexDark.textOnBrand)
    }

    func testDestructiveUsesTheDangerFill() {
        let style = SwipeActionStyleResolver.style(role: .destructive)
        XCTAssertEqual(style.backgroundLightHex, DocsColorHex.danger)
        XCTAssertEqual(style.backgroundDarkHex, DocsColorHexDark.danger)
        XCTAssertEqual(style.foregroundLightHex, DocsColorHex.textOnBrand)
    }

    /// **Destructive is the reason a resolver carries both halves per color.**
    ///
    /// `DocsColorHex.danger` is `0xD7010E`, a deep red that white ink sits on at roughly
    /// 7:1. Its dark counterpart `DocsColorHexDark.danger` is `0xF4796E` — a *light*
    /// salmon, because in dark mode the fill is the thing that has to lift off a near-black
    /// page. White on that reads at about 2.3:1, well under any usable threshold.
    ///
    /// So dark inverts the pairing rather than reusing the light ink: the same salmon fill
    /// with the page's own near-black as the ink, ~8:1. A single hex plus a global
    /// light→dark lookup could not express this, which is exactly the case CLAUDE.md's
    /// "both light and dark raw fields per color" rule exists for.
    ///
    /// This assertion is deliberately phrased against `textOnBrand` — a well-meaning
    /// "make the roles consistent" edit would set it to white and fail here.
    func testDestructiveInvertsItsInkInDarkModeRatherThanStayingWhite() {
        let style = SwipeActionStyleResolver.style(role: .destructive)
        XCTAssertEqual(style.foregroundDarkHex, DocsColorHexDark.surfacePage)
        XCTAssertNotEqual(
            style.foregroundDarkHex, DocsColorHexDark.textOnBrand,
            "white on the dark danger fill reads at ~2.3:1 — see this test's doc comment")
    }

    func testEveryRoleResolvesToADistinctBackground() {
        let backgrounds = [SwipeActionRole.neutral, .brand, .destructive]
            .map { SwipeActionStyleResolver.style(role: $0).backgroundLightHex }
        XCTAssertEqual(Set(backgrounds).count, backgrounds.count)
    }
}
