import XCTest

@testable import Schrift

/// Token values themselves are visual and are checked in the `#Preview` catalogs and the Sketch library;
/// these tests pin only the relationships the design system promises and that an edit could break.
final class DocsColorTokenInvariantTests: XCTestCase {
    private let readable = 4.5

    func testSolidControlInkIsReadableOnEveryFillInLightAndDark() {
        let lightFills = [
            DocsColorHex.brandFill, DocsColorHex.danger, DocsColorHex.success, DocsColorHex.warning, DocsColorHex.info,
        ]
        let darkFills = [
            DocsColorHexDark.brandFill, DocsColorHexDark.danger, DocsColorHexDark.success,
            DocsColorHexDark.warning, DocsColorHexDark.info,
        ]
        for fill in lightFills {
            XCTAssertGreaterThanOrEqual(contrastRatio(DocsColorHex.textOnFill, fill), readable, "light \(fill)")
        }
        for fill in darkFills {
            XCTAssertGreaterThanOrEqual(contrastRatio(DocsColorHexDark.textOnFill, fill), readable, "dark \(fill)")
        }
    }

    func testTextAndBrandInkAreReadableOnEveryPageSurfaceInLightAndDark() {
        let light = (
            inks: [
                DocsColorHex.textPrimary, DocsColorHex.textSecondary, DocsColorHex.textTertiary, DocsColorHex.textBrand,
            ],
            surfaces: [DocsColorHex.surfacePage, DocsColorHex.surfaceSunken, DocsColorHex.surfaceMuted]
        )
        let dark = (
            inks: [
                DocsColorHexDark.textPrimary, DocsColorHexDark.textSecondary, DocsColorHexDark.textTertiary,
                DocsColorHexDark.textBrand,
            ],
            surfaces: [
                DocsColorHexDark.surfacePage, DocsColorHexDark.surfaceSunken, DocsColorHexDark.surfaceMuted,
                DocsColorHexDark.surfaceRaised,
            ]
        )
        for (inks, surfaces) in [(light.inks, light.surfaces), (dark.inks, dark.surfaces)] {
            for ink in inks {
                for surface in surfaces {
                    XCTAssertGreaterThanOrEqual(contrastRatio(ink, surface), readable, "\(ink) on \(surface)")
                }
            }
        }
    }

    func testFeedbackForegroundsAreReadableOnTheirSoftBackgrounds() {
        let light: [(UInt32, UInt32)] = [
            (DocsColorHex.info650, DocsColorHex.infoSoft), (DocsColorHex.success650, DocsColorHex.successSoft),
            (DocsColorHex.warning650, DocsColorHex.warningSoft), (DocsColorHex.dangerStrong, DocsColorHex.dangerSoft),
        ]
        let dark: [(UInt32, UInt32)] = [
            (DocsColorHexDark.info650, DocsColorHexDark.infoSoft),
            (DocsColorHexDark.success650, DocsColorHexDark.successSoft),
            (DocsColorHexDark.warning650, DocsColorHexDark.warningSoft),
            (DocsColorHexDark.dangerStrong, DocsColorHexDark.dangerSoft),
        ]
        for (ink, soft) in light + dark {
            XCTAssertGreaterThanOrEqual(contrastRatio(ink, soft), readable, "\(ink) on \(soft)")
        }
    }

    /// Dark mode is a real inversion for the neutral surfaces and text, not a copy of light.
    func testNeutralSurfacesAndTextDifferBetweenLightAndDark() {
        let pairs: [(UInt32, UInt32)] = [
            (DocsColorHex.surfacePage, DocsColorHexDark.surfacePage),
            (DocsColorHex.surfaceSunken, DocsColorHexDark.surfaceSunken),
            (DocsColorHex.surfaceMuted, DocsColorHexDark.surfaceMuted),
            (DocsColorHex.surfaceRaised, DocsColorHexDark.surfaceRaised),
            (DocsColorHex.textPrimary, DocsColorHexDark.textPrimary),
            (DocsColorHex.textSecondary, DocsColorHexDark.textSecondary),
            (DocsColorHex.textTertiary, DocsColorHexDark.textTertiary),
            (DocsColorHex.borderDefault, DocsColorHexDark.borderDefault),
        ]
        for (light, dark) in pairs {
            XCTAssertNotEqual(light, dark)
        }
        XCTAssertGreaterThan(relativeLuminance(DocsColorHex.surfacePage), relativeLuminance(DocsColorHex.textPrimary))
        XCTAssertLessThan(
            relativeLuminance(DocsColorHexDark.surfacePage), relativeLuminance(DocsColorHexDark.textPrimary))
    }

    /// docs/design-system.md: dark surfaces form an elevation ladder, sunken < page < raised < muted.
    func testDarkSurfacesFormAnElevationLadder() {
        let ladder = [
            DocsColorHexDark.surfaceSunken, DocsColorHexDark.surfacePage, DocsColorHexDark.surfaceRaised,
            DocsColorHexDark.surfaceMuted,
        ].map(relativeLuminance)
        XCTAssertEqual(ladder, ladder.sorted())
        XCTAssertEqual(Set(ladder).count, ladder.count)
    }

    /// docs/design-system.md: the accent palette (avatars, tags) is deliberately mode-independent.
    func testAccentPaletteIsUnchangedInDark() {
        XCTAssertEqual(DocsColorHexDark.accentOrange, DocsColorHex.accentOrange)
        XCTAssertEqual(DocsColorHexDark.accentBrown, DocsColorHex.accentBrown)
        XCTAssertEqual(DocsColorHexDark.accentGreen, DocsColorHex.accentGreen)
        XCTAssertEqual(DocsColorHexDark.accentBlue1, DocsColorHex.accentBlue1)
        XCTAssertEqual(DocsColorHexDark.accentBlue2, DocsColorHex.accentBlue2)
        XCTAssertEqual(DocsColorHexDark.accentPurple, DocsColorHex.accentPurple)
        XCTAssertEqual(DocsColorHexDark.accentPink, DocsColorHex.accentPink)
    }

    /// The sign-in logo's shadow must stay visible on the dark page, so dark `brandLogo` keeps its distance
    /// from the dark page surface.
    func testBrandLogoStaysDistinctFromThePageInBothModes() {
        XCTAssertGreaterThanOrEqual(contrastRatio(DocsColorHex.brandLogo, DocsColorHex.surfacePage), 3)
        XCTAssertGreaterThanOrEqual(contrastRatio(DocsColorHexDark.brandLogo, DocsColorHexDark.surfacePage), 3)
    }

    /// White media overlays keep their independent role, so `textOnBrand` is the same in both modes;
    /// `textOnFill` is the contrasting solid-control ink (AGENTS.md, "Personal themes" bullet).
    func testMediaOverlayInkIsModeIndependent() {
        XCTAssertEqual(DocsColorHexDark.textOnBrand, DocsColorHex.textOnBrand)
    }
}
