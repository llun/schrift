import XCTest

@testable import Schrift

final class BlockNoteHTMLParserTests: XCTestCase {
    private func project(_ copies: [BlockNoteWriter.Copy]) throws -> (doc: YDoc, blocks: [NativeBlockSnapshot]) {
        let payload = try BlockNoteSubtreePayload.encode(copies)
        let decoded = try BlockNoteSubtreePayload.validatingPastable(BlockNoteSubtreePayload.decode(payload))
        _ = try BlockNoteSubtreePayload.validate(decoded)
        let doc = YDoc(clientID: 1, gc: false)
        try doc.applyUpdate(YUpdateDecoder.decode(payload))
        return (doc, NativeBlockProjection.project(doc).blocks)
    }

    func testParsesParagraphsHeadingsClampingH4ToH6AndHardBreaks() throws {
        let html = """
            <h1>One</h1>
            <h2>Two</h2>
            <h3>Three</h3>
            <h4>Four</h4>
            <h5>Five</h5>
            <h6>Six</h6>
            <p>Line 1<br>Line 2</p>
            <p><br></p>
            <div>Div A</div><div>Div B</div>
            """
        let copies = try BlockNoteHTMLParser.parse(html)
        XCTAssertEqual(copies.count, 11)
        guard copies.count == 11 else { return }

        let levels = copies.prefix(6).compactMap { copy -> Int? in
            guard case .element("blockContainer", _, let kids) = copy,
                case .element("heading", let props, _)? = kids.first,
                case .int(let level)? = props.first(where: { $0.key == "level" })?.value
            else { return nil }
            return level
        }
        XCTAssertEqual(levels, [1, 2, 3, 3, 3, 3])

        // <p>Line 1<br>Line 2</p> splits into two modeled paragraphs (never hardBreak in prose).
        let (brDoc, brBlocks) = try project(Array(copies[6...7]))
        defer { brDoc.destroy() }
        XCTAssertEqual(brBlocks.map(\.block.node), ["paragraph", "paragraph"])
        XCTAssertEqual(brBlocks.map(\.block.fidelity), [.modeled, .modeled])
        XCTAssertEqual(brBlocks.map { $0.block.runs.map(\.text).joined() }, ["Line 1", "Line 2"])
        XCTAssertNotNil(NativeBlockProjection.markdownShadow(brDoc))

        // <p><br></p> produces an empty paragraph, not a stray hardBreak.
        guard case .element("blockContainer", _, let emptyKids) = copies[8],
            case .element("paragraph", _, let emptyInline)? = emptyKids.first
        else { return XCTFail("expected empty paragraph at index 8") }
        XCTAssertTrue(emptyInline.isEmpty)

        // <div>Div A</div><div>Div B</div> produces two separate paragraphs.
        let (doc, blocks) = try project(Array(copies[9...10]))
        defer { doc.destroy() }
        XCTAssertEqual(blocks.map { $0.block.runs.map(\.text).joined() }, ["Div A", "Div B"])
    }

    func testParsesInlineMarksPaletteColorsAndSanitizedLinks() throws {
        let html = """
            <p><strong>Bold</strong> <b>B</b> <em>Em</em> <i>I</i> <u>U</u> <s>S</s> <del>D</del> <code>C</code></p>
            <p><span style="font-weight:700;font-style:italic;text-decoration:underline line-through;\
            color:#ff00ff;font-family:Comic Sans">Styled</span>
            <span data-style-type="textColor" data-value="red">Red</span>
            <span data-style-type="backgroundColor" data-value="hotpink">BadColor</span></p>
            <p><a href="https://example.com/ok">Good</a>
            <a href="javascript:alert(1)">BadJS</a>
            <a href="data:text/html,<script>x</script>">BadData</a>
            <a href="/relative/path">BadRel</a></p>
            """
        let copies = try BlockNoteHTMLParser.parse(html)
        let (doc, blocks) = try project(copies)
        defer { doc.destroy() }
        XCTAssertEqual(blocks.count, 3)

        let marks0 = blocks[0].block.runs.filter { !$0.marks.isEmpty }.map { ($0.text, Set($0.marks.map(\.key))) }
        XCTAssertEqual(marks0.map(\.0), ["Bold", "B", "Em", "I", "U", "S", "D", "C"])
        XCTAssertEqual(
            marks0.map(\.1),
            [["bold"], ["bold"], ["italic"], ["italic"], ["underline"], ["strike"], ["strike"], ["code"]])

        let runs1 = blocks[1].block.runs
        let styled = try XCTUnwrap(runs1.first { $0.text == "Styled" })
        XCTAssertEqual(Set(styled.marks.map(\.key)), ["bold", "italic", "underline", "strike"])
        let red = try XCTUnwrap(runs1.first { $0.text == "Red" })
        XCTAssertEqual(red.marks.map(\.key), ["textColor"])
        XCTAssertEqual(NativeMark.colorName(from: red.marks[0].valueJSON), "red")
        let badColor = try XCTUnwrap(runs1.first { $0.text.contains("BadColor") })
        XCTAssertTrue(badColor.marks.isEmpty, "arbitrary non-palette colors must be dropped")

        let runs2 = blocks[2].block.runs
        let goodLink = try XCTUnwrap(runs2.first { $0.text == "Good" })
        XCTAssertEqual(goodLink.marks.map(\.key), ["link"])
        XCTAssertEqual(YBlockProjection.linkHref(from: goodLink.marks[0].valueJSON), "https://example.com/ok")
        for unsafe in ["BadJS", "BadData", "BadRel"] {
            let matching = runs2.filter { $0.text.contains(unsafe) }
            XCTAssertFalse(matching.isEmpty, "text for \(unsafe) should be kept")
            XCTAssertTrue(
                matching.allSatisfy { $0.marks.isEmpty }, "\(unsafe) link mark must be stripped")
        }
    }

    func testParsesNestedListsNumberedStartAndChecklists() throws {
        let html = """
            <ul>
              <li>Parent<ul><li>Child<ul><li>Grandchild</li></ul></li></ul></li>
              <li><input type="checkbox"> Todo</li>
              <li><input type="checkbox" checked> Done</li>
            </ul>
            <ol start="5">
              <li>Five</li>
              <li>Six</li>
            </ol>
            <div data-content-type="checkListItem" data-checked="true"><p>BlockNote Done</p></div>
            <div data-content-type="checkListItem" data-checked="false"><p>BlockNote Open</p></div>
            """
        let copies = try BlockNoteHTMLParser.parse(html)
        let (doc, blocks) = try project(copies)
        defer { doc.destroy() }

        XCTAssertEqual(
            blocks.map(\.block.node),
            [
                "bulletListItem", "bulletListItem", "bulletListItem",
                "checkListItem", "checkListItem",
                "numberedListItem", "numberedListItem",
                "checkListItem", "checkListItem",
            ])
        XCTAssertEqual(blocks.map(\.depth), [0, 1, 2, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(
            blocks.map { $0.block.runs.map(\.text).joined() },
            ["Parent", "Child", "Grandchild", "Todo", "Done", "Five", "Six", "BlockNote Done", "BlockNote Open"])

        XCTAssertEqual(blocks[3].block.props.first { $0.key == "checked" }?.value, .bool(false))
        XCTAssertEqual(blocks[4].block.props.first { $0.key == "checked" }?.value, .bool(true))
        XCTAssertEqual(blocks[5].block.props.first { $0.key == "start" }?.value, .int(5))
        XCTAssertEqual(blocks[6].block.props.first { $0.key == "start" }?.value, .undefined)
        XCTAssertEqual(blocks[7].block.props.first { $0.key == "checked" }?.value, .bool(true))
        XCTAssertEqual(blocks[8].block.props.first { $0.key == "checked" }?.value, .bool(false))
        XCTAssertNotNil(NativeBlockProjection.markdownShadow(doc))
    }

    func testParsesBlockquoteCodeBlockWithLanguageDividerTableAndHTTPSImages() throws {
        let html = """
            <blockquote><p>Quoted <em>wisdom</em></p></blockquote>
            <pre><code class="language-swift">let a = 1\n  let b = 2\n</code></pre>
            <hr>
            <table>
              <thead><tr><th>Name</th><th>Role</th></tr></thead>
              <tbody>
                <tr><td><strong>Ada</strong></td><td><table><tr><td>Nested</td></tr></table></td></tr>
                <tr><td>Grace</td></tr>
              </tbody>
            </table>
            <p>Before <img src="https://images.example/été.png" alt="Cat"> after</p>
            <img src="http://insecure.example/a.png" alt="NoHTTP">
            <img src="data:image/png;base64,AAAA" alt="NoData">
            <img src="file:///etc/passwd" alt="NoFile">
            <img src="javascript:alert(1)" alt="NoJS">
            """
        let copies = try BlockNoteHTMLParser.parse(html)
        let (doc, blocks) = try project(copies)
        defer { doc.destroy() }

        XCTAssertEqual(
            blocks.map(\.block.node),
            ["quote", "codeBlock", "divider", "table", "paragraph", "image", "paragraph"])
        XCTAssertEqual(blocks[0].block.runs.map(\.text).joined(), "Quoted wisdom")
        XCTAssertEqual(blocks[1].block.props.first { $0.key == "language" }?.value, .string("swift"))
        XCTAssertEqual(blocks[1].block.runs.map(\.text).joined(), "let a = 1\n  let b = 2")
        XCTAssertEqual(blocks[3].block.fidelity, .modeled, "normalized table must be familiar")
        XCTAssertEqual(TableGrid.tables(in: doc).values.first?.rows[1][1].runs.map(\.text).joined(), "Nested")
        XCTAssertEqual(blocks[4].block.runs.map(\.text).joined(), "Before")
        XCTAssertEqual(
            blocks[5].block.props.first { $0.key == "url" }?.value,
            .string("https://images.example/%C3%A9t%C3%A9.png"))
        XCTAssertEqual(blocks[5].block.props.first { $0.key == "name" }?.value, .string("Cat"))
        XCTAssertEqual(blocks[6].block.runs.map(\.text).joined(), "after")
        XCTAssertNotNil(NativeBlockProjection.markdownShadow(doc))
    }

    func testDropsUnsupportedHTMLAndUnwrapsLayoutContainers() throws {
        let html = """
            <html><head><title>Ignored</title><style>p { color: red; }</style></head>
            <body>
              <script>alert('xss')</script>
              <iframe src="https://evil.example">Fallback</iframe>
              <form>
                <label>User</label><input type="text" value="x">
                <button>Go</button><select><option>A</option></select>
              </form>
              <section><article><main><p>Kept</p></main></article></section>
            </body></html>
            """
        let copies = try BlockNoteHTMLParser.parse(html)
        let (doc, blocks) = try project(copies)
        defer { doc.destroy() }
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].block.node, "paragraph")
        XCTAssertEqual(blocks[0].block.runs.map(\.text).joined(), "Kept")
    }

    func testHostileAndOversizedInputsRespectBounds() throws {
        // Oversized byte length (> 2 MiB)
        let hugeBytes = "<p>" + String(repeating: "a", count: TableClipboard.maxHTMLBytes + 1) + "</p>"
        do {
            _ = try BlockNoteHTMLParser.parse(hugeBytes)
            XCTFail("expected tooLarge for oversized byte count")
        } catch let error as BlockNoteHTMLParser.Error {
            XCTAssertEqual(error, .tooLarge)
        }

        // Excessive DOM nesting (> 256)
        let deepDOM = String(repeating: "<div>", count: 300) + "x" + String(repeating: "</div>", count: 300)
        do {
            _ = try BlockNoteHTMLParser.parse(deepDOM)
            XCTFail("expected tooLarge for deep DOM")
        } catch let error as BlockNoteHTMLParser.Error {
            XCTAssertEqual(error, .tooLarge)
        }

        // Too many blocks (> 2,000)
        let manyBlocks = String(repeating: "<p>x</p>", count: BlockNoteSubtreePayload.maxBlocks + 1)
        do {
            _ = try BlockNoteHTMLParser.parse(manyBlocks)
            XCTFail("expected tooLarge for >2000 blocks")
        } catch let error as BlockNoteHTMLParser.Error {
            XCTAssertEqual(error, .tooLarge)
        }

        // Oversized UTF-16 text (> 200,000)
        let hugeText = "<p>" + String(repeating: "a", count: NativeClipboard.maxPasteUTF16 + 1) + "</p>"
        do {
            _ = try BlockNoteHTMLParser.parse(hugeText)
            XCTFail("expected tooLarge for >200k UTF-16")
        } catch let error as BlockNoteHTMLParser.Error {
            XCTAssertEqual(error, .tooLarge)
        }

        // Deeply nested list (> maxNestingDepth) clamps instead of failing payload validation.
        let deepList = String(repeating: "<ul><li>x", count: 25) + String(repeating: "</li></ul>", count: 25)
        let clamped = try BlockNoteHTMLParser.parse(deepList)
        let shape = try BlockNoteSubtreePayload.validate(clamped)
        XCTAssertLessThanOrEqual(shape.depth, BlockNoteWriter.maxNestingDepth)

        // Script-only input produces empty blocks cleanly.
        XCTAssertTrue(try BlockNoteHTMLParser.parse("<script>1</script><style>a{}</style>").isEmpty)
    }

    func testCRLFIsCollapsedAcrossContainersChecklistsAndTables() throws {
        let html =
            "<div>\r\n<p>Hello\r\nworld</p>\r\n</div>"
            + "<ul><li>\r\n<input type=\"checkbox\" checked> Done</li></ul>"
            + "<table><tr><td>A\r\nB</td></tr></table>"
        let copies = try BlockNoteHTMLParser.parse(html)
        let (doc, blocks) = try project(copies)
        defer { doc.destroy() }

        XCTAssertEqual(blocks.map(\.block.node), ["paragraph", "checkListItem", "table"])
        guard blocks.count == 3 else { return }
        XCTAssertEqual(blocks[0].block.runs.map(\.text).joined(), "Hello world")
        XCTAssertEqual(blocks[1].block.props.first { $0.key == "checked" }?.value, .bool(true))
        XCTAssertEqual(blocks[1].block.runs.map(\.text).joined(), "Done")
        let table = try XCTUnwrap(TableGrid.tables(in: doc).values.first)
        XCTAssertEqual(table.rows[0][0].runs.map(\.text).joined(), "A B")
    }

    func testTopLevelListItemWithImageAndNestedListDoesNotAttachChildrenToImage() throws {
        let html = """
            <ul>
              <li>
                <p>Lead <img src="https://images.example/a.png" alt="Pic"></p>
                <ul><li>Child</li></ul>
              </li>
              <li>
                <p><img src="https://images.example/b.png" alt="Only"></p>
                <ul><li>Sibling</li></ul>
              </li>
            </ul>
            """
        let copies = try BlockNoteHTMLParser.parse(html)
        let (doc, blocks) = try project(copies)
        defer { doc.destroy() }

        XCTAssertEqual(
            blocks.map(\.block.node),
            ["bulletListItem", "image", "bulletListItem", "image", "bulletListItem"])
        XCTAssertEqual(blocks.map(\.depth), [0, 0, 0, 0, 0])
        // Neither image may carry nested children (the engine refuses root-only blocks with children).
        for copy in copies {
            guard case .element("blockContainer", _, let kids) = copy,
                case .element("image", _, _)? = kids.first
            else { continue }
            XCTAssertEqual(kids.count, 1, "image container must never have a nested blockGroup")
        }
    }

    func testManyInlineRunsAndWideRaggedTableStayWithinLinearTimeBounds() throws {
        // #5: alternating bold/plain runs and coalesced runs must append in place, not quadratically.
        let alternating = "<p>" + String(repeating: "<b>a</b>a", count: 15_000) + "</p>"
        let startAlt = ThreadCPUClock.now
        let altCopies = try BlockNoteHTMLParser.parse(alternating)
        let elapsedAlt = ThreadCPUClock.now - startAlt
        XCTAssertEqual(altCopies.count, 1)
        XCTAssertLessThan(elapsedAlt, .milliseconds(500), "alternating runs should parse linearly, took \(elapsedAlt)")

        let coalesced = "<p>" + String(repeating: "<span>aaaaaaaaaa</span>", count: 15_000) + "</p>"
        let startCoal = ThreadCPUClock.now
        let coalCopies = try BlockNoteHTMLParser.parse(coalesced)
        let elapsedCoal = ThreadCPUClock.now - startCoal
        XCTAssertEqual(coalCopies.count, 1)
        XCTAssertLessThan(elapsedCoal, .milliseconds(500), "coalesced runs should append in place, took \(elapsedCoal)")

        // #8: 500-wide row + 500 one-cell rows must fail bounding size check before materializing 250k cells.
        let wideRagged =
            "<table><tr><td colspan=\"500\">a</td></tr>"
            + String(repeating: "<tr><td>x</td></tr>", count: 500) + "</table>"
        let startTable = ThreadCPUClock.now
        do {
            _ = try BlockNoteHTMLParser.parse(wideRagged)
            XCTFail("expected tooLarge for 500x501 ragged table")
        } catch let error as BlockNoteHTMLParser.Error {
            XCTAssertEqual(error, .tooLarge)
        }
        let elapsedTable = ThreadCPUClock.now - startTable
        XCTAssertLessThan(
            elapsedTable, .milliseconds(250), "bounding table size must reject before fixTable, took \(elapsedTable)")
    }
}
