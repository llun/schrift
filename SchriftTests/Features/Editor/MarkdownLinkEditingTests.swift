import XCTest

@testable import Schrift

final class MarkdownLinkEditingTests: XCTestCase {

    // MARK: - Locating

    func testLinkSpanFindsTheLinkUnderAnOffset() throws {
        let text = "see [docs](https://x.dev/) now"
        let span = try XCTUnwrap(linkSpan(in: text, containing: 6))
        XCTAssertEqual(span.label, "docs")
        XCTAssertEqual(span.url, "https://x.dev/")
    }

    func testLinkSpanCoversTheHiddenSyntaxToo() {
        let text = "see [docs](https://x.dev/) now"
        // The opening `[` at 4 and the closing `)` at 25 both belong to the link.
        XCTAssertNotNil(linkSpan(in: text, containing: 4))
        XCTAssertNotNil(linkSpan(in: text, containing: 25))
        // 26 is the space after it.
        XCTAssertNil(linkSpan(in: text, containing: 26))
        XCTAssertNil(linkSpan(in: text, containing: 0))
    }

    // MARK: - Insert

    func testInsertingALinkAtACollapsedCaret() {
        let edit = insertMarkdownLink(
            in: "go now", range: NSRange(location: 3, length: 0), label: "here", url: "https://x.dev/")
        XCTAssertEqual(edit.text, "go [here](https://x.dev/)now")
        // "[here](https://x.dev/)" is 22 characters.
        XCTAssertEqual(edit.selection, NSRange(location: 3 + 22, length: 0))
    }

    func testInsertingALinkWrapsTheSelection() {
        let edit = insertMarkdownLink(
            in: "go here now", range: NSRange(location: 3, length: 4), label: "here", url: "https://x.dev/")
        XCTAssertEqual(edit.text, "go [here](https://x.dev/) now")
    }

    /// The caret lands after the link so typing on does not extend it — the
    /// non-inclusive behaviour the web editor has.
    func testCaretLandsAfterTheInsertedLink() {
        let edit = insertMarkdownLink(in: "", range: NSRange(location: 0, length: 0), label: "a", url: "https://x.dev/")
        XCTAssertEqual(edit.text, "[a](https://x.dev/)")
        XCTAssertEqual(edit.selection, NSRange(location: 19, length: 0))
        XCTAssertNil(linkSpan(in: edit.text, containing: edit.selection.location))
    }

    func testAnInsertedLinkParsesBackAsExactlyThatLink() throws {
        let edit = insertMarkdownLink(
            in: "x", range: NSRange(location: 1, length: 0), label: "a]b[c", url: "https://x.dev/p")
        let span = try XCTUnwrap(InlineMarkdown.layout(of: edit.text).links.first)
        XCTAssertEqual(span.label, "a]b[c")
        XCTAssertEqual(span.url, "https://x.dev/p")
    }

    // MARK: - Replace

    func testReplacingRetargetsTheLinkInPlace() throws {
        let text = "see [docs](https://x.dev/) now"
        let span = try XCTUnwrap(linkSpan(in: text, containing: 6))
        let edit = replaceMarkdownLink(in: text, span: span, label: "guide", url: "https://y.dev/")
        XCTAssertEqual(edit.text, "see [guide](https://y.dev/) now")
    }

    // MARK: - Remove

    func testRemovingKeepsTheLabelAndDropsTheSyntax() throws {
        let text = "see [docs](https://x.dev/) now"
        let span = try XCTUnwrap(linkSpan(in: text, containing: 6))
        let edit = removeMarkdownLink(in: text, span: span)
        XCTAssertEqual(edit.text, "see docs now")
        XCTAssertEqual(edit.selection, NSRange(location: 8, length: 0))
    }

    /// The raw label is kept, escapes and all. Re-inserting the *displayed*
    /// label `*text*` would silently turn the leftover into italics.
    func testRemovingPreservesTheLabelsEscapes() throws {
        let text = "[\\*not italic\\*](https://x.dev/)"
        let span = try XCTUnwrap(linkSpan(in: text, containing: 2))
        XCTAssertEqual(span.label, "*not italic*")
        let edit = removeMarkdownLink(in: text, span: span)
        XCTAssertEqual(edit.text, "\\*not italic\\*")
        // Still literal text, still not italic.
        XCTAssertEqual(InlineMarkdown.parse(edit.text), [InlineRun("*not italic*")])
    }

    // MARK: - Label escaping

    func testEscapingBracketsAndBackslashes() {
        XCTAssertEqual(escapedLinkLabel("a]b"), "a\\]b")
        XCTAssertEqual(escapedLinkLabel("a[b"), "a\\[b")
        XCTAssertEqual(escapedLinkLabel("a\\b"), "a\\\\b")
        XCTAssertEqual(escapedLinkLabel("plain"), "plain")
    }

    func testNewlinesInALabelBecomeSpaces() {
        XCTAssertEqual(escapedLinkLabel("a\nb"), "a b")
    }

    // MARK: - URL sanitizing

    func testAcceptsTheAllowedSchemes() {
        XCTAssertEqual(sanitizedLinkURL("https://x.dev/a"), "https://x.dev/a")
        XCTAssertEqual(sanitizedLinkURL("http://x.dev"), "http://x.dev")
        XCTAssertEqual(sanitizedLinkURL("mailto:a@b.dev"), "mailto:a@b.dev")
        XCTAssertEqual(sanitizedLinkURL("tel:+15551234"), "tel:+15551234")
    }

    func testPrependsHTTPSToASchemelessInput() {
        XCTAssertEqual(sanitizedLinkURL("x.dev/a"), "https://x.dev/a")
        XCTAssertEqual(sanitizedLinkURL("  x.dev  "), "https://x.dev")
    }

    func testRejectsDangerousSchemes() {
        XCTAssertNil(sanitizedLinkURL("javascript:alert"))
        XCTAssertNil(sanitizedLinkURL("JavaScript:alert"))
        XCTAssertNil(sanitizedLinkURL("data:text/html;base64,abc"))
        XCTAssertNil(sanitizedLinkURL("file:///etc/passwd"))
    }

    /// `InlineMarkdown.matchLink` ends the destination at the first `)` and never
    /// unescapes it, so no parenthesised URL survives the round trip. Rejecting
    /// is the only option that cannot save a mangled link.
    func testRejectsParenthesesBecauseTheyWouldTruncateOnSave() {
        XCTAssertNil(sanitizedLinkURL("https://x.dev/a(1)"))
        XCTAssertNil(sanitizedLinkURL("https://x.dev/a)b"))
    }

    func testRejectsBackslashesBecauseTheyWouldSwallowTheClosingParen() {
        XCTAssertNil(sanitizedLinkURL("https://x.dev/a\\"))
    }

    func testRejectsWhitespaceAndEmptyInput() {
        XCTAssertNil(sanitizedLinkURL(""))
        XCTAssertNil(sanitizedLinkURL("   "))
        XCTAssertNil(sanitizedLinkURL("https://x.dev/a b"))
        XCTAssertNil(sanitizedLinkURL("https://x.dev/a\nb"))
    }

    func testRejectsASchemeWithNoHost() {
        XCTAssertNil(sanitizedLinkURL("https://"))
    }

    /// Everything `sanitizedLinkURL` accepts must survive being written into a
    /// link and read back by the save parser, byte for byte.
    func testEverySanitizedURLRoundTripsThroughTheSaveParser() throws {
        let inputs = ["https://x.dev/a", "http://x.dev", "mailto:a@b.dev", "tel:+15551234", "x.dev/a?q=1#f"]
        for input in inputs {
            let url = try XCTUnwrap(sanitizedLinkURL(input), input)
            let edit = insertMarkdownLink(in: "", range: NSRange(location: 0, length: 0), label: "L", url: url)
            let span = try XCTUnwrap(InlineMarkdown.layout(of: edit.text).links.first, input)
            XCTAssertEqual(span.url, url, "url mangled for \(input)")
            XCTAssertEqual(span.label, "L", "label mangled for \(input)")
        }
    }
}
