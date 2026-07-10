import XCTest

@testable import Schrift

/// `InlineMarkdown.layout(of:)` is what the block editor styles from, and
/// `InlineMarkdown.parse(_:)` is what the full-overwrite save encodes. They are
/// one scanner, so these tests pin the properties the editor relies on — above
/// all that visible content and hidden syntax **partition** the source exactly.
final class InlineLayoutTests: XCTestCase {

    /// Every source the editor might hold. Reused by the invariant tests, which
    /// are the real safety net: they hold for inputs nobody thought to enumerate.
    private let corpus = [
        "",
        "just plain text",
        "a **bold** b",
        "a *it* b",
        "run `**not bold**` here",
        "~~gone~~ text",
        "see [docs](https://example.com/x) now",
        "call snake_case_name and _not italic_",
        "2 * 3 = 6",
        "unterminated **bold",
        "\\*not italic\\* and \\`not code\\`",
        "a``b",
        "`x\\`y",
        "[✅ Review](https://docs.llun.dev/docs/0d08a528-8657-4e20-9cb9-a1b4578b77b8/)",
        "[**bold link**](https://example.com/)",
        "🇫🇷 flag then [👍🏽 thumbs](https://example.com/) tail",
        "[a](b) [c](d)",
        "![img](https://example.com/i.png)",
        "trailing backslash \\",
        "[unclosed](https://example.com",
        "empty []() link",
        "*a* **b** `c` ~~d~~ [e](f)",
    ]

    private func nsRanges(_ layout: InlineLayout) -> [NSRange] {
        (layout.spans.map(\.range) + layout.syntax).sorted { $0.location < $1.location }
    }

    // MARK: - The partition invariant

    func testSpansAndSyntaxPartitionTheSourceExactly() {
        for source in corpus {
            let layout = InlineMarkdown.layout(of: source)
            let all = nsRanges(layout)
            var cursor = 0
            for range in all {
                XCTAssertEqual(range.location, cursor, "gap or overlap in \(source.debugDescription)")
                XCTAssertGreaterThan(range.length, 0, "empty range in \(source.debugDescription)")
                cursor = range.location + range.length
            }
            XCTAssertEqual(cursor, (source as NSString).length, "did not cover \(source.debugDescription)")
        }
    }

    func testVisibleTextIsTheConcatenationOfSpans() {
        let source = "a \\*b\\* **c** `d` [e](https://x.dev/)"
        let layout = InlineMarkdown.layout(of: source)
        let ns = source as NSString
        let visible = layout.spans.map { ns.substring(with: $0.range) }.joined()
        XCTAssertEqual(visible, "a *b* c d e")
    }

    /// The save path and the editor's styling must agree character for
    /// character. If this ever fails, the editor is styling something that
    /// saves differently — the exact class of bug this design exists to prevent.
    func testParseIsAProjectionOfLayout() {
        for source in corpus {
            let ns = source as NSString
            let layout = InlineMarkdown.layout(of: source)
            let fromLayout = layout.spans.map { ns.substring(with: $0.range) }.joined()
            let fromParse = InlineMarkdown.parse(source).map(\.text).joined()
            XCTAssertEqual(fromLayout, fromParse, "diverged on \(source.debugDescription)")
        }
    }

    func testSpanMarksMatchTheRunMarksParseProduces() {
        for source in corpus {
            let layoutMarks = InlineMarkdown.layout(of: source).spans.map { $0.marks.map(\.key) }
            let parseMarks = InlineMarkdown.parse(source).map { $0.marks.map(\.key) }
            // `parse` coalesces adjacent identically-marked runs, so compare the
            // de-duplicated mark sequences rather than the counts.
            XCTAssertEqual(dedupeAdjacent(layoutMarks), dedupeAdjacent(parseMarks), "on \(source.debugDescription)")
        }
    }

    private func dedupeAdjacent(_ items: [[String]]) -> [[String]] {
        var result: [[String]] = []
        for item in items where result.last != item {
            result.append(item)
        }
        return result
    }

    // MARK: - Syntax is what gets hidden

    func testLinkSyntaxIsHiddenAndLabelIsVisible() {
        let source = "see [docs](https://example.com/x) now"
        let layout = InlineMarkdown.layout(of: source)
        let ns = source as NSString
        XCTAssertEqual(layout.syntax.map { ns.substring(with: $0) }, ["[", "](https://example.com/x)"])
        XCTAssertEqual(layout.spans.map { ns.substring(with: $0.range) }, ["see ", "docs", " now"])
    }

    func testEmphasisDelimitersAreSyntax() {
        let source = "a **b** c"
        let layout = InlineMarkdown.layout(of: source)
        let ns = source as NSString
        XCTAssertEqual(layout.syntax.map { ns.substring(with: $0) }, ["**", "**"])
    }

    func testBackslashIsSyntaxAndTheEscapedCharacterIsContent() {
        let source = "\\*x"
        let layout = InlineMarkdown.layout(of: source)
        let ns = source as NSString
        XCTAssertEqual(layout.syntax.map { ns.substring(with: $0) }, ["\\"])
        XCTAssertEqual(layout.spans.map { ns.substring(with: $0.range) }, ["*x"])
    }

    func testUnmatchedDelimitersStayVisible() {
        let source = "unterminated **bold"
        let layout = InlineMarkdown.layout(of: source)
        XCTAssertEqual(layout.syntax, [])
        XCTAssertEqual(layout.spans.count, 1)
        XCTAssertEqual(layout.spans[0].marks, [])
    }

    func testCodeSpanContentIsVisibleAndLiteral() {
        let source = "run `**x**` here"
        let layout = InlineMarkdown.layout(of: source)
        let ns = source as NSString
        XCTAssertEqual(layout.syntax.map { ns.substring(with: $0) }, ["`", "`"])
        let code = layout.spans.first { $0.marks == [.code] }
        XCTAssertEqual(code.map { ns.substring(with: $0.range) }, "**x**")
    }

    // MARK: - Links

    func testLinkSpanCarriesRangesLabelAndURL() throws {
        let source = "see [docs](https://example.com/x) now"
        let link = try XCTUnwrap(InlineMarkdown.layout(of: source).links.first)
        // "[docs](https://example.com/x)" — 1 + 4 + 2 + 21 + 1 = 29.
        XCTAssertEqual(link.range, NSRange(location: 4, length: 29))
        XCTAssertEqual((source as NSString).substring(with: link.range), "[docs](https://example.com/x)")
        XCTAssertEqual(link.labelRange, NSRange(location: 5, length: 4))
        XCTAssertEqual(link.label, "docs")
        XCTAssertEqual(link.url, "https://example.com/x")
    }

    func testLinkLabelResolvesEscapes() throws {
        let source = "[a\\]b](https://x.dev/)"
        let link = try XCTUnwrap(InlineMarkdown.layout(of: source).links.first)
        XCTAssertEqual(link.label, "a]b")
        XCTAssertEqual(link.url, "https://x.dev/")
    }

    func testNestedMarkInsideALinkLabel() throws {
        let source = "[**bold link**](https://example.com/)"
        let layout = InlineMarkdown.layout(of: source)
        let link = try XCTUnwrap(layout.links.first)
        XCTAssertEqual(link.label, "bold link")
        let span = try XCTUnwrap(layout.spans.first)
        XCTAssertEqual(span.marks, [.link(href: "https://example.com/"), .bold])
    }

    func testTwoLinksAreReportedInDocumentOrder() {
        let links = InlineMarkdown.layout(of: "[a](b) [c](d)").links
        XCTAssertEqual(links.map(\.label), ["a", "c"])
        XCTAssertEqual(links.map(\.url), ["b", "d"])
    }

    func testEmptyLabelOrURLIsNotALink() {
        XCTAssertEqual(InlineMarkdown.layout(of: "empty []() link").links, [])
        XCTAssertEqual(InlineMarkdown.layout(of: "[a]() x").links, [])
        XCTAssertEqual(InlineMarkdown.layout(of: "[](b) x").links, [])
    }

    // MARK: - UTF-16 offsets

    /// `NSRange` is UTF-16; `Array(String)` is grapheme clusters. A skin-toned
    /// thumb is one Character and four UTF-16 units, and a flag is two. Getting
    /// this wrong misplaces every hidden range after the first emoji.
    func testRangesAreUTF16OffsetsNotCharacterOffsets() throws {
        let source = "🇫🇷 flag then [👍🏽 thumbs](https://example.com/) tail"
        let ns = source as NSString
        let layout = InlineMarkdown.layout(of: source)
        let link = try XCTUnwrap(layout.links.first)
        XCTAssertEqual(ns.substring(with: link.range), "[👍🏽 thumbs](https://example.com/)")
        XCTAssertEqual(ns.substring(with: link.labelRange), "👍🏽 thumbs")
        XCTAssertEqual(link.label, "👍🏽 thumbs")
    }

    func testEmojiInsideALinkLabelKeepsTheLabelVisible() {
        let source = "[✅ Review](https://docs.llun.dev/docs/0d08a528-8657-4e20-9cb9-a1b4578b77b8/)"
        let ns = source as NSString
        let layout = InlineMarkdown.layout(of: source)
        XCTAssertEqual(layout.spans.map { ns.substring(with: $0.range) }, ["✅ Review"])
        XCTAssertEqual(layout.syntax.map { ns.substring(with: $0) }.first, "[")
    }

    // MARK: - What the save actually encodes

    /// `YjsEncoderTests` asserts golden bytes for hand-built `[InlineRun]`s — it
    /// never runs the scanner. So "the golden tests pass" alone does **not**
    /// prove the scanner still feeds the encoder the same runs.
    ///
    /// These tests close that gap: they pin `parse(_:)`'s output for the very
    /// markdown whose runs the golden fixtures encode. Together the two are a
    /// byte-level proof by transitivity — markdown → runs → bytes. Change either
    /// side and one of them fails.
    func testParseProducesExactlyTheRunsTheGoldenLinkFixtureEncodes() {
        XCTAssertEqual(
            InlineMarkdown.parse("See [docs](https://example.com) now"),
            [
                InlineRun("See "),
                InlineRun("docs", marks: [("link", "{\"href\":\"https://example.com\"}")]),
                InlineRun(" now"),
            ])
    }

    func testParseProducesExactlyTheRunsTheGoldenMultiMarkFixtureEncodes() {
        XCTAssertEqual(
            InlineMarkdown.parse("Some *italic* and **bold** and `code` here."),
            [
                InlineRun("Some "),
                InlineRun("italic", marks: [("italic", "{}")]),
                InlineRun(" and "),
                InlineRun("bold", marks: [("bold", "{}")]),
                InlineRun(" and "),
                InlineRun("code", marks: [("code", "{}")]),
                InlineRun(" here."),
            ])
    }

    func testParseProducesExactlyTheRunsTheGoldenStrikeFixtureEncodes() {
        XCTAssertEqual(
            InlineMarkdown.parse("~~gone~~ text"),
            [InlineRun("gone", marks: [("strike", "{}")]), InlineRun(" text")])
    }

    func testParseProducesExactlyTheRunsTheGoldenBoldFixtureEncodes() {
        XCTAssertEqual(
            InlineMarkdown.parse("Hello **world**"),
            [InlineRun("Hello "), InlineRun("world", marks: [("bold", "{}")])])
    }

    /// Mark **order** is part of the wire format: the encoder emits them in the
    /// order the runs carry them, so an outermost-last ordering would move bytes.
    func testNestedMarksAreCarriedOutermostFirst() {
        let runs = InlineMarkdown.parse("[**b**](u)")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].marks.map(\.key), ["link", "bold"])
        XCTAssertEqual(runs[0].marks.map(\.valueJSON), ["{\"href\":\"u\"}", "{}"])
    }
}
