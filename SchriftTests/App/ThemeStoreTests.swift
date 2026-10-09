import SwiftUI
import UIKit
import XCTest

@testable import Schrift

private final class ThemeDefaults: UserDefaults, @unchecked Sendable {
    var writes = 0
    override func set(_ value: Any?, forKey defaultName: String) {
        writes += 1
        super.set(value, forKey: defaultName)
    }
}

@MainActor
final class ThemeStoreTests: XCTestCase {
    private var defaults: ThemeDefaults!
    private var suite: String!

    override func setUp() {
        suite = "ThemeStoreTests.\(UUID().uuidString)"
        defaults = ThemeDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
    }

    func testExistingAndNewInstallDefaultToWhiteWithoutWrites() {
        defaults.set("dark", forKey: "schrift.appearance")
        defaults.writes = 0
        XCTAssertEqual(ThemeStore(userDefaults: defaults).selected, .white)
        XCTAssertEqual(defaults.writes, 0)
        XCTAssertEqual(AppearanceStore(userDefaults: defaults).selected, .dark)
    }

    func testInvalidStoredThemeFallsBackWithoutMutatingPreferences() {
        defaults.set("unknown", forKey: "schrift.theme")
        defaults.writes = 0
        XCTAssertEqual(ThemeStore(userDefaults: defaults).selected, .white)
        XCTAssertEqual(defaults.string(forKey: "schrift.theme"), "unknown")
        XCTAssertEqual(defaults.writes, 0)
    }

    func testThemeAndAppearancePersistIndependently() {
        let appearance = AppearanceStore(userDefaults: defaults)
        let theme = ThemeStore(userDefaults: defaults)
        appearance.selected = .dark
        theme.selected = .paper
        XCTAssertEqual(ThemeStore(userDefaults: defaults).selected, .paper)
        XCTAssertEqual(AppearanceStore(userDefaults: defaults).selected, .dark)
        appearance.selected = .system
        XCTAssertEqual(theme.selected, .paper)
        theme.selected = .mist
        XCTAssertEqual(appearance.selected, .system)
    }

    func testReselectingTheSameThemeDoesNotWrite() {
        let theme = ThemeStore(userDefaults: defaults)
        theme.selected = .paper
        defaults.writes = 0
        theme.selected = .paper
        XCTAssertEqual(defaults.writes, 0)
    }
}

final class DocsThemePaletteTests: XCTestCase {
    func testBodySecondaryLinksAndFeedbackRemainReadableAcrossThemeSurfaces() {
        for theme in AppTheme.allCases {
            for isDark in [false, true] {
                let p = DocsPalette(theme: theme, isDark: isDark)
                for surface in [p.surfacePage, p.surfaceSunken, p.surfaceMuted] {
                    for ink in [p.textPrimary, p.textSecondary, p.textTertiary, p.textBrand] {
                        XCTAssertGreaterThanOrEqual(
                            contrastRatio(ink, surface), 4.5, "\(theme)-\(isDark): \(ink) / \(surface)")
                    }
                }
                for (ink, fill) in [
                    (p.info650, p.infoSoft), (p.success650, p.successSoft),
                    (p.warning650, p.warningSoft), (p.dangerStrong, p.dangerSoft),
                ] {
                    XCTAssertGreaterThanOrEqual(contrastRatio(ink, fill), 4.5)
                }
            }
        }
    }

    func testPrimaryControlTextContrastsAgainstItsResolvedFillInEveryThemeAndMode() {
        for theme in AppTheme.allCases {
            for color in [ButtonColor.brand, .neutral, .danger] {
                let style = ButtonStyleResolver.style(variant: .primary, color: color, theme: theme)
                XCTAssertGreaterThanOrEqual(contrastRatio(style.foregroundLightHex, style.backgroundLightHex!), 4.5)
                XCTAssertGreaterThanOrEqual(contrastRatio(style.foregroundDarkHex, style.backgroundDarkHex!), 4.5)
            }
        }
    }

    func testPureResolversUseTheSameSemanticPaletteAsScreenColors() {
        for theme in AppTheme.allCases {
            let light = DocsPalette(theme: theme, isDark: false)
            let dark = DocsPalette(theme: theme, isDark: true)
            let badge = BadgeStyleResolver.style(tone: .neutral, theme: theme)
            XCTAssertEqual(badge.foregroundLightHex, light.gray600)
            XCTAssertEqual(badge.backgroundDarkHex, dark.gray100)
            let button = ButtonStyleResolver.style(variant: .outline, color: .brand, theme: theme)
            XCTAssertEqual(button.backgroundLightHex, light.surfaceRaised)
            XCTAssertEqual(button.foregroundDarkHex, dark.textBrand)
            let field = TextFieldStyleResolver.style(state: .normal, theme: theme)
            XCTAssertEqual(field.borderLightHex, light.borderDefault)
        }
    }
}
