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
}
