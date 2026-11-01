import XCTest

@testable import Schrift

final class MarkdownTableTests: XCTestCase {

    // MARK: - Parsing

    /// The shape the server's markdown export writes: padded cells and a long
    /// delimiter row.
    func testParsesTheServerExportShape() throws {
        let table = try XCTUnwrap(
            parseMarkdownTable(
                """
                | Page                 | What it covers                     |
                | -------------------- | ---------------------------------- |
                | 🏗️ Architecture      | How the server is put together     |
                | ✨ Features          | One page per feature area          |
                """))
        XCTAssertEqual(table.header, ["Page", "What it covers"])
        XCTAssertEqual(table.alignments, [.unspecified, .unspecified])
        XCTAssertEqual(
            table.rows,
            [["🏗️ Architecture", "How the server is put together"], ["✨ Features", "One page per feature area"]])
    }

    func testReadsAlignmentsFromTheDelimiterRow() throws {
        let table = try XCTUnwrap(parseMarkdownTable("| a | b | c | d |\n| :-- | :-: | --: | --- |"))
        XCTAssertEqual(table.alignments, [.leading, .center, .trailing, .unspecified])
        XCTAssertEqual(table.rows, [])
    }

    func testOuterPipesAreOptional() throws {
        let table = try XCTUnwrap(parseMarkdownTable("a | b\n--- | ---\n1 | 2"))
        XCTAssertEqual(table.header, ["a", "b"])
        XCTAssertEqual(table.rows, [["1", "2"]])
    }

    func testAnEscapedPipeStaysInsideItsCell() throws {
        let table = try XCTUnwrap(parseMarkdownTable("| a | b |\n| - | - |\n| x \\| y | `p\\|q` |"))
        XCTAssertEqual(table.rows, [["x | y", "`p|q`"]])
    }

    func testAnEscapedBackslashBeforeTheOuterPipeIsNotAnExtraCell() throws {
        let table = try XCTUnwrap(parseMarkdownTable("| a | b \\\\|\n| - | - |"))
        XCTAssertEqual(table.header, ["a", "b \\\\"])
    }

    func testOtherBackslashEscapesAreLeftForTheInlineRenderer() throws {
        let table = try XCTUnwrap(parseMarkdownTable("| a |\n| - |\n| \\*not bold\\* |"))
        XCTAssertEqual(table.rows, [["\\*not bold\\*"]])
    }

    func testRaggedRowsArePaddedOrTruncatedToTheHeader() throws {
        let table = try XCTUnwrap(parseMarkdownTable("| a | b |\n| - | - |\n| 1 |\n| 1 | 2 | 3 |"))
        XCTAssertEqual(table.rows, [["1", ""], ["1", "2"]])
    }

    func testEmptyCellsAreKept() throws {
        let table = try XCTUnwrap(parseMarkdownTable("| a | b |\n| - | - |\n|  | 2 |\n1 |"))
        XCTAssertEqual(table.rows, [["", "2"], ["1", ""]])
    }

    // MARK: - Declining

    func testAHeaderAloneIsNotATable() {
        XCTAssertNil(parseMarkdownTable("| a | b |"))
    }

    func testAMismatchedDelimiterRowIsNotATable() {
        XCTAssertNil(parseMarkdownTable("| a | b |\n| - |"))
        XCTAssertNil(parseMarkdownTable("| a | b |\n| - | x |"))
    }

    func testLeadingProseIsNotATable() {
        XCTAssertNil(parseMarkdownTable("Intro text\n| a | b |\n| - | - |"))
    }

    func testATrailingLineWithoutAPipeIsNotATable() {
        XCTAssertNil(parseMarkdownTable("| a | b |\n| - | - |\n| 1 | 2 |\nafterwards"))
    }

    func testIndentedLinesAreNotATable() {
        XCTAssertNil(parseMarkdownTable("    | a | b |\n    | - | - |"))
    }

    func testProseAndHTMLAreNotTables() {
        XCTAssertNil(parseMarkdownTable("Line one\nLine two"))
        XCTAssertNil(parseMarkdownTable("<div>hi</div>"))
        XCTAssertNil(parseMarkdownTable(""))
    }

    /// A table still parses as one `.unknown` block, so the save path keeps
    /// writing its source back verbatim; only the reading surface draws it.
    func testATableStaysOneUnknownBlockForTheSavePath() throws {
        let markdown = "| a | b |\n| - | - |\n| 1 | 2 |"
        let blocks = parseEditorBlocks(markdown)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.kind, .unknown)
        XCTAssertNotNil(parseMarkdownTable(try XCTUnwrap(blocks.first).text))
    }

    // MARK: - Column widths

    func testNarrowContentGrowsInProportionToFillTheWidth() {
        XCTAssertEqual(MarkdownTableColumnWidths.fitting(ideals: [50, 150], available: 400), [100, 300])
    }

    func testWideContentKeepsNarrowColumnsAndSharesTheRest() {
        // An even share is 150; the first column fits it and keeps 100, the
        // other two split the remaining 200.
        XCTAssertEqual(MarkdownTableColumnWidths.fitting(ideals: [100, 600, 400], available: 450), [100, 175, 175])
    }

    func testEveryColumnTooWideSplitsEvenly() {
        XCTAssertEqual(MarkdownTableColumnWidths.fitting(ideals: [500, 800], available: 300), [150, 150])
    }

    func testEmptyColumnsShareTheWidthEvenly() {
        XCTAssertEqual(MarkdownTableColumnWidths.fitting(ideals: [0, 0], available: 200), [100, 100])
    }

    func testMinimumFittingWidthFloorsEachColumn() {
        let floor = MarkdownTableColumnWidths.minimumColumnWidth
        XCTAssertEqual(MarkdownTableColumnWidths.minimumFitting(ideals: [40, 500]), [40, floor])
    }

    func testScrollingColumnsAreCapped() {
        let cap = MarkdownTableColumnWidths.maximumScrollingColumnWidth
        XCTAssertEqual(MarkdownTableColumnWidths.scrolling(ideals: [80, 1000]), [80, cap])
    }
}
