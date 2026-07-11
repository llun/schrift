import UIKit
import XCTest

@testable import Schrift

final class MaterialIconTests: XCTestCase {
    func testCoversEveryHandoffGlyph() {
        // 69 from the handoff (brand-iconography.html) + 8 app-specific Material
        // Symbols the iOS app needs that the mockups didn't surface.
        XCTAssertEqual(MaterialIcon.allCases.count, 77)
    }

    func testKnownCodepoints() {
        XCTAssertEqual(MaterialIcon.share.codepoint, 0xe80d)
        XCTAssertEqual(MaterialIcon.account_tree.codepoint, 0xe97a)
        XCTAssertEqual(MaterialIcon.edit.codepoint, 0xf097)
        XCTAssertEqual(MaterialIcon.description.codepoint, 0xe873)
        XCTAssertEqual(MaterialIcon.push_pin.codepoint, 0xf10d)
        XCTAssertEqual(MaterialIcon.`public`.codepoint, 0xe80b)
    }

    func testEveryGlyphHasARenderableScalar() {
        for icon in MaterialIcon.allCases {
            XCTAssertNotNil(Unicode.Scalar(icon.codepoint), "\(icon.rawValue) has an invalid scalar")
        }
    }

    func testBundledFontIsRegistered() {
        // UIAppFonts should have registered the subset by its PostScript name.
        XCTAssertNotNil(
            UIFont(name: MaterialSymbolFont.postScriptName, size: 24),
            "Material Symbols font not registered — check UIAppFonts / bundled ttf")
    }
}
