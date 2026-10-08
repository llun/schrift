import CoreText
import UIKit
import XCTest

@testable import Schrift

final class MaterialIconTests: XCTestCase {
    func testCoversEveryHandoffGlyph() {
        // 69 from the handoff (brand-iconography.html) + 11 app-specific Material
        // Symbols the iOS app needs that the mockups didn't surface.
        XCTAssertEqual(MaterialIcon.allCases.count, 80)
    }

    func testKnownCodepoints() {
        XCTAssertEqual(MaterialIcon.share.codepoint, 0xe80d)
        XCTAssertEqual(MaterialIcon.account_tree.codepoint, 0xe97a)
        XCTAssertEqual(MaterialIcon.edit.codepoint, 0xf097)
        XCTAssertEqual(MaterialIcon.description.codepoint, 0xe873)
        XCTAssertEqual(MaterialIcon.push_pin.codepoint, 0xf10d)
        XCTAssertEqual(MaterialIcon.`public`.codepoint, 0xe80b)
        XCTAssertEqual(MaterialIcon.format_indent_increase.codepoint, 0xe23e)
        XCTAssertEqual(MaterialIcon.format_indent_decrease.codepoint, 0xe23d)
        XCTAssertEqual(MaterialIcon.attach_file.codepoint, 0xe226)
    }

    func testBundledFontHasAGlyphForEveryIcon() {
        // The font is a subset, so an icon added to the enum without re-subsetting
        // renders as an empty box. Ask the registered font for each glyph.
        guard let font = UIFont(name: MaterialSymbolFont.postScriptName, size: 24) else {
            return XCTFail("Material Symbols font not registered")
        }
        let ctFont = font as CTFont
        for icon in MaterialIcon.allCases {
            let characters = Array(String(icon.character).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            XCTAssertTrue(
                CTFontGetGlyphsForCharacters(ctFont, characters, &glyphs, characters.count),
                "\(icon.rawValue) is missing from the bundled font subset")
        }
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
