import XCTest

@testable import Schrift

final class DocIconTests: XCTestCase {
    func testCustomEmojiIsDisplayed() {
        XCTAssertEqual(docIconDisplayText(emoji: "📄"), "📄")
    }

    func testMissingOrEmptyEmojiFallsBackToDefaultGlyph() {
        XCTAssertNil(docIconDisplayText(emoji: nil))
        XCTAssertNil(docIconDisplayText(emoji: ""))
    }
}
