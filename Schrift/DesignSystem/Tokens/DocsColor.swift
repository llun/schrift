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

    // Feedback (tertiary tints — lightest feedback backgrounds)
    static let infoTertiary: UInt32 = 0xEAF2F9
    static let successTertiary: UInt32 = 0xE8F1EA
    static let warningTertiary: UInt32 = 0xF8F0E9
    static let errorTertiary: UInt32 = 0xF9EFEC

    // Brand (hover states, logo field, focused-input border)
    static let brandFillSoftHover: UInt32 = 0xCED3F1
    static let brandFillSubtleHover: UInt32 = 0xDDE2F5
    static let borderBrand: UInt32 = 0x5E5CD0
    static let brandLogo: UInt32 = 0x4F46E5

    // Neutral gray ramp (cool-tinted; a subset of the Cunningham grey scale)
    static let gray050: UInt32 = 0xF0F0F3
    static let gray100: UInt32 = 0xE2E2EA
    static let gray150: UInt32 = 0xD3D4E0
    static let gray200: UInt32 = 0xC5C6D5
    static let gray300: UInt32 = 0xA9A9BF
    static let gray350: UInt32 = 0x9C9CB2
    static let gray450: UInt32 = 0x828297
    static let gray600: UInt32 = 0x5D5D70
    static let gray850: UInt32 = 0x25252F

    // Surfaces (semantic)
    static let surfaceRaised: UInt32 = 0xFFFFFF
    static let surfaceScrim: UInt32 = 0x1B1B23   // rendered at 0.45 opacity
    static let surfaceOverlay: UInt32 = 0x1B1B23 // rendered at 0.05 opacity

    // Accent palette (avatars, emoji chips, tags)
    static let accentRed: UInt32 = 0xDA3B49
    static let accentOrange: UInt32 = 0xB95D33
    static let accentBrown: UInt32 = 0x8F7158
    static let accentYellow: UInt32 = 0x9D6E00
    static let accentGreen: UInt32 = 0x008948
    static let accentBlue1: UInt32 = 0x4279B9
    static let accentBlue2: UInt32 = 0x00848F
    static let accentPurple: UInt32 = 0x9961AF
    static let accentPink: UInt32 = 0xAA5F80
    static let accentGray: UInt32 = 0x75758A

    // Live-collaboration presence (accent cycle for cursors / avatars)
    static let presence1: UInt32 = 0x6969DF
    static let presence2: UInt32 = 0x008948
    static let presence3: UInt32 = 0xB95D33
    static let presence4: UInt32 = 0x9961AF
    static let presence5: UInt32 = 0x4279B9

    // App-icon / logo mark palette
    static let iconField: UInt32 = 0x4F46E5
    static let iconPaper: UInt32 = 0xFFFFFF
    static let iconFold: UInt32 = 0xDBD9F5
    static let iconHeadingBar: UInt32 = 0xB9B5E6
    static let iconBodyLine: UInt32 = 0xE2E1F1
    static let iconCursorAmber: UInt32 = 0xF59E0B
    static let iconCursorPink: UInt32 = 0xEC4899
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

    static let dangerStrong = Color(hex: DocsColorHex.dangerStrong)
    static let info650 = Color(hex: DocsColorHex.info650)
    static let success650 = Color(hex: DocsColorHex.success650)
    static let warning650 = Color(hex: DocsColorHex.warning650)

    static let brandFillSoftHover = Color(hex: DocsColorHex.brandFillSoftHover)
    static let brandFillSubtleHover = Color(hex: DocsColorHex.brandFillSubtleHover)
    static let borderBrand = Color(hex: DocsColorHex.borderBrand)
    static let brandLogo = Color(hex: DocsColorHex.brandLogo)

    static let gray050 = Color(hex: DocsColorHex.gray050)
    static let gray100 = Color(hex: DocsColorHex.gray100)
    static let gray150 = Color(hex: DocsColorHex.gray150)
    static let gray200 = Color(hex: DocsColorHex.gray200)
    static let gray300 = Color(hex: DocsColorHex.gray300)
    static let gray350 = Color(hex: DocsColorHex.gray350)
    static let gray450 = Color(hex: DocsColorHex.gray450)
    static let gray600 = Color(hex: DocsColorHex.gray600)
    static let gray850 = Color(hex: DocsColorHex.gray850)

    static let surfaceRaised = Color(hex: DocsColorHex.surfaceRaised)
    static let surfaceScrim = Color(hex: DocsColorHex.surfaceScrim, opacity: 0.45)
    static let surfaceOverlay = Color(hex: DocsColorHex.surfaceOverlay, opacity: 0.05)

    static let presence1 = Color(hex: DocsColorHex.presence1)
    static let presence2 = Color(hex: DocsColorHex.presence2)
    static let presence3 = Color(hex: DocsColorHex.presence3)
    static let presence4 = Color(hex: DocsColorHex.presence4)
    static let presence5 = Color(hex: DocsColorHex.presence5)
}
