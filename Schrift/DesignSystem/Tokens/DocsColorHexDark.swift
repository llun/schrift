/// Dark-mode raw hex values for every token in `DocsColorHex`, same member
/// names. `DocsColor` pairs `DocsColorHex` (light) with `DocsColorHexDark`
/// (this file) into adaptive `Color`s via `Color(lightHex:darkHex:)`.
enum DocsColorHexDark {
    // Brand
    static let brandFill: UInt32 = 0x7B79E8
    static let brandFillHover: UInt32 = 0x8F8DF2
    static let brandFillSoft: UInt32 = 0x2C2C50
    static let brandFillSubtle: UInt32 = 0x1E1E33
    static let textBrand: UInt32 = 0xA9ADF9
    static let textBrandSecondary: UInt32 = 0x9195FC

    // Text
    static let textPrimary: UInt32 = 0xF4F4F6
    static let textSecondary: UInt32 = 0xB4B4C6
    static let textTertiary: UInt32 = 0x9494AA
    static let textDisabled: UInt32 = 0x5A5A6B
    static let textOnBrand: UInt32 = 0xFFFFFF

    // Surfaces
    static let surfacePage: UInt32 = 0x16161C
    static let surfaceSunken: UInt32 = 0x0E0E13
    static let surfaceMuted: UInt32 = 0x2A2A34

    // Borders
    static let borderDefault: UInt32 = 0x2E2E38
    static let borderStrong: UInt32 = 0x3C3C48
    static let borderFocus: UInt32 = 0x9CA0FF

    // Feedback
    static let info: UInt32 = 0x5AA9F0
    static let success: UInt32 = 0x4FB878
    static let warning: UInt32 = 0xE6915F
    static let danger: UInt32 = 0xF4796E

    // Feedback (soft backgrounds)
    static let infoSoft: UInt32 = 0x12283F
    static let successSoft: UInt32 = 0x12301E
    static let warningSoft: UInt32 = 0x35220F
    static let dangerSoft: UInt32 = 0x3A1A17

    // Feedback (strong / -650 foregrounds — used by Badge & LinkReachPill)
    static let dangerStrong: UInt32 = 0xF4796E
    static let info650: UInt32 = 0x5AA9F0
    static let success650: UInt32 = 0x4FB878
    static let warning650: UInt32 = 0xE6915F

    // Brand logo / app-icon field
    static let brandLogo: UInt32 = 0x7C79F2

    // Neutral gray ramp (cool-tinted; a subset of the Cunningham grey scale)
    static let gray050: UInt32 = 0x202028
    static let gray100: UInt32 = 0x2E2E38
    static let gray300: UInt32 = 0x565663
    static let gray350: UInt32 = 0x6C6C80
    static let gray450: UInt32 = 0x8A8A9E
    static let gray600: UInt32 = 0xB7B7CB

    // Surfaces (semantic)
    static let surfaceRaised: UInt32 = 0x202028
    static let surfaceScrim: UInt32 = 0x000000  // rendered at 0.45 opacity

    // Accent palette (avatars, emoji chips, tags) — unchanged in dark; white
    // initials read on both, and the accent hues are already dark enough.
    static let accentOrange: UInt32 = 0xB95D33
    static let accentBrown: UInt32 = 0x8F7158
    static let accentGreen: UInt32 = 0x008948
    static let accentBlue1: UInt32 = 0x4279B9
    static let accentBlue2: UInt32 = 0x00848F
    static let accentPurple: UInt32 = 0x9961AF
    static let accentPink: UInt32 = 0xAA5F80
}
