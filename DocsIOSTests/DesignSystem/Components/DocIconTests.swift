import XCTest
@testable import DocsIOS

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
