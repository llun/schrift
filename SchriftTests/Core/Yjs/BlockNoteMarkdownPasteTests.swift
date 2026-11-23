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
        XCTAssertEqual(runs2.map(\.text), ["ok", " [badjs](javascript:alert(1)) [baddata](data:text/html,hi)"])
        if runs2.count == 2 {
            XCTAssertEqual(runs2[0].marks.map(\.key), ["link"])
            XCTAssertEqual(YBlockProjection.linkHref(from: runs2[0].marks[0].valueJSON), "https://example.com")
            XCTAssertTrue(runs2[1].marks.isEmpty)
        }
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

    func testArithmeticStarsStayLiteralAndPreserveBlankLines() throws {
        let md = "2*3*4\n\n2 * 3 * 4\n2**3**4\n2 ** 3 ** 4\na~~b~~c\na ~~ b ~~ c"
        let copies = try BlockNoteMarkdownPaste.parse(md)
        let (doc, blocks) = try project(copies)
        defer { doc.destroy() }

        XCTAssertEqual(
            blocks.map { $0.block.runs.map(\.text).joined() },
            ["2*3*4", "", "2 * 3 * 4", "2**3**4", "2 ** 3 ** 4", "a~~b~~c", "a ~~ b ~~ c"])
        XCTAssertTrue(blocks.allSatisfy { $0.block.runs.allSatisfy(\.marks.isEmpty) })

        // Real flanked emphasis still works, including punctuation-adjacent and combined bold+italic.
        let formatted = try BlockNoteMarkdownPaste.parse("(**bold**) *em*, ***both*** ~~gone~~")
        let (fDoc, fBlocks) = try project(formatted)
        defer { fDoc.destroy() }
        let runs = fBlocks[0].block.runs
        XCTAssertEqual(runs.first { $0.text == "bold" }?.marks.map(\.key), ["bold"])
        XCTAssertEqual(runs.first { $0.text == "em" }?.marks.map(\.key), ["italic"])
        XCTAssertEqual(Set(runs.first { $0.text == "both" }?.marks.map(\.key) ?? []), ["bold", "italic"])
        XCTAssertEqual(runs.first { $0.text == "gone" }?.marks.map(\.key), ["strike"])
    }

    func testEscapedImagesAndDoubleBacktickCodeSpansDoNotProduceImageBlocks() throws {
        let md = """
            \\![a](https://images.example/a.png)
            ``![b](https://images.example/b.png)``
            - \\![c](https://images.example/c.png)
            - ``![d](https://images.example/d.png)``
            """
        let copies = try BlockNoteMarkdownPaste.parse(md)
        let (doc, blocks) = try project(copies)
        defer { doc.destroy() }

        XCTAssertEqual(blocks.map(\.block.node), ["paragraph", "paragraph", "bulletListItem", "bulletListItem"])
        XCTAssertFalse(blocks.contains { $0.block.node == "image" })
        guard blocks.count == 4 else { return }
        XCTAssertEqual(blocks[1].block.runs.first?.text, "![b](https://images.example/b.png)")
        XCTAssertEqual(blocks[1].block.runs.first?.marks.map(\.key), ["code"])
        XCTAssertEqual(blocks[3].block.runs.first?.text, "![d](https://images.example/d.png)")
        XCTAssertEqual(blocks[3].block.runs.first?.marks.map(\.key), ["code"])
    }

    func testSizeBoundCheckedBeforeStrippingAndPathologicalScansAreLinear() throws {
        // #12: input over maxPasteUTF16 made entirely of U+FFFC must be rejected before stripping.
        let objectReplacements = String(repeating: "\u{FFFC}", count: NativeClipboard.maxPasteUTF16 + 1)
        do {
            _ = try BlockNoteMarkdownPaste.parse(objectReplacements)
            XCTFail("expected tooLarge before stripping U+FFFC")
        } catch let error as BlockNoteMarkdownPaste.Error {
            XCTAssertEqual(error, .tooLarge)
        }

        // #4: repeated failed image, backtick and link openers must stay linear.
        let pathological = [
            String(repeating: "![", count: 10_000),
            String(repeating: "![", count: 10_000) + "]",
            String(repeating: "`", count: 10_000),
            String(repeating: "[", count: 20_000),
        ]
        for input in pathological {
            let start = ThreadCPUClock.now
            let copies = try BlockNoteMarkdownPaste.parse(input)
            let elapsed = ThreadCPUClock.now - start
            XCTAssertEqual(copies.count, 1)
            XCTAssertLessThan(elapsed, .milliseconds(500), "pathological scan should stay linear, took \(elapsed)")
        }

        // #10: table followed by a bare `|` line and many trailing pipe rows must not backtrack quadratically.
        let pipeTable =
            (["| H |", "| - |"]
            + Array(repeating: "| a |", count: 900)
            + ["|"]
            + Array(repeating: "| a |", count: 900)).joined(separator: "\n")
        let startTable = ThreadCPUClock.now
        let tableCopies = try BlockNoteMarkdownPaste.parse(pipeTable)
        let elapsedTable = ThreadCPUClock.now - startTable
        XCTAssertEqual(tableCopies.count, 902)
        XCTAssertLessThan(
            elapsedTable, .milliseconds(500), "table scan hitting a bare pipe should be linear, took \(elapsedTable)")
    }

    func testLinksBeforeTrailingBracketsSurviveDelimiterLookahead() throws {
        // Bold emphasis whose lookahead scans past `[note]` before rewinding to scan the inner range.
        let boldCopies = try BlockNoteMarkdownPaste.parse("**[click](https://example.com) [note]**")
        let (boldDoc, boldBlocks) = try project(boldCopies)
        defer { boldDoc.destroy() }

        XCTAssertEqual(boldBlocks.count, 1)
        XCTAssertEqual(boldBlocks[0].block.node, "paragraph")
        let boldRuns = boldBlocks[0].block.runs
        XCTAssertEqual(boldRuns.map(\.text), ["click", " [note]"])
        if boldRuns.count == 2 {
            XCTAssertEqual(Set(boldRuns[0].marks.map(\.key)), ["bold", "link"])
            let boldHref = try XCTUnwrap(boldRuns[0].marks.first { $0.key == "link" }?.valueJSON)
            XCTAssertEqual(YBlockProjection.linkHref(from: boldHref), "https://example.com")
            XCTAssertEqual(boldRuns[1].marks.map(\.key), ["bold"])
        }

        // Unmatched `*` whose lookahead scans past `[1]` before falling back to plain scanning.
        let plainCopies = try BlockNoteMarkdownPaste.parse("*note: see [click](https://example.com) [1]")
        let (plainDoc, plainBlocks) = try project(plainCopies)
        defer { plainDoc.destroy() }

        XCTAssertEqual(plainBlocks.count, 1)
        XCTAssertEqual(plainBlocks[0].block.node, "paragraph")
        let plainRuns = plainBlocks[0].block.runs
        XCTAssertEqual(plainRuns.map(\.text), ["*note: see ", "click", " [1]"])
        if plainRuns.count == 3 {
            XCTAssertTrue(plainRuns[0].marks.isEmpty)
            XCTAssertEqual(plainRuns[1].marks.map(\.key), ["link"])
            XCTAssertEqual(YBlockProjection.linkHref(from: plainRuns[1].marks[0].valueJSON), "https://example.com")
            XCTAssertTrue(plainRuns[2].marks.isEmpty)
        }
    }

    func testPathologicalAngleImagesAndEmptyLinkLabelsStayBounded() throws {
        // Repeated unclosed `<` image destinations on a single 180 KB line and across 24 capped lines.
        let hugeAngleImages = String(repeating: "![a](<", count: 30_000) + ">"
        let startHugeAngle = ThreadCPUClock.now
        let hugeAngleCopies = try BlockNoteMarkdownPaste.parse(hugeAngleImages)
        let elapsedHugeAngle = ThreadCPUClock.now - startHugeAngle
        XCTAssertEqual(hugeAngleCopies.count, 1)
        XCTAssertLessThan(
            elapsedHugeAngle, .milliseconds(500),
            "180 KB angle-image line should stay bounded, took \(elapsedHugeAngle)")

        let cappedAngleLine = String(repeating: "![a](<", count: 1_365) + ">"
        let multiLineAngleImages = Array(repeating: cappedAngleLine, count: 24).joined(separator: "\n")
        let startMultiAngle = ThreadCPUClock.now
        let multiAngleCopies = try BlockNoteMarkdownPaste.parse(multiLineAngleImages)
        let elapsedMultiAngle = ThreadCPUClock.now - startMultiAngle
        XCTAssertEqual(multiAngleCopies.count, 24)
        XCTAssertLessThan(
            elapsedMultiAngle, .milliseconds(500),
            "24 capped angle-image lines should stay linear, took \(elapsedMultiAngle)")

        // Valid angle-bracketed image after a malformed `<` opener still parses.
        let validAfterMalformed = try BlockNoteMarkdownPaste.parse(
            "![bad](<x ![ok](<https://images.example/ok.png>)")
        let (imgDoc, imgBlocks) = try project(validAfterMalformed)
        defer { imgDoc.destroy() }
        XCTAssertEqual(imgBlocks.map(\.block.node), ["paragraph", "image"])
        XCTAssertEqual(
            imgBlocks[1].block.props.first { $0.key == "url" }?.value, .string("https://images.example/ok.png"))

        // 24 capped lines of empty-label `[](` openers before a trailing `)`, plus unclosed `[` and `[a](`.
        let emptyLinkLine = "*" + String(repeating: "[](", count: 1_365) + String(repeating: "x", count: 4_095) + ")"
        let emptyLinkInputs = [
            Array(repeating: emptyLinkLine, count: 24).joined(separator: "\n"),
            Array(repeating: "*" + String(repeating: "[", count: 8_191), count: 24).joined(separator: "\n"),
            Array(repeating: "*" + String(repeating: "[a](", count: 2_047), count: 24).joined(separator: "\n"),
        ]
        for input in emptyLinkInputs {
            let start = ThreadCPUClock.now
            let copies = try BlockNoteMarkdownPaste.parse(input)
            let elapsed = ThreadCPUClock.now - start
            XCTAssertEqual(copies.count, 24)
            XCTAssertLessThan(
                elapsed, .milliseconds(500), "pathological link scan should stay bounded, took \(elapsed)")
        }
    }

    func testInvalidWhitespaceAndRejectedLinksStayLiteral() throws {
        let broken = try BlockNoteMarkdownPaste.parse("[broken](unclosed and [two](https://two.example)")
        let (brokenDoc, brokenBlocks) = try project(broken)
        defer { brokenDoc.destroy() }
        XCTAssertEqual(brokenBlocks.map(\.block.node), ["paragraph"])
        let brokenRuns = brokenBlocks[0].block.runs
        XCTAssertEqual(brokenRuns.map(\.text), ["[broken](unclosed and ", "two"])
        if brokenRuns.count == 2 {
            XCTAssertTrue(brokenRuns[0].marks.isEmpty)
            XCTAssertEqual(brokenRuns[1].marks.map(\.key), ["link"])
            XCTAssertEqual(
                YBlockProjection.linkHref(from: brokenRuns[1].marks[0].valueJSON), "https://two.example")
        }

        let prose = try BlockNoteMarkdownPaste.parse("Items [foo](see note)")
        let (proseDoc, proseBlocks) = try project(prose)
        defer { proseDoc.destroy() }
        XCTAssertEqual(proseBlocks.map(\.block.node), ["paragraph"])
        XCTAssertEqual(proseBlocks[0].block.runs.map(\.text), ["Items [foo](see note)"])
        XCTAssertTrue(proseBlocks[0].block.runs.allSatisfy(\.marks.isEmpty))

        let badJS = try BlockNoteMarkdownPaste.parse("[badjs](javascript:alert(1))")
        let (badJSDoc, badJSBlocks) = try project(badJS)
        defer { badJSDoc.destroy() }
        XCTAssertEqual(badJSBlocks.map(\.block.node), ["paragraph"])
        XCTAssertEqual(badJSBlocks[0].block.runs.map(\.text), ["[badjs](javascript:alert(1))"])
        XCTAssertTrue(badJSBlocks[0].block.runs.allSatisfy(\.marks.isEmpty))
    }

    func testLongUnclosedDelimiterRunsStayLinear() throws {
        let tildeLine = "a " + String(repeating: "~", count: 8_190)
        let starLine = String(repeating: "*", count: 8_190) + " a"
        let tildeInput = Array(repeating: tildeLine, count: 24).joined(separator: "\n")
        let starInput = Array(repeating: starLine, count: 24).joined(separator: "\n")

        let start = ThreadCPUClock.now
        let tildeCopies = try BlockNoteMarkdownPaste.parse(tildeInput)
        let starCopies = try BlockNoteMarkdownPaste.parse(starInput)
        let elapsed = ThreadCPUClock.now - start

        XCTAssertLessThan(
            elapsed, .milliseconds(500), "unclosed ~/* runs should stay linear, took \(elapsed)")

        let (tildeDoc, tildeBlocks) = try project(tildeCopies)
        defer { tildeDoc.destroy() }
        XCTAssertEqual(tildeBlocks.count, 24)
        XCTAssertEqual(tildeBlocks.first?.block.runs.map(\.text), [tildeLine])
        XCTAssertTrue(tildeBlocks.allSatisfy { $0.block.runs == [InlineRun(tildeLine)] })

        let (starDoc, starBlocks) = try project(starCopies)
        defer { starDoc.destroy() }
        XCTAssertEqual(starBlocks.count, 24)
        XCTAssertEqual(starBlocks.first?.block.runs.map(\.text), [starLine])
        XCTAssertTrue(starBlocks.allSatisfy { $0.block.runs == [InlineRun(starLine)] })
    }

    func testBalancedParenthesisDestinationsStayLossless() throws {
        // `sanitizedLinkURL` rejects parentheses to preserve `InlineMarkdown` save round-trips,
        // so balanced-paren link destinations stay intact as literal source text rather than
        // truncating at the first `)`.
        let wikiURL = "https://en.wikipedia.org/wiki/Swift_(programming_language)"
        let fooURL = "https://example.com/(a)/b"
        XCTAssertNil(sanitizedLinkURL(wikiURL))
        XCTAssertNil(sanitizedLinkURL(fooURL))

        let wikiSource = "[Swift](\(wikiURL))"
        let wikiCopies = try BlockNoteMarkdownPaste.parse(wikiSource)
        let (wikiDoc, wikiBlocks) = try project(wikiCopies)
        defer { wikiDoc.destroy() }
        XCTAssertEqual(wikiBlocks.map(\.block.node), ["paragraph"])
        XCTAssertEqual(wikiBlocks[0].block.runs.map(\.text), [wikiSource])
        XCTAssertTrue(wikiBlocks[0].block.runs.allSatisfy(\.marks.isEmpty))

        let fooSource = "[foo](\(fooURL))"
        let fooCopies = try BlockNoteMarkdownPaste.parse(fooSource)
        let (fooDoc, fooBlocks) = try project(fooCopies)
        defer { fooDoc.destroy() }
        XCTAssertEqual(fooBlocks.map(\.block.node), ["paragraph"])
        XCTAssertEqual(fooBlocks[0].block.runs.map(\.text), [fooSource])
        XCTAssertTrue(fooBlocks[0].block.runs.allSatisfy(\.marks.isEmpty))

        let mixed = try BlockNoteMarkdownPaste.parse("\(wikiSource) and [ok](https://example.com)")
        let (mixedDoc, mixedBlocks) = try project(mixed)
        defer { mixedDoc.destroy() }
        XCTAssertEqual(mixedBlocks.map(\.block.node), ["paragraph"])
        let mixedRuns = mixedBlocks[0].block.runs
        XCTAssertEqual(mixedRuns.map(\.text), ["\(wikiSource) and ", "ok"])
        if mixedRuns.count == 2 {
            XCTAssertTrue(mixedRuns[0].marks.isEmpty)
            XCTAssertEqual(mixedRuns[1].marks.map(\.key), ["link"])
            XCTAssertEqual(YBlockProjection.linkHref(from: mixedRuns[1].marks[0].valueJSON), "https://example.com")
        }

        // The shared destination parser accepts balanced parentheses when the URL validator does.
        let imageCopies = try BlockNoteMarkdownPaste.parse("![Swift](https://images.example/Swift_(logo).png)")
        let (imageDoc, imageBlocks) = try project(imageCopies)
        defer { imageDoc.destroy() }
        XCTAssertEqual(imageBlocks.map(\.block.node), ["image"])
        XCTAssertEqual(
            imageBlocks[0].block.props.first { $0.key == "url" }?.value,
            .string("https://images.example/Swift_(logo).png"))
        XCTAssertEqual(imageBlocks[0].block.props.first { $0.key == "name" }?.value, .string("Swift"))
    }

    func testAngleBracketedTitledAndPaddedLinkDestinations() throws {
        let inputs = [
            "[Example](<https://example.com>)",
            "[Example](https://example.com \"Title\")",
            "[Example]( https://example.com )",
            "[Example](https://example.com 'Title (1)')",
        ]
        for input in inputs {
            let copies = try BlockNoteMarkdownPaste.parse(input)
            let (doc, blocks) = try project(copies)
            defer { doc.destroy() }
            XCTAssertEqual(blocks.map(\.block.node), ["paragraph"], input)
            let runs = blocks[0].block.runs
            XCTAssertEqual(runs.map(\.text), ["Example"], input)
            if runs.count == 1 {
                XCTAssertEqual(runs[0].marks.map(\.key), ["link"], input)
                XCTAssertEqual(
                    YBlockProjection.linkHref(from: runs[0].marks[0].valueJSON), "https://example.com", input)
            }
        }
    }

    func testBalancedNestedBracketsInLinkLabelsAndImageAltText() throws {
        let nestedLink = try BlockNoteMarkdownPaste.parse("[foo [bar] baz](https://example.com)")
        let (linkDoc, linkBlocks) = try project(nestedLink)
        defer { linkDoc.destroy() }
        XCTAssertEqual(linkBlocks.map(\.block.node), ["paragraph"])
        let linkRuns = linkBlocks[0].block.runs
        XCTAssertEqual(linkRuns.map(\.text), ["foo [bar] baz"])
        if linkRuns.count == 1 {
            XCTAssertEqual(linkRuns[0].marks.map(\.key), ["link"])
            XCTAssertEqual(YBlockProjection.linkHref(from: linkRuns[0].marks[0].valueJSON), "https://example.com")
        }

        let nestedImage = try BlockNoteMarkdownPaste.parse("![alt [1]](https://images.example/a.png)")
        let (imgDoc, imgBlocks) = try project(nestedImage)
        defer { imgDoc.destroy() }
        XCTAssertEqual(imgBlocks.map(\.block.node), ["image"])
        XCTAssertEqual(
            imgBlocks[0].block.props.first { $0.key == "url" }?.value, .string("https://images.example/a.png"))
        XCTAssertEqual(imgBlocks[0].block.props.first { $0.key == "name" }?.value, .string("alt [1]"))

        let prefixedImage = try BlockNoteMarkdownPaste.parse("![prefix ![ok](https://images.example/ok.png)")
        let (prefDoc, prefBlocks) = try project(prefixedImage)
        defer { prefDoc.destroy() }
        XCTAssertEqual(prefBlocks.map(\.block.node), ["paragraph", "image"])
        if prefBlocks.count == 2 {
            XCTAssertEqual(prefBlocks[0].block.runs.map(\.text), ["![prefix "])
            XCTAssertTrue(prefBlocks[0].block.runs.allSatisfy(\.marks.isEmpty))
            XCTAssertEqual(
                prefBlocks[1].block.props.first { $0.key == "url" }?.value,
                .string("https://images.example/ok.png"))
            XCTAssertEqual(prefBlocks[1].block.props.first { $0.key == "name" }?.value, .string("ok"))
        }
    }

    func testFourSpaceIndentedOperatorsStayPlainTextAndPreserveBlankLines() throws {
        let plain = "result = a\n    + b\n    - c\n\ndone"
        let plainCopies = try BlockNoteMarkdownPaste.parse(plain)
        let (plainDoc, plainBlocks) = try project(plainCopies)
        defer { plainDoc.destroy() }

        XCTAssertEqual(
            plainBlocks.map(\.block.node), ["paragraph", "paragraph", "paragraph", "paragraph", "paragraph"])
        XCTAssertEqual(
            plainBlocks.map { $0.block.runs.map(\.text).joined() },
            ["result = a", "    + b", "    - c", "", "done"])
        XCTAssertTrue(plainBlocks.allSatisfy { $0.block.runs.allSatisfy(\.marks.isEmpty) })

        // Even when Markdown is present elsewhere, 4-space/tab indented lines outside an open list stay paragraphs.
        let mixed = "# Heading\n    + b\n    - c\n    1. d\n\t- e"
        let mixedCopies = try BlockNoteMarkdownPaste.parse(mixed)
        let (mixedDoc, mixedBlocks) = try project(mixedCopies)
        defer { mixedDoc.destroy() }

        XCTAssertEqual(mixedBlocks.map(\.block.node), ["heading", "paragraph", "paragraph", "paragraph", "paragraph"])
        XCTAssertEqual(
            mixedBlocks.map { $0.block.runs.map(\.text).joined() },
            ["Heading", "    + b", "    - c", "    1. d", "\t- e"])
    }

    func testTableEndsBeforeFollowingBlockConstructsContainingPipes() throws {
        let tablePrefix = "| H1 | H2 |\n| --- | --- |\n| a | b |\n"

        // Heading with `|` after table keeps the heading and all segments (`C` is not dropped).
        let headingCopies = try BlockNoteMarkdownPaste.parse(tablePrefix + "# Section A | B | C")
        let (headingDoc, headingBlocks) = try project(headingCopies)
        defer { headingDoc.destroy() }
        XCTAssertEqual(headingBlocks.map(\.block.node), ["table", "heading"])
        if headingBlocks.count == 2 {
            let table = try XCTUnwrap(TableGrid.tables(in: headingDoc).values.first)
            XCTAssertEqual(table.rows.map { $0.map { $0.runs.map(\.text).joined() } }, [["H1", "H2"], ["a", "b"]])
            XCTAssertEqual(headingBlocks[1].block.props.first { $0.key == "level" }?.value, .int(1))
            XCTAssertEqual(headingBlocks[1].block.runs.map(\.text).joined(), "Section A | B | C")
        }

        // Bullet list, numbered list, quote, fence and divider with `|` each terminate the table.
        let followUps: [(suffix: String, expectedNode: String, expectedText: String)] = [
            ("- Item A | B | C", "bulletListItem", "Item A | B | C"),
            ("1. Item A | B | C", "numberedListItem", "Item A | B | C"),
            ("> Quote A | B | C", "quote", "Quote A | B | C"),
            ("```a|b\ncode\n```", "codeBlock", "code"),
            ("---", "divider", ""),
        ]
        for entry in followUps {
            let copies = try BlockNoteMarkdownPaste.parse(tablePrefix + entry.suffix)
            let (doc, blocks) = try project(copies)
            defer { doc.destroy() }
            XCTAssertEqual(blocks.map(\.block.node), ["table", entry.expectedNode], entry.suffix)
            if blocks.count == 2 {
                let table = try XCTUnwrap(TableGrid.tables(in: doc).values.first)
                XCTAssertEqual(
                    table.rows.map { $0.map { $0.runs.map(\.text).joined() } }, [["H1", "H2"], ["a", "b"]], entry.suffix
                )
                XCTAssertEqual(blocks[1].block.runs.map(\.text).joined(), entry.expectedText, entry.suffix)
            }
        }
    }

    func testOversizedMarkdownLinkURLAndMarkAmplificationStayBounded() throws {
        let prefix = "https://example.com/"
        let exactHref = prefix + String(repeating: "a", count: MediaBlock.maxURL - prefix.count)
        let overHref = exactHref + "b"

        let overSource = "[Over](\(overHref))"
        let overCopies = try BlockNoteMarkdownPaste.parse(overSource)
        let (overDoc, overBlocks) = try project(overCopies)
        defer { overDoc.destroy() }
        XCTAssertEqual(overBlocks.map(\.block.node), ["paragraph"])
        XCTAssertEqual(overBlocks[0].block.runs.map(\.text), [overSource])
        XCTAssertTrue(overBlocks[0].block.runs.allSatisfy(\.marks.isEmpty))

        // 24 lines repeating a maxURL link mark across 1,500 alternating bold/plain runs (~72 MB)
        // must fail fast with .tooLarge.
        let amplifiedLine = "[" + String(repeating: "**a** a ", count: 750) + "](\(exactHref))"
        let amplified = Array(repeating: amplifiedLine, count: 24).joined(separator: "\n")
        let start = ThreadCPUClock.now
        do {
            _ = try BlockNoteMarkdownPaste.parse(amplified)
            XCTFail("expected tooLarge when Markdown link marks exceed payload byte bound")
        } catch let error as BlockNoteMarkdownPaste.Error {
            XCTAssertEqual(error, .tooLarge)
        }
        let elapsed = ThreadCPUClock.now - start
        XCTAssertLessThan(
            elapsed, .milliseconds(500),
            "Markdown mark-byte amplification must fail fast during parse, took \(elapsed)")
    }

    func testUTF8ScanPreservesUnicodeSemanticsAndBoundsClosedAngleAndNestedDelimiters() throws {
        // Non-ASCII letters, Unicode punctuation flanking (`—`), non-ASCII image alt text,
        // and non-ASCII whitespace (U+00A0) terminating a bare destination stay exact under
        // the UTF-8 byte scanner.
        let unicode = """
            **café** *naïve*—_über_ ~~résumé~~ [日本語](https://example.com)
            ![héllo \\] world](https://images.example/a.png)
            [nbsp](https://example.com\u{00A0}tail)
            """
        let unicodeCopies = try BlockNoteMarkdownPaste.parse(unicode)
        let (doc, blocks) = try project(unicodeCopies)
        defer { doc.destroy() }

        XCTAssertEqual(blocks.map(\.block.node), ["paragraph", "image", "paragraph"])
        if blocks.count == 3 {
            let runs = blocks[0].block.runs
            XCTAssertEqual(runs.first { $0.text == "café" }?.marks.map(\.key), ["bold"])
            XCTAssertEqual(runs.first { $0.text == "naïve" }?.marks.map(\.key), ["italic"])
            XCTAssertEqual(runs.first { $0.text == "über" }?.marks.map(\.key), ["italic"])
            XCTAssertEqual(runs.first { $0.text == "résumé" }?.marks.map(\.key), ["strike"])
            XCTAssertEqual(runs.first { $0.text == "日本語" }?.marks.map(\.key), ["link"])

            XCTAssertEqual(
                blocks[1].block.props.first { $0.key == "url" }?.value, .string("https://images.example/a.png"))
            XCTAssertEqual(blocks[1].block.props.first { $0.key == "name" }?.value, .string("héllo ] world"))

            XCTAssertEqual(blocks[2].block.runs.map(\.text), ["[nbsp](https://example.com\u{00A0}tail)"])
            XCTAssertTrue(blocks[2].block.runs.allSatisfy(\.marks.isEmpty))
        }

        // 24 capped angle-image lines with a trailing `)` (forcing the image & link scanners to run)
        // and 24 capped lines of unclosed `*` inside `**...**` both stay strictly linear.
        let closedAngleLine = String(repeating: "![a](<", count: 1_365) + ">)"
        let closedAngleInput = Array(repeating: closedAngleLine, count: 24).joined(separator: "\n")
        let startClosedAngle = ThreadCPUClock.now
        let closedAngleCopies = try BlockNoteMarkdownPaste.parse(closedAngleInput)
        let elapsedClosedAngle = ThreadCPUClock.now - startClosedAngle
        XCTAssertEqual(closedAngleCopies.count, 24)
        XCTAssertLessThan(
            elapsedClosedAngle, .milliseconds(500),
            "24 capped angle-image lines with trailing ')' should stay linear, took \(elapsedClosedAngle)")

        let nestedStarLine = "**" + String(repeating: "*a ", count: 1_360) + "**"
        let nestedStarInput = Array(repeating: nestedStarLine, count: 24).joined(separator: "\n")
        let startNestedStar = ThreadCPUClock.now
        let nestedStarCopies = try BlockNoteMarkdownPaste.parse(nestedStarInput)
        let elapsedNestedStar = ThreadCPUClock.now - startNestedStar
        XCTAssertEqual(nestedStarCopies.count, 24)
        XCTAssertLessThan(
            elapsedNestedStar, .milliseconds(500),
            "24 capped lines of unclosed '*' inside '**' should stay linear, took \(elapsedNestedStar)")
    }
}
