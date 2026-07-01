import SwiftUI

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
