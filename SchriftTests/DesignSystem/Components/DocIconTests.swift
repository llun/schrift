import XCTest
@testable import Schrift

final class DocIconTests: XCTestCase {
    func testCustomEmojiIsDisplayed() {
        XCTAssertEqual(docIconDisplayText(emoji: "📄"), "📄")
    }

    func testNilEmojiFallsBackToDefaultGlyph() {
        XCTAssertNil(docIconDisplayText(emoji: nil))
    }

    func testEmptyEmojiFallsBackToDefaultGlyph() {
        XCTAssertNil(docIconDisplayText(emoji: ""))
    }
}
