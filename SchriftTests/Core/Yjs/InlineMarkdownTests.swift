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

    func testUnderscoresStayLiteralToProtectSnakeCase() {
        let runs = InlineMarkdown.parse("call snake_case_name and _not italic_")
        XCTAssertEqual(runs, [InlineRun("call snake_case_name and _not italic_")])
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
}
