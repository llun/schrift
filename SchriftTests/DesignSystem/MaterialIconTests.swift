import CoreText
import UIKit
import XCTest

@testable import Schrift

final class MaterialIconTests: XCTestCase {
    func testBundledFontHasAGlyphForEveryIcon() {
        // The font is a subset, so an icon added to the enum without re-subsetting
        // renders as an empty box. Ask the registered font for each glyph.
        guard let font = UIFont(name: MaterialSymbolFont.postScriptName, size: 24) else {
            return XCTFail("Material Symbols font not registered — check UIAppFonts / bundled ttf")
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
}
