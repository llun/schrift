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
    static let surfaceScrim: UInt32 = 0x1B1B23   // rendered at 0.45 opacity

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
    static let brandFill = Color(hex: DocsColorHex.brandFill)
    static let brandFillHover = Color(hex: DocsColorHex.brandFillHover)
    static let brandFillSoft = Color(hex: DocsColorHex.brandFillSoft)
    static let brandFillSubtle = Color(hex: DocsColorHex.brandFillSubtle)
    static let textBrand = Color(hex: DocsColorHex.textBrand)
    static let textBrandSecondary = Color(hex: DocsColorHex.textBrandSecondary)

    static let textPrimary = Color(hex: DocsColorHex.textPrimary)
    static let textSecondary = Color(hex: DocsColorHex.textSecondary)
    static let textTertiary = Color(hex: DocsColorHex.textTertiary)
    static let textDisabled = Color(hex: DocsColorHex.textDisabled)
    static let textOnBrand = Color(hex: DocsColorHex.textOnBrand)

    static let surfacePage = Color(hex: DocsColorHex.surfacePage)
    static let surfaceSunken = Color(hex: DocsColorHex.surfaceSunken)
    static let surfaceMuted = Color(hex: DocsColorHex.surfaceMuted)

    static let borderDefault = Color(hex: DocsColorHex.borderDefault)
    static let borderStrong = Color(hex: DocsColorHex.borderStrong)
    static let borderFocus = Color(hex: DocsColorHex.borderFocus)

    static let info = Color(hex: DocsColorHex.info)
    static let success = Color(hex: DocsColorHex.success)
    static let warning = Color(hex: DocsColorHex.warning)
    static let danger = Color(hex: DocsColorHex.danger)

    static let infoSoft = Color(hex: DocsColorHex.infoSoft)
    static let successSoft = Color(hex: DocsColorHex.successSoft)
    static let warningSoft = Color(hex: DocsColorHex.warningSoft)
    static let dangerSoft = Color(hex: DocsColorHex.dangerSoft)

    static let brandLogo = Color(hex: DocsColorHex.brandLogo)

    static let gray050 = Color(hex: DocsColorHex.gray050)
    static let gray300 = Color(hex: DocsColorHex.gray300)
    static let gray350 = Color(hex: DocsColorHex.gray350)
    static let gray450 = Color(hex: DocsColorHex.gray450)

    static let surfaceRaised = Color(hex: DocsColorHex.surfaceRaised)
    static let surfaceScrim = Color(hex: DocsColorHex.surfaceScrim, opacity: 0.45)
}
