import XCTest

@testable import Schrift

final class InlineMarkdownTests: XCTestCase {
    private func keys(_ run: InlineRun) -> [String] { run.marks.map(\.key) }

    func testPlainTextIsASingleUnmarkedRun() {
        let runs = InlineMarkdown.parse("just plain text")
        XCTAssertEqual(runs, [InlineRun("just plain text")])
    }

    func testBold() {
        let runs = InlineMarkdown.parse("a **bold** b")
        XCTAssertEqual(runs.map(\.text), ["a ", "bold", " b"])
        XCTAssertEqual(keys(runs[1]), ["bold"])
        XCTAssertEqual(runs[1].marks.first?.valueJSON, "{}")
    }

    func testItalic() {
        let runs = InlineMarkdown.parse("a *it* b")
        XCTAssertEqual(runs.map(\.text), ["a ", "it", " b"])
        XCTAssertEqual(keys(runs[1]), ["italic"])
    }

    func testInlineCodeContentIsLiteral() {
        let runs = InlineMarkdown.parse("run `**not bold**` here")
        XCTAssertEqual(runs.map(\.text), ["run ", "**not bold**", " here"])
        XCTAssertEqual(keys(runs[1]), ["code"])
    }

    func testStrikethrough() {
        let runs = InlineMarkdown.parse("~~gone~~ text")
        XCTAssertEqual(runs.map(\.text), ["gone", " text"])
        XCTAssertEqual(keys(runs[0]), ["strike"])
    }

    func testLinkCarriesHref() throws {
        let runs = InlineMarkdown.parse("see [docs](https://example.com/x) now")
        XCTAssertEqual(runs.map(\.text), ["see ", "docs", " now"])
        XCTAssertEqual(keys(runs[1]), ["link"])
        let json = try XCTUnwrap(runs[1].marks.first?.valueJSON.data(using: .utf8))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: String])
        XCTAssertEqual(obj["href"], "https://example.com/x")
    }

    /// Both halves of the flanking rule in one line: intra-word underscores are
    /// content, word-boundary ones are emphasis. The scanner used to protect
    /// `snake_case` by ignoring every `_`, which cost it the emphasis.
    func testUnderscoresProtectSnakeCaseYetStillEmphasize() {
        let runs = InlineMarkdown.parse("call snake_case_name and _really italic_")
        XCTAssertEqual(runs.map(\.text), ["call snake_case_name and ", "really italic"])
        XCTAssertTrue(runs[0].marks.isEmpty)
        XCTAssertEqual(keys(runs[1]), ["italic"])
    }

    func testUnmatchedDelimiterStaysLiteral() {
        XCTAssertEqual(InlineMarkdown.parse("2 * 3 = 6"), [InlineRun("2 * 3 = 6")])
        XCTAssertEqual(InlineMarkdown.parse("unterminated **bold"), [InlineRun("unterminated **bold")])
    }

    func testBackslashEscapesAreLiteral() {
        let runs = InlineMarkdown.parse("\\*not italic\\* and \\`not code\\`")
        XCTAssertEqual(runs, [InlineRun("*not italic* and `not code`")])
    }

    func testEmptyStringYieldsNoRuns() {
        XCTAssertEqual(InlineMarkdown.parse(""), [])
    }

    func testAdjacentBackticksStayLiteral() {
        // An empty code span is not a code span (matching CommonMark/BlockNote);
        // it must not emit a zero-length code run.
        XCTAssertEqual(InlineMarkdown.parse("a``b"), [InlineRun("a``b")])
    }

    func testBackslashInsideCodeSpanIsLiteralContent() {
        // Code span content is literal: the backslash does not escape the
        // closing backtick, so the span closes at the first backtick.
        let runs = InlineMarkdown.parse("`x\\`y")
        XCTAssertEqual(runs.map(\.text), ["x\\", "y"])
        XCTAssertEqual(keys(runs[0]), ["code"])
        XCTAssertTrue(runs[1].marks.isEmpty)
    }

    // MARK: - Underscore emphasis (CommonMark flanking)
    //
    // The rule and its saved-byte delta are recorded in the
    // "Editor & the on-device save" section of `CLAUDE.md`.
    // Each case below was cross-checked against Foundation's
    // `AttributedString(markdown:)` — the reading surface, and the oracle this
    // scanner converges on.

    func testLoneUnderscoresAreEmphasis() {
        let runs = InlineMarkdown.parse("a _it_ b")
        XCTAssertEqual(runs.map(\.text), ["a ", "it", " b"])
        XCTAssertEqual(keys(runs[1]), ["italic"])
        XCTAssertEqual(runs[1].marks.first?.valueJSON, "{}")
    }

    /// The whole point of the flanking rule: intra-word underscores are content.
    func testIntraWordUnderscoresStayLiteral() {
        for source in ["snake_case", "snake_case_name", "a_b_c", "5_000_000", "_snake_case", "snake_case_"] {
            XCTAssertEqual(InlineMarkdown.parse(source), [InlineRun(source)], "\(source) must stay literal")
        }
    }

    /// What BlockNote exports for bold+italic. Before the flanking rule this
    /// parsed as bold(`_word_`) — the italic destroyed and the underscores
    /// written into the document's saved text on the next full-overwrite save.
    func testBoldItalicRoundTripsAsBothMarks() {
        let runs = InlineMarkdown.parse("**_word_**")
        XCTAssertEqual(runs.map(\.text), ["word"])
        XCTAssertEqual(keys(runs[0]), ["bold", "italic"])
    }

    /// Marks are carried outermost-first, and the order is part of the wire format.
    func testItalicOutsideBoldCarriesItalicFirst() {
        let runs = InlineMarkdown.parse("_**word**_")
        XCTAssertEqual(runs.map(\.text), ["word"])
        XCTAssertEqual(keys(runs[0]), ["italic", "bold"])
    }

    /// A BlockNote format map has one entry per key, and CommonMark collapses
    /// `*_x_*` to a single `<em>`. Emitting `italic` twice would be a wire-format
    /// defect the golden hex tests cannot see — they hand-build their runs.
    func testNestedIdenticalEmphasisEmitsTheMarkOnce() {
        for source in ["*_word_*", "_*word*_"] {
            let runs = InlineMarkdown.parse(source)
            XCTAssertEqual(runs.map(\.text), ["word"], source)
            XCTAssertEqual(keys(runs[0]), ["italic"], "\(source) must not duplicate the italic key")
        }
    }

    /// A `_` is a delimiter only when it stands alone, so runs of two or more
    /// stay literal — which is what holds `___` (the divider) and every existing
    /// `__x__` document byte-identical.
    func testUnderscoreRunsOfTwoOrMoreStayLiteral() {
        for source in ["__word__", "___word___", "snake__case", "___", "__"] {
            XCTAssertEqual(InlineMarkdown.parse(source), [InlineRun(source)], "\(source) must stay literal")
        }
    }

    /// CommonMark closes emphasis at the last underscore here, not the first:
    /// the interior `_` is left-flanking and not followed by punctuation, so it
    /// cannot close.
    func testInteriorUnderscoreCannotCloseEmphasis() {
        let runs = InlineMarkdown.parse("_foo_bar_")
        XCTAssertEqual(runs.map(\.text), ["foo_bar"])
        XCTAssertEqual(keys(runs[0]), ["italic"])
    }

    func testUnderscoreRunInsideEmphasisStaysLiteral() {
        let runs = InlineMarkdown.parse("_a__b_")
        XCTAssertEqual(runs.map(\.text), ["a__b"])
        XCTAssertEqual(keys(runs[0]), ["italic"])
    }

    /// An opener may not be followed by whitespace, nor a closer preceded by it.
    func testWhitespaceFlankedUnderscoresStayLiteral() {
        for source in ["_ word _", "_ x_", "_x _", "_ _"] {
            XCTAssertEqual(InlineMarkdown.parse(source), [InlineRun(source)], "\(source) must stay literal")
        }
    }

    /// An unmatched opener is content, not a dangling delimiter.
    func testUnmatchedUnderscoreStaysLiteral() {
        for source in ["_x_y", "x_y_", "a_b", "_"] {
            XCTAssertEqual(InlineMarkdown.parse(source), [InlineRun(source)], "\(source) must stay literal")
        }
    }

    /// CommonMark's "Unicode punctuation" is ASCII punctuation ∪ `P*` — it does
    /// **not** include `So`/`Sc` symbols, though `Character.isSymbol` is true for
    /// all three of these. Foundation agrees: `a+_x_+a` is emphasis while
    /// `😀_x_😀` and `€_x_€` are literal.
    func testPunctuationFlankingFollowsCommonMarkNotIsSymbol() {
        for source in ["(_x_)", "“_x_”", "a+_x_+a"] {
            let runs = InlineMarkdown.parse(source)
            XCTAssertEqual(runs.first(where: { !$0.marks.isEmpty })?.text, "x", "\(source) must emphasize")
            XCTAssertEqual(keys(runs.first(where: { !$0.marks.isEmpty })!), ["italic"], source)
        }
        for source in ["😀_x_😀", "€_x_€"] {
            XCTAssertEqual(InlineMarkdown.parse(source), [InlineRun(source)], "\(source) must stay literal")
        }
    }

    func testEscapedUnderscoresStayLiteral() {
        XCTAssertEqual(InlineMarkdown.parse("\\_x\\_"), [InlineRun("_x_")])
    }

    func testUnderscoresInsideACodeSpanAreLiteral() {
        let runs = InlineMarkdown.parse("`_x_`")
        XCTAssertEqual(runs.map(\.text), ["_x_"])
        XCTAssertEqual(keys(runs[0]), ["code"])
    }

    func testEmphasisInsideALinkLabel() {
        let runs = InlineMarkdown.parse("[_x_](https://example.com)")
        XCTAssertEqual(runs.map(\.text), ["x"])
        XCTAssertEqual(keys(runs[0]), ["link", "italic"])
    }

    /// A url is never inline-parsed, so word-boundary underscores inside one
    /// survive verbatim: the backend matches the destination byte-for-byte.
    func testUnderscoresInAURLAreNotEmphasis() throws {
        let runs = InlineMarkdown.parse("[x](https://example.com/_a_)")
        XCTAssertEqual(runs.map(\.text), ["x"])
        let href = try XCTUnwrap(runs[0].marks.first?.valueJSON)
        XCTAssertEqual(href, "{\"href\":\"https://example.com/_a_\"}")
    }

    // MARK: Code spans and links bind tighter than emphasis
    //
    // Differential fuzzing caught both of these: the closing search walked raw
    // characters, so emphasis closed on a `_` *inside* a code span or a link
    // destination and tore it apart — which a full-overwrite save would persist.

    /// The `_` inside the code span is content, so nothing closes the opener and
    /// the leading `_` stays literal.
    func testEmphasisDoesNotCloseInsideACodeSpan() {
        let runs = InlineMarkdown.parse("_`_`")
        XCTAssertEqual(runs.map(\.text), ["_", "_"])
        XCTAssertTrue(runs[0].marks.isEmpty)
        XCTAssertEqual(keys(runs[1]), ["code"])
    }

    /// The emphasis closes at the final `_`, stepping over the code span whole.
    func testEmphasisSpansACodeSpanWithoutClosingInsideIt() {
        let runs = InlineMarkdown.parse("_a`b_c`d_")
        XCTAssertEqual(runs.map(\.text), ["a", "b_c", "d"])
        XCTAssertEqual(keys(runs[0]), ["italic"])
        XCTAssertEqual(keys(runs[1]), ["italic", "code"])
        XCTAssertEqual(keys(runs[2]), ["italic"])
    }

    /// A `_` in a link destination must not close emphasis opened outside it, or
    /// the link is destroyed.
    func testEmphasisDoesNotCloseInsideALinkDestination() throws {
        let runs = InlineMarkdown.parse("_[x](a_ b)_")
        XCTAssertEqual(runs.map(\.text), ["x"])
        XCTAssertEqual(keys(runs[0]), ["italic", "link"])
        XCTAssertEqual(runs[0].marks.last?.valueJSON, "{\"href\":\"a_ b\"}")
    }

    /// Emphasis nested in a link label that is itself inside emphasis collapses to
    /// one `italic` key — the dedupe, exercised through two layers.
    func testEmphasisAroundALinkWhoseLabelIsAlsoEmphasized() {
        let runs = InlineMarkdown.parse("_[_x_](u)_")
        XCTAssertEqual(runs.map(\.text), ["x"])
        XCTAssertEqual(keys(runs[0]), ["italic", "link"])
    }

    /// Delimiter soup: `_` and `*` competing for the same characters. The leftmost
    /// opener wins, which is what CommonMark does too — and what
    /// `AttributedString(markdown:)` renders. Pinned so the choice stays deliberate.
    func testMixedUnderscoreAndAsteriskSoupLetsTheLeftmostOpenerWin() {
        let runs = InlineMarkdown.parse("_*_*")
        XCTAssertEqual(runs.map(\.text), ["*", "*"])
        XCTAssertEqual(keys(runs[0]), ["italic"])
        XCTAssertTrue(runs[1].marks.isEmpty)
    }

    // MARK: Emphasis pairs with the nearest opener, not the first closer
    //
    // A leading `_` must not reach past a later `_word` to grab a distant closer,
    // or it italicizes text the user (and the reading surface) meant as literal.
    // Cross-checked against Foundation.

    /// The reviewer's case: `_foo ` stays literal, only `bar` is emphasized.
    func testAnUnclosedLeadingUnderscoreDoesNotSwallowLaterEmphasis() {
        let runs = InlineMarkdown.parse("_foo _bar_")
        XCTAssertEqual(runs.map(\.text), ["_foo ", "bar"])
        XCTAssertTrue(runs[0].marks.isEmpty)
        XCTAssertEqual(keys(runs[1]), ["italic"])
    }

    /// Realistic prose form of the same shape.
    func testALeadingUnderscoreWordBeforeRealEmphasisStaysLiteral() {
        let runs = InlineMarkdown.parse("the _config and _value_ matter")
        XCTAssertEqual(runs.map(\.text), ["the _config and ", "value", " matter"])
        XCTAssertEqual(keys(runs[1]), ["italic"])
        XCTAssertTrue(runs[0].marks.isEmpty)
        XCTAssertTrue(runs[2].marks.isEmpty)
    }

    /// Two adjacent complete emphases still both parse — the nearest-opener rule
    /// only stops a reach *past* an unclosed opener.
    func testTwoAdjacentEmphasesBothParse() {
        let runs = InlineMarkdown.parse("_a_ _b_")
        XCTAssertEqual(runs.map(\.text), ["a", " ", "b"])
        XCTAssertEqual(keys(runs[0]), ["italic"])
        XCTAssertEqual(keys(runs[2]), ["italic"])
    }
}
