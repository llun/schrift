import SwiftUI
import UIKit
import XCTest

@testable import Schrift

final class HexColorTests: XCTestCase {
    func testResolvedHexPicksByStyle() {
        XCTAssertEqual(resolvedHex(lightHex: 0xFFFFFF, darkHex: 0x000000, isDark: false), 0xFFFFFF)
        XCTAssertEqual(resolvedHex(lightHex: 0xFFFFFF, darkHex: 0x000000, isDark: true), 0x000000)
    }

    func testAdaptiveColorResolvesBothStyles() {
        let color = UIColor(Color(lightHex: 0xFFFFFF, darkHex: 0x000000))
        let light = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let dark = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var lr: CGFloat = 0
        var dr: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        light.getRed(&lr, green: &g, blue: &b, alpha: &a)
        dark.getRed(&dr, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(lr, 1, accuracy: 0.01)
        XCTAssertEqual(dr, 0, accuracy: 0.01)
    }
}
