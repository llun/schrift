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

    func testBareURLAndMarkdownLinkCoexist() {
        let result = markdownInlineText("[site](https://a.dev/x) and https://b.dev")
        XCTAssertEqual(
            result.runs.compactMap { $0.link },
            [URL(string: "https://a.dev/x")!, URL(string: "https://b.dev")!])
        XCTAssertFalse(String(result.characters).contains("]("))
    }

    func testPreservesLineBreaks() {
        // The `.inlineOnlyPreservingWhitespace` option keeps hard line breaks so
        // multi-line `.unknown` prose still renders across lines.
        XCTAssertTrue(String(markdownInlineText("Line one\nLine two").characters).contains("\n"))
    }

    // Standalone-image classification now lives in the parser
    // (`parseImageLine` → `.image` blocks); see MarkdownParserTests.
    // Off-origin image gating (which images auto-load vs tap-to-load) lives in
    // `imageLoadPolicy`; see ImageLoadPolicyTests.

    // MARK: - Unknown-block prose detection

    func testMultiLineProseIsProse() {
        XCTAssertTrue(unknownRendersAsProse("Line one\nLine two with https://x.dev link"))
    }

    func testTableIsNotProse() {
        XCTAssertFalse(unknownRendersAsProse("| a | b |\n| - | - |"))
    }

    func testStructuralMarkerOnLaterLineIsNotProse() {
        // Every line is scanned, not just the first: a prose opener followed by
        // a table row must still bail out to verbatim rendering.
        XCTAssertFalse(unknownRendersAsProse("Intro text\n| a | b |"))
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
