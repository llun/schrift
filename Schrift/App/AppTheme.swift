import SwiftUI

/// A personal display preference. It never reaches document or collaboration data.
enum AppTheme: String, CaseIterable, Sendable {
    case white, mist, paper

    var colors: DocsColors { DocsColors(theme: self) }
}

/// Defaulted value injection keeps independent previews and windows isolated.
private struct DocsThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.white
}

extension EnvironmentValues {
    var docsTheme: AppTheme {
        get { self[DocsThemeKey.self] }
        set { self[DocsThemeKey.self] = newValue }
    }
}

@MainActor
@Observable
final class ThemeStore {
    private let userDefaults: UserDefaults
    private static let key = "schrift.theme"

    var selected: AppTheme {
        didSet {
            guard oldValue != selected else { return }
            userDefaults.set(selected.rawValue, forKey: Self.key)
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        selected = userDefaults.string(forKey: Self.key).flatMap(AppTheme.init(rawValue:)) ?? .white
    }
}

/// Pure semantic palette. White preserves the established colors for existing installs;
/// Mist and Paper change neutral/brand roles while feedback and identity hues stay stable.
struct DocsPalette: Equatable, Sendable {
    let theme: AppTheme
    let isDark: Bool

    var brandFill: UInt32 {
        switch theme {
        case .white: return isDark ? DocsColorHexDark.brandFill : DocsColorHex.brandFill
        case .mist: return isDark ? 0xBAB7FF : 0x5654C2
        case .paper: return isDark ? 0xC5B3F0 : 0x6555AD
        }
    }

    var brandFillHover: UInt32 {
        switch theme {
        case .white: return isDark ? DocsColorHexDark.brandFillHover : DocsColorHex.brandFillHover
        case .mist: return isDark ? 0xC8C5FF : 0x4844AD
        case .paper: return isDark ? 0xD4C4FA : 0x53438F
        }
    }

    var brandFillSoft: UInt32 {
        switch theme {
        case .white: return isDark ? DocsColorHexDark.brandFillSoft : DocsColorHex.brandFillSoft
        case .mist: return isDark ? 0x2C3442 : 0xE3E5ED
        case .paper: return isDark ? 0x373229 : 0xE8E0D2
        }
    }

    var brandFillSubtle: UInt32 {
        switch theme {
        case .white: return isDark ? DocsColorHexDark.brandFillSubtle : DocsColorHex.brandFillSubtle
        case .mist: return isDark ? 0x2C3442 : 0xE8EAF0
        case .paper: return isDark ? 0x373229 : 0xEDE6D9
        }
    }

    var textBrand: UInt32 {
        switch theme {
        case .white: return isDark ? DocsColorHexDark.textBrand : DocsColorHex.textBrand
        case .mist: return isDark ? 0xBAB7FF : 0x5654C2
        case .paper: return isDark ? 0xC5B3F0 : 0x6555AD
        }
    }

    var textBrandSecondary: UInt32 {
        switch theme {
        case .white: return isDark ? DocsColorHexDark.textBrandSecondary : DocsColorHex.textBrandSecondary
        case .mist: return isDark ? 0xBAB7FF : 0x5654C2
        case .paper: return isDark ? 0xC5B3F0 : 0x6555AD
        }
    }

    var textPrimary: UInt32 {
        switch theme {
        case .white: return isDark ? DocsColorHexDark.textPrimary : DocsColorHex.textPrimary
        case .mist: return isDark ? 0xF0F2F7 : 0x242630
        case .paper: return isDark ? 0xF3ECE0 : 0x302E2C
        }
    }

    var textSecondary: UInt32 {
        switch theme {
        case .white: return isDark ? DocsColorHexDark.textSecondary : DocsColorHex.textSecondary
        case .mist: return isDark ? 0xACB6C6 : 0x616676
        case .paper: return isDark ? 0xBBB1A2 : 0x666057
        }
    }

    var textTertiary: UInt32 {
        switch theme {
        case .white: return isDark ? DocsColorHexDark.textTertiary : DocsColorHex.textTertiary
        case .mist: return isDark ? 0xACB6C6 : 0x616676
        case .paper: return isDark ? 0xBBB1A2 : 0x666057
        }
    }

    var textDisabled: UInt32 {
        switch theme {
        case .white: return isDark ? DocsColorHexDark.textDisabled : DocsColorHex.textDisabled
        case .mist: return isDark ? 0x727C8C : 0x8A8F9E
        case .paper: return isDark ? 0x857B6B : 0x938B7E
        }
    }

    var textOnBrand: UInt32 {
        isDark ? DocsColorHexDark.textOnBrand : DocsColorHex.textOnBrand
    }

    var textOnFill: UInt32 {
        switch theme {
        case .white: return isDark ? DocsColorHexDark.textOnFill : DocsColorHex.textOnFill
        case .mist: return isDark ? 0x1C2028 : 0xFFFFFF
        case .paper: return isDark ? 0x25231F : 0xFFFFFF
        }
    }

    var surfacePage: UInt32 {
        switch theme {
        case .white: return isDark ? DocsColorHexDark.surfacePage : DocsColorHex.surfacePage
        case .mist: return isDark ? 0x1C2028 : 0xF2F3F6
        case .paper: return isDark ? 0x25231F : 0xF6F1E7
        }
    }

    var surfaceSunken: UInt32 {
        switch theme {
        case .white: return isDark ? DocsColorHexDark.surfaceSunken : DocsColorHex.surfaceSunken
        case .mist: return isDark ? 0x151921 : 0xE8EAF0
        case .paper: return isDark ? 0x1C1B18 : 0xEDE6D9
        }
    }

    var surfaceMuted: UInt32 {
        switch theme {
        case .white: return isDark ? DocsColorHexDark.surfaceMuted : DocsColorHex.surfaceMuted
        case .mist: return isDark ? 0x2C3442 : 0xE3E5ED
        case .paper: return isDark ? 0x373229 : 0xE8E0D2
        }
    }

    var borderDefault: UInt32 {
        switch theme {
        case .white: return isDark ? DocsColorHexDark.borderDefault : DocsColorHex.borderDefault
        case .mist: return isDark ? 0x3B4351 : 0xD8DBE4
        case .paper: return isDark ? 0x4B453B : 0xDCD3C4
        }
    }

    var borderStrong: UInt32 {
        switch theme {
        case .white: return isDark ? DocsColorHexDark.borderStrong : DocsColorHex.borderStrong
        case .mist: return isDark ? 0x788598 : 0x959CAD
        case .paper: return isDark ? 0x91816A : 0xA99D89
        }
    }

    var borderFocus: UInt32 {
        switch theme {
        case .white: return isDark ? DocsColorHexDark.borderFocus : DocsColorHex.borderFocus
        case .mist: return isDark ? 0xBAB7FF : 0x5654C2
        case .paper: return isDark ? 0xC5B3F0 : 0x6555AD
        }
    }

    var info: UInt32 {
        isDark ? DocsColorHexDark.info : DocsColorHex.info
    }

    var success: UInt32 {
        isDark ? DocsColorHexDark.success : DocsColorHex.success
    }

    var warning: UInt32 {
        isDark ? DocsColorHexDark.warning : DocsColorHex.warning
    }

    var danger: UInt32 {
        isDark ? DocsColorHexDark.danger : DocsColorHex.danger
    }

    var infoSoft: UInt32 {
        isDark ? DocsColorHexDark.infoSoft : DocsColorHex.infoSoft
    }

    var successSoft: UInt32 {
        isDark ? DocsColorHexDark.successSoft : DocsColorHex.successSoft
    }

    var warningSoft: UInt32 {
        isDark ? DocsColorHexDark.warningSoft : DocsColorHex.warningSoft
    }

    var dangerSoft: UInt32 {
        isDark ? DocsColorHexDark.dangerSoft : DocsColorHex.dangerSoft
    }

    var dangerStrong: UInt32 {
        isDark ? DocsColorHexDark.dangerStrong : DocsColorHex.dangerStrong
    }

    var info650: UInt32 {
        isDark ? DocsColorHexDark.info650 : DocsColorHex.info650
    }

    var success650: UInt32 {
        isDark ? DocsColorHexDark.success650 : DocsColorHex.success650
    }

    var warning650: UInt32 {
        isDark ? DocsColorHexDark.warning650 : DocsColorHex.warning650
    }

    var brandLogo: UInt32 {
        isDark ? DocsColorHexDark.brandLogo : DocsColorHex.brandLogo
    }

    var gray050: UInt32 {
        switch theme {
        case .white: return isDark ? DocsColorHexDark.gray050 : DocsColorHex.gray050
        case .mist: return isDark ? 0x2C3442 : 0xE3E5ED
        case .paper: return isDark ? 0x373229 : 0xE8E0D2
        }
    }

    var gray100: UInt32 {
        switch theme {
        case .white: return isDark ? DocsColorHexDark.gray100 : DocsColorHex.gray100
        case .mist: return isDark ? 0x3B4351 : 0xD8DBE4
        case .paper: return isDark ? 0x4B453B : 0xDCD3C4
        }
    }

    var gray300: UInt32 {
        switch theme {
        case .white: return isDark ? DocsColorHexDark.gray300 : DocsColorHex.gray300
        case .mist: return isDark ? 0x727C8C : 0x8A8F9E
        case .paper: return isDark ? 0x857B6B : 0x938B7E
        }
    }

    var gray350: UInt32 {
        switch theme {
        case .white: return isDark ? DocsColorHexDark.gray350 : DocsColorHex.gray350
        case .mist: return isDark ? 0x727C8C : 0x8A8F9E
        case .paper: return isDark ? 0x857B6B : 0x938B7E
        }
    }

    var gray450: UInt32 {
        switch theme {
        case .white: return isDark ? DocsColorHexDark.gray450 : DocsColorHex.gray450
        case .mist: return isDark ? 0xACB6C6 : 0x616676
        case .paper: return isDark ? 0xBBB1A2 : 0x666057
        }
    }

    var gray600: UInt32 {
        switch theme {
        case .white: return isDark ? DocsColorHexDark.gray600 : DocsColorHex.gray600
        case .mist: return isDark ? 0xACB6C6 : 0x616676
        case .paper: return isDark ? 0xBBB1A2 : 0x666057
        }
    }

    var surfaceRaised: UInt32 {
        switch theme {
        case .white: return isDark ? DocsColorHexDark.surfaceRaised : DocsColorHex.surfaceRaised
        case .mist: return isDark ? 0x1C2028 : 0xF2F3F6
        case .paper: return isDark ? 0x25231F : 0xF6F1E7
        }
    }

    var surfaceScrim: UInt32 {
        isDark ? DocsColorHexDark.surfaceScrim : DocsColorHex.surfaceScrim
    }

    var accentOrange: UInt32 {
        isDark ? DocsColorHexDark.accentOrange : DocsColorHex.accentOrange
    }

    var accentBrown: UInt32 {
        isDark ? DocsColorHexDark.accentBrown : DocsColorHex.accentBrown
    }

    var accentGreen: UInt32 {
        isDark ? DocsColorHexDark.accentGreen : DocsColorHex.accentGreen
    }

    var accentBlue1: UInt32 {
        isDark ? DocsColorHexDark.accentBlue1 : DocsColorHex.accentBlue1
    }

    var accentBlue2: UInt32 {
        isDark ? DocsColorHexDark.accentBlue2 : DocsColorHex.accentBlue2
    }

    var accentPurple: UInt32 {
        isDark ? DocsColorHexDark.accentPurple : DocsColorHex.accentPurple
    }

    var accentPink: UInt32 {
        isDark ? DocsColorHexDark.accentPink : DocsColorHex.accentPink
    }
}

/// Adaptive SwiftUI colors made from the same palette the pure resolvers consume.
struct DocsColors {
    let theme: AppTheme

    var borderStrong: Color {
        Color(
            lightHex: DocsPalette(theme: theme, isDark: false).borderStrong,
            darkHex: DocsPalette(theme: theme, isDark: true).borderStrong)
    }

    var brandFill: Color {
        Color(
            lightHex: DocsPalette(theme: theme, isDark: false).brandFill,
            darkHex: DocsPalette(theme: theme, isDark: true).brandFill)
    }

    var brandFillSubtle: Color {
        Color(
            lightHex: DocsPalette(theme: theme, isDark: false).brandFillSubtle,
            darkHex: DocsPalette(theme: theme, isDark: true).brandFillSubtle)
    }

    var textBrand: Color {
        Color(
            lightHex: DocsPalette(theme: theme, isDark: false).textBrand,
            darkHex: DocsPalette(theme: theme, isDark: true).textBrand)
    }

    var textPrimary: Color {
        Color(
            lightHex: DocsPalette(theme: theme, isDark: false).textPrimary,
            darkHex: DocsPalette(theme: theme, isDark: true).textPrimary)
    }

    var textSecondary: Color {
        Color(
            lightHex: DocsPalette(theme: theme, isDark: false).textSecondary,
            darkHex: DocsPalette(theme: theme, isDark: true).textSecondary)
    }

    var textTertiary: Color {
        Color(
            lightHex: DocsPalette(theme: theme, isDark: false).textTertiary,
            darkHex: DocsPalette(theme: theme, isDark: true).textTertiary)
    }

    var textOnBrand: Color {
        Color(
            lightHex: DocsPalette(theme: theme, isDark: false).textOnBrand,
            darkHex: DocsPalette(theme: theme, isDark: true).textOnBrand)
    }

    var surfacePage: Color {
        Color(
            lightHex: DocsPalette(theme: theme, isDark: false).surfacePage,
            darkHex: DocsPalette(theme: theme, isDark: true).surfacePage)
    }

    var surfaceSunken: Color {
        Color(
            lightHex: DocsPalette(theme: theme, isDark: false).surfaceSunken,
            darkHex: DocsPalette(theme: theme, isDark: true).surfaceSunken)
    }

    var surfaceMuted: Color {
        Color(
            lightHex: DocsPalette(theme: theme, isDark: false).surfaceMuted,
            darkHex: DocsPalette(theme: theme, isDark: true).surfaceMuted)
    }

    var borderDefault: Color {
        Color(
            lightHex: DocsPalette(theme: theme, isDark: false).borderDefault,
            darkHex: DocsPalette(theme: theme, isDark: true).borderDefault)
    }

    var borderFocus: Color {
        Color(
            lightHex: DocsPalette(theme: theme, isDark: false).borderFocus,
            darkHex: DocsPalette(theme: theme, isDark: true).borderFocus)
    }

    var success: Color {
        Color(
            lightHex: DocsPalette(theme: theme, isDark: false).success,
            darkHex: DocsPalette(theme: theme, isDark: true).success)
    }

    var danger: Color {
        Color(
            lightHex: DocsPalette(theme: theme, isDark: false).danger,
            darkHex: DocsPalette(theme: theme, isDark: true).danger)
    }

    var brandLogo: Color {
        Color(
            lightHex: DocsPalette(theme: theme, isDark: false).brandLogo,
            darkHex: DocsPalette(theme: theme, isDark: true).brandLogo)
    }

    var gray050: Color {
        Color(
            lightHex: DocsPalette(theme: theme, isDark: false).gray050,
            darkHex: DocsPalette(theme: theme, isDark: true).gray050)
    }

    var gray300: Color {
        Color(
            lightHex: DocsPalette(theme: theme, isDark: false).gray300,
            darkHex: DocsPalette(theme: theme, isDark: true).gray300)
    }

    var gray350: Color {
        Color(
            lightHex: DocsPalette(theme: theme, isDark: false).gray350,
            darkHex: DocsPalette(theme: theme, isDark: true).gray350)
    }

    var gray450: Color {
        Color(
            lightHex: DocsPalette(theme: theme, isDark: false).gray450,
            darkHex: DocsPalette(theme: theme, isDark: true).gray450)
    }

    var surfaceRaised: Color {
        Color(
            lightHex: DocsPalette(theme: theme, isDark: false).surfaceRaised,
            darkHex: DocsPalette(theme: theme, isDark: true).surfaceRaised)
    }

    var surfaceScrim: Color {
        Color(
            lightHex: DocsPalette(theme: theme, isDark: false).surfaceScrim,
            darkHex: DocsPalette(theme: theme, isDark: true).surfaceScrim, opacity: 0.45)
    }
}

private struct DocsRowGutterKey: EnvironmentKey {
    static let defaultValue: CGFloat = DocsSpacing.gutter
}

extension EnvironmentValues {
    /// Open sections own their outer inset; sheet rows retain their ordinary gutter.
    var docsRowGutter: CGFloat {
        get { self[DocsRowGutterKey.self] }
        set { self[DocsRowGutterKey.self] = newValue }
    }
}

enum DocsCanvasRole { case page, sidebar }

private struct DocsCanvasRoleKey: EnvironmentKey {
    static let defaultValue = DocsCanvasRole.page
}

extension EnvironmentValues {
    var docsCanvasRole: DocsCanvasRole {
        get { self[DocsCanvasRoleKey.self] }
        set { self[DocsCanvasRoleKey.self] = newValue }
    }
}
