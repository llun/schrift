import SwiftUI
import UIKit

struct HexColorComponents: Equatable {
    let red: Double
    let green: Double
    let blue: Double
}

func hexColorComponents(_ hex: UInt32) -> HexColorComponents {
    let red = Double((hex >> 16) & 0xFF) / 255.0
    let green = Double((hex >> 8) & 0xFF) / 255.0
    let blue = Double(hex & 0xFF) / 255.0
    return HexColorComponents(red: red, green: green, blue: blue)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let components = hexColorComponents(hex)
        self.init(.sRGB, red: components.red, green: components.green, blue: components.blue, opacity: opacity)
    }
}

/// Pure selector for the adaptive color's two raw values — unit-testable
/// without SwiftUI or a trait collection.
func resolvedHex(lightHex: UInt32, darkHex: UInt32, isDark: Bool) -> UInt32 {
    isDark ? darkHex : lightHex
}

extension Color {
    /// Adaptive color: resolves `lightHex` in light mode, `darkHex` in dark mode.
    /// Backed by `UIColor(dynamicProvider:)` so it re-resolves on trait changes.
    init(lightHex: UInt32, darkHex: UInt32, opacity: Double = 1) {
        self.init(
            uiColor: UIColor { traits in
                let hex = resolvedHex(lightHex: lightHex, darkHex: darkHex, isDark: traits.userInterfaceStyle == .dark)
                let c = hexColorComponents(hex)
                return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: opacity)
            })
    }
}
