import XCTest

@testable import Schrift

final class MarkdownBlockViewTests: XCTestCase {

    // MARK: - Bare-URL autolinking

    func testAutolinksBareURL() {
        let result = markdownInlineText("Visit https://example.com now")
        let links = result.runs.compactMap { $0.link }
        XCTAssertEqual(links, [URL(string: "https://example.com")!])
    }

    func testPreservesMarkdownLinkWithoutDoubleLinking() {
        let result = markdownInlineText("See [the site](https://example.com/x)")
        let links = result.runs.compactMap { $0.link }
        XCTAssertEqual(links, [URL(string: "https://example.com/x")!])
        // The raw markdown syntax is consumed, not shown.
        XCTAssertFalse(String(result.characters).contains("]("))
    }

    func testPlainTextHasNoLinks() {
        let result = markdownInlineText("just some words")
        XCTAssertTrue(result.runs.allSatisfy { $0.link == nil })
    }

    func testAutolinkExcludesTrailingComma() {
        let result = markdownInlineText("(https://api.example.com/v1/mcp, more)")
        XCTAssertEqual(result.runs.compactMap { $0.link }, [URL(string: "https://api.example.com/v1/mcp")!])
    }

    // MARK: - Standalone image parsing

    func testParsesImage() {
        let parsed = parseStandaloneImage("![photo.png](https://docs.llun.dev/media/x.png)")
        XCTAssertEqual(parsed?.alt, "photo.png")
        XCTAssertEqual(parsed?.url, URL(string: "https://docs.llun.dev/media/x.png"))
    }

    func testParsesImageWithSpacesInAlt() {
        let parsed = parseStandaloneImage("![photo (1).png](https://docs.llun.dev/a.png)")
        XCTAssertEqual(parsed?.alt, "photo (1).png")
        XCTAssertEqual(parsed?.url, URL(string: "https://docs.llun.dev/a.png"))
    }

    func testParsesImageWithEmptyAlt() {
        XCTAssertEqual(parseStandaloneImage("![](https://a.dev/b.png)")?.alt, "")
    }

    func testRejectsNonHttpImageURL() {
        XCTAssertNil(parseStandaloneImage("![x](file:///etc/passwd)"))
        XCTAssertNil(parseStandaloneImage("![x](/relative/path.png)"))
    }

    func testRejectsImageWithTrailingText() {
        XCTAssertNil(parseStandaloneImage("![x](https://a.dev/b.png) caption"))
    }

    func testRejectsMultiLineImage() {
        XCTAssertNil(parseStandaloneImage("![x](https://a.dev/b.png)\nmore"))
    }

    func testNonImageReturnsNil() {
        XCTAssertNil(parseStandaloneImage("just text"))
        XCTAssertNil(parseStandaloneImage("[a link](https://a.dev)"))
    }

    // MARK: - Unknown-block prose detection

    func testMultiLineProseIsProse() {
        XCTAssertTrue(unknownRendersAsProse("Line one\nLine two with https://x.dev link"))
    }

    func testTableIsNotProse() {
        XCTAssertFalse(unknownRendersAsProse("| a | b |\n| - | - |"))
    }

    func testHTMLIsNotProse() {
        XCTAssertFalse(unknownRendersAsProse("<div>hi</div>"))
    }

    func testIndentedContentIsNotProse() {
        XCTAssertFalse(unknownRendersAsProse("    indented code"))
    }

    func testStandaloneImageIsNotProse() {
        XCTAssertFalse(unknownRendersAsProse("![x](https://a.dev/b.png)"))
    }

    func testEmptyIsNotProse() {
        XCTAssertFalse(unknownRendersAsProse(""))
    }
}
