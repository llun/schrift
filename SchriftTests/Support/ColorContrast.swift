import Foundation

@testable import Schrift

/// WCAG relative luminance of a raw `0xRRGGBB` value.
func relativeLuminance(_ hex: UInt32) -> Double {
    let c = hexColorComponents(hex)
    func channel(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue)
}

/// WCAG contrast ratio (1...21) between two raw `0xRRGGBB` values, order-independent.
func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
    let x = relativeLuminance(a)
    let y = relativeLuminance(b)
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}
