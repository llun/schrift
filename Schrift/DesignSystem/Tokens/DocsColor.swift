import SwiftUI

enum DocsColorHex {
    // Brand
    static let brandFill: UInt32 = 0x5E5CD0
    static let brandFillHover: UInt32 = 0x4844AD
    static let brandFillSoft: UInt32 = 0xDDE2F5
    static let brandFillSubtle: UInt32 = 0xEEF1FA
    static let textBrand: UInt32 = 0x3E3B98
    static let textBrandSecondary: UInt32 = 0x534FC2

    // Text
    static let textPrimary: UInt32 = 0x25252F
    static let textSecondary: UInt32 = 0x5D5D70
    static let textTertiary: UInt32 = 0x69697D
    static let textDisabled: UInt32 = 0xA9A9BF
    static let textOnBrand: UInt32 = 0xFFFFFF

    // Surfaces
    static let surfacePage: UInt32 = 0xFFFFFF
    static let surfaceSunken: UInt32 = 0xF8F8F9
    static let surfaceMuted: UInt32 = 0xF0F0F3

    // Borders
    static let borderDefault: UInt32 = 0xE2E2EA
    static let borderStrong: UInt32 = 0xD3D4E0
    static let borderFocus: UInt32 = 0x8184FC

    // Feedback
    static let info: UInt32 = 0x0069CF
    static let success: UInt32 = 0x027B3E
    static let warning: UInt32 = 0xBC4200
    static let danger: UInt32 = 0xD7010E

    // Feedback (soft backgrounds)
    static let infoSoft: UInt32 = 0xD5E4F3
    static let successSoft: UInt32 = 0xCFE4D4
    static let warningSoft: UInt32 = 0xF1E0D3
    static let dangerSoft: UInt32 = 0xF4DFD9

    // Feedback (strong / -650 foregrounds — used by Badge & LinkReachPill)
    static let dangerStrong: UInt32 = 0xC00100
    static let info650: UInt32 = 0x0D4EAA
    static let success650: UInt32 = 0x006024
    static let warning650: UInt32 = 0x9E2300

    // Brand logo / app-icon field
    static let brandLogo: UInt32 = 0x4F46E5

    // Neutral gray ramp (cool-tinted; a subset of the Cunningham grey scale)
    static let gray050: UInt32 = 0xF0F0F3
    static let gray100: UInt32 = 0xE2E2EA
    static let gray300: UInt32 = 0xA9A9BF
    static let gray350: UInt32 = 0x9C9CB2
    static let gray450: UInt32 = 0x828297
    static let gray600: UInt32 = 0x5D5D70

    // Surfaces (semantic)
    static let surfaceRaised: UInt32 = 0xFFFFFF
    static let surfaceScrim: UInt32 = 0x1B1B23  // rendered at 0.45 opacity

    // Accent palette (avatars, emoji chips, tags)
    static let accentOrange: UInt32 = 0xB95D33
    static let accentBrown: UInt32 = 0x8F7158
    static let accentGreen: UInt32 = 0x008948
    static let accentBlue1: UInt32 = 0x4279B9
    static let accentBlue2: UInt32 = 0x00848F
    static let accentPurple: UInt32 = 0x9961AF
    static let accentPink: UInt32 = 0xAA5F80
}

enum DocsColor {
    static let brandFill = Color(lightHex: DocsColorHex.brandFill, darkHex: DocsColorHexDark.brandFill)
    static let brandFillHover = Color(lightHex: DocsColorHex.brandFillHover, darkHex: DocsColorHexDark.brandFillHover)
    static let brandFillSoft = Color(lightHex: DocsColorHex.brandFillSoft, darkHex: DocsColorHexDark.brandFillSoft)
    static let brandFillSubtle = Color(
        lightHex: DocsColorHex.brandFillSubtle, darkHex: DocsColorHexDark.brandFillSubtle)
    static let textBrand = Color(lightHex: DocsColorHex.textBrand, darkHex: DocsColorHexDark.textBrand)
    static let textBrandSecondary = Color(
        lightHex: DocsColorHex.textBrandSecondary, darkHex: DocsColorHexDark.textBrandSecondary)

    static let textPrimary = Color(lightHex: DocsColorHex.textPrimary, darkHex: DocsColorHexDark.textPrimary)
    static let textSecondary = Color(lightHex: DocsColorHex.textSecondary, darkHex: DocsColorHexDark.textSecondary)
    static let textTertiary = Color(lightHex: DocsColorHex.textTertiary, darkHex: DocsColorHexDark.textTertiary)
    static let textDisabled = Color(lightHex: DocsColorHex.textDisabled, darkHex: DocsColorHexDark.textDisabled)
    static let textOnBrand = Color(lightHex: DocsColorHex.textOnBrand, darkHex: DocsColorHexDark.textOnBrand)

    static let surfacePage = Color(lightHex: DocsColorHex.surfacePage, darkHex: DocsColorHexDark.surfacePage)
    static let surfaceSunken = Color(lightHex: DocsColorHex.surfaceSunken, darkHex: DocsColorHexDark.surfaceSunken)
    static let surfaceMuted = Color(lightHex: DocsColorHex.surfaceMuted, darkHex: DocsColorHexDark.surfaceMuted)

    static let borderDefault = Color(lightHex: DocsColorHex.borderDefault, darkHex: DocsColorHexDark.borderDefault)
    static let borderStrong = Color(lightHex: DocsColorHex.borderStrong, darkHex: DocsColorHexDark.borderStrong)
    static let borderFocus = Color(lightHex: DocsColorHex.borderFocus, darkHex: DocsColorHexDark.borderFocus)

    static let info = Color(lightHex: DocsColorHex.info, darkHex: DocsColorHexDark.info)
    static let success = Color(lightHex: DocsColorHex.success, darkHex: DocsColorHexDark.success)
    static let warning = Color(lightHex: DocsColorHex.warning, darkHex: DocsColorHexDark.warning)
    static let danger = Color(lightHex: DocsColorHex.danger, darkHex: DocsColorHexDark.danger)

    static let infoSoft = Color(lightHex: DocsColorHex.infoSoft, darkHex: DocsColorHexDark.infoSoft)
    static let successSoft = Color(lightHex: DocsColorHex.successSoft, darkHex: DocsColorHexDark.successSoft)
    static let warningSoft = Color(lightHex: DocsColorHex.warningSoft, darkHex: DocsColorHexDark.warningSoft)
    static let dangerSoft = Color(lightHex: DocsColorHex.dangerSoft, darkHex: DocsColorHexDark.dangerSoft)

    static let brandLogo = Color(lightHex: DocsColorHex.brandLogo, darkHex: DocsColorHexDark.brandLogo)

    static let gray050 = Color(lightHex: DocsColorHex.gray050, darkHex: DocsColorHexDark.gray050)
    static let gray300 = Color(lightHex: DocsColorHex.gray300, darkHex: DocsColorHexDark.gray300)
    static let gray350 = Color(lightHex: DocsColorHex.gray350, darkHex: DocsColorHexDark.gray350)
    static let gray450 = Color(lightHex: DocsColorHex.gray450, darkHex: DocsColorHexDark.gray450)

    static let surfaceRaised = Color(lightHex: DocsColorHex.surfaceRaised, darkHex: DocsColorHexDark.surfaceRaised)
    static let surfaceScrim = Color(
        lightHex: DocsColorHex.surfaceScrim, darkHex: DocsColorHexDark.surfaceScrim, opacity: 0.45)
}
