import XCTest

@testable import Schrift

final class BlockNoteMarkdownPasteTests: XCTestCase {
    private func project(_ copies: [BlockNoteWriter.Copy]) throws -> (doc: YDoc, blocks: [NativeBlockSnapshot]) {
        let payload = try BlockNoteSubtreePayload.encode(copies)
        let decoded = try BlockNoteSubtreePayload.validatingPastable(BlockNoteSubtreePayload.decode(payload))
        _ = try BlockNoteSubtreePayload.validate(decoded)
        let doc = YDoc(clientID: 1, gc: false)
        try doc.applyUpdate(YUpdateDecoder.decode(payload))
        return (doc, NativeBlockProjection.project(doc).blocks)
    }

    func testParsesHeadingsClampingH4ToH6QuotesDividersAndCodeFences() throws {
        let md = """
            # One
            ## Two
            ### Three
            #### Four
            ##### Five
            ###### Six ##

            > Quoted **text**

            ---
            ***
            ___

            ```swift
            let x = 1

            # not a heading
            ```
            """
        let copies = try BlockNoteMarkdownPaste.parse(md)
        let (doc, blocks) = try project(copies)
        defer { doc.destroy() }

        XCTAssertEqual(
            blocks.map(\.block.node),
            [
                "heading", "heading", "heading", "heading", "heading", "heading", "quote", "divider", "divider",
                "divider",
                "codeBlock",
            ])
        let levels = blocks.prefix(6).compactMap { block -> Int? in
            if case .int(let level)? = block.block.props.first(where: { $0.key == "level" })?.value { return level }
            return nil
        }
        XCTAssertEqual(levels, [1, 2, 3, 3, 3, 3])
        XCTAssertEqual(blocks[5].block.runs.map(\.text).joined(), "Six")
        XCTAssertEqual(blocks[6].block.runs.map(\.text).joined(), "Quoted text")
        XCTAssertEqual(blocks[6].block.runs.last?.marks.map(\.key), ["bold"])
        XCTAssertEqual(blocks[10].block.props.first { $0.key == "language" }?.value, .string("swift"))
        XCTAssertEqual(blocks[10].block.runs.map(\.text).joined(), "let x = 1\n\n# not a heading")
        XCTAssertNotNil(NativeBlockProjection.markdownShadow(doc))
    }

    func testParsesNestedBulletsNumberedAndChecklists() throws {
        let md = """
            - Root bullet
              * Child star
                + Grandchild plus
            - [ ] Unchecked
            - [x] Checked
            [X] Bare checked

            5. Start five
            6) Next six
                1. Nested one
            """
        let copies = try BlockNoteMarkdownPaste.parse(md)
        let (doc, blocks) = try project(copies)
        defer { doc.destroy() }

        XCTAssertEqual(
            blocks.map(\.block.node),
            [
                "bulletListItem", "bulletListItem", "bulletListItem",
                "checkListItem", "checkListItem", "checkListItem",
                "numberedListItem", "numberedListItem", "numberedListItem",
            ])
        XCTAssertEqual(blocks.map(\.depth), [0, 1, 2, 0, 0, 0, 0, 0, 1])
        XCTAssertEqual(
            blocks.map { $0.block.runs.map(\.text).joined() },
            [
                "Root bullet", "Child star", "Grandchild plus",
                "Unchecked", "Checked", "Bare checked",
                "Start five", "Next six", "Nested one",
            ])

        XCTAssertEqual(blocks[3].block.props.first { $0.key == "checked" }?.value, .bool(false))
        XCTAssertEqual(blocks[4].block.props.first { $0.key == "checked" }?.value, .bool(true))
        XCTAssertEqual(blocks[5].block.props.first { $0.key == "checked" }?.value, .bool(true))
        XCTAssertEqual(blocks[6].block.props.first { $0.key == "start" }?.value, .int(5))
        XCTAssertEqual(blocks[7].block.props.first { $0.key == "start" }?.value, .undefined)
        XCTAssertNotNil(NativeBlockProjection.markdownShadow(doc))
    }

    func testParsesGFMTablesWithAlignmentsInlineMarksAndLineBreaks() throws {
        let md = """
            | Name | Score | Notes |
            | :--- | :---: | ---: |
            | **Ada** | 100 | Line 1<br>Line 2 |
            | Grace | 99 | [Link](https://example.com) |
            """
        let copies = try BlockNoteMarkdownPaste.parse(md)
        let (doc, blocks) = try project(copies)
        defer { doc.destroy() }

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].block.node, "table")
        XCTAssertEqual(blocks[0].block.fidelity, .modeled)
        let tables = TableGrid.tables(in: doc)
        let grid = try XCTUnwrap(tables.values.first)
        XCTAssertTrue(grid.isFamiliar)
        XCTAssertEqual(grid.rows.count, 3)
        XCTAssertEqual(grid.columnCount, 3)
        XCTAssertTrue(grid.rows[0].allSatisfy(\.isHeader))
        XCTAssertEqual(grid.rows[1][0].runs.first?.marks.map(\.key), ["bold"])
        XCTAssertEqual(grid.rows[1][1].string("textAlignment"), "center")
        XCTAssertEqual(grid.rows[1][2].string("textAlignment"), "right")
        XCTAssertEqual(grid.rows[1][2].runs.map(\.text).joined(), "Line 1\nLine 2")
        XCTAssertEqual(grid.rows[2][2].runs.first?.marks.map(\.key), ["link"])
        XCTAssertNotNil(NativeBlockProjection.markdownShadow(doc))
    }

    func testParsesHTTPSImagesInlineMarksAndSanitizesLinks() throws {
        let md = """
            ![Cat](https://images.example/cat.png)
            ![NoHTTP](http://insecure.example/a.png)
            ![NoData](data:image/png;base64,AAAA)
            ![NoFile](file:///tmp/a.png)
            ![NoJS](javascript:alert(1))
            **bold** *em* _under_ `code` ~~strike~~ snake_case
            [ok](https://example.com) [badjs](javascript:alert(1)) [baddata](data:text/html,hi)
            """
        let copies = try BlockNoteMarkdownPaste.parse(md)
        let (doc, blocks) = try project(copies)
        defer { doc.destroy() }

        XCTAssertEqual(blocks.map(\.block.node), ["image", "paragraph", "paragraph"])
        XCTAssertEqual(
            blocks[0].block.props.first { $0.key == "url" }?.value, .string("https://images.example/cat.png"))
        XCTAssertEqual(blocks[0].block.props.first { $0.key == "name" }?.value, .string("Cat"))

        let runs1 = blocks[1].block.runs
        XCTAssertEqual(runs1.first { $0.text == "bold" }?.marks.map(\.key), ["bold"])
        XCTAssertEqual(runs1.first { $0.text == "em" }?.marks.map(\.key), ["italic"])
        XCTAssertEqual(runs1.first { $0.text == "under" }?.marks.map(\.key), ["italic"])
        XCTAssertEqual(runs1.first { $0.text == "code" }?.marks.map(\.key), ["code"])
        XCTAssertEqual(runs1.first { $0.text == "strike" }?.marks.map(\.key), ["strike"])
        XCTAssertTrue(runs1.contains { $0.text.contains("snake_case") && $0.marks.isEmpty })

        let runs2 = blocks[2].block.runs
        let okLink = try XCTUnwrap(runs2.first { $0.text == "ok" })
        XCTAssertEqual(okLink.marks.map(\.key), ["link"])
        XCTAssertEqual(YBlockProjection.linkHref(from: okLink.marks[0].valueJSON), "https://example.com")
        XCTAssertTrue(runs2.contains { $0.text.contains("badjs") && $0.marks.isEmpty })
        XCTAssertTrue(runs2.contains { $0.text.contains("baddata") && $0.marks.isEmpty })
    }

    func testPlainTextWithoutMarkdownMatchesMultiLinePaste() throws {
        let plain = "First line\r\nSecond line\n\n  indented snake_case #hashtag\u{FFFC}"
        let copies = try BlockNoteMarkdownPaste.parse(plain)
        let (doc, blocks) = try project(copies)
        defer { doc.destroy() }

        XCTAssertEqual(blocks.map(\.block.node), ["paragraph", "paragraph", "paragraph", "paragraph"])
        XCTAssertEqual(
            blocks.map { $0.block.runs.map(\.text).joined() },
            ["First line", "Second line", "", "  indented snake_case #hashtag"])
        XCTAssertTrue(blocks.allSatisfy { $0.block.runs.allSatisfy(\.marks.isEmpty) })
    }

    func testSingleNewlineOutsideFencesStartsNewParagraph() throws {
        let md = "# Title\nFirst line\nSecond line"
        let copies = try BlockNoteMarkdownPaste.parse(md)
        let (doc, blocks) = try project(copies)
        defer { doc.destroy() }

        XCTAssertEqual(blocks.map(\.block.node), ["heading", "paragraph", "paragraph"])
        XCTAssertEqual(blocks.map { $0.block.runs.map(\.text).joined() }, ["Title", "First line", "Second line"])
    }

    func testHostileAndOversizedInputsRespectBounds() throws {
        let hugeText = String(repeating: "a", count: NativeClipboard.maxPasteUTF16 + 1)
        do {
            _ = try BlockNoteMarkdownPaste.parse(hugeText)
            XCTFail("expected tooLarge for >200k UTF-16")
        } catch let error as BlockNoteMarkdownPaste.Error {
            XCTAssertEqual(error, .tooLarge)
        }

        let tooManyLines = Array(repeating: "x", count: NativeClipboard.maxPasteLines + 1).joined(separator: "\n")
        do {
            _ = try BlockNoteMarkdownPaste.parse(tooManyLines)
            XCTFail("expected tooLarge for >2000 lines")
        } catch let error as BlockNoteMarkdownPaste.Error {
            XCTAssertEqual(error, .tooLarge)
        }

        // Table exceeding TableGrid.maxCells (1,000) is rejected.
        let header = "| " + (0..<20).map { "H\($0)" }.joined(separator: " | ") + " |"
        let sep = "| " + (0..<20).map { _ in "---" }.joined(separator: " | ") + " |"
        let row = "| " + (0..<20).map { _ in "v" }.joined(separator: " | ") + " |"
        let hugeTable = ([header, sep] + Array(repeating: row, count: 55)).joined(separator: "\n")
        do {
            _ = try BlockNoteMarkdownPaste.parse(hugeTable)
            XCTFail("expected tooLarge for >1000-cell table")
        } catch let error as BlockNoteMarkdownPaste.Error {
            XCTAssertEqual(error, .tooLarge)
        }

        // Deeply nested list (> maxNestingDepth) clamps and still validates cleanly.
        let deep = (0..<25).map { String(repeating: "  ", count: $0) + "- L\($0)" }.joined(separator: "\n")
        let clamped = try BlockNoteMarkdownPaste.parse(deep)
        let shape = try BlockNoteSubtreePayload.validate(clamped)
        XCTAssertLessThanOrEqual(shape.depth, BlockNoteWriter.maxNestingDepth)

        // Dropped-only image input returns empty cleanly.
        XCTAssertTrue(try BlockNoteMarkdownPaste.parse("![bad](http://insecure.example/x.png)").isEmpty)
    }
}
