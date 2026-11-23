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

    func testGoogleDocsInlineWrapperAroundBlocksPreservesBlockStructure() throws {
        let html =
            "<b style=\"font-weight:normal;\" id=\"docs-internal-guid-x\">"
            + "<h1>Title</h1><p>First</p><p>Second</p>"
            + "<ul><li>One</li><li>Two</li></ul><hr>"
            + "<table><tr><td>A</td><td>B</td></tr></table></b>"
        let copies = try BlockNoteHTMLParser.parse(html)
        let (doc, blocks) = try project(copies)
        defer { doc.destroy() }

        XCTAssertEqual(
            blocks.map(\.block.node),
            ["heading", "paragraph", "paragraph", "bulletListItem", "bulletListItem", "divider", "table"])
        guard blocks.count == 7 else { return }
        XCTAssertEqual(blocks[0].block.props.first { $0.key == "level" }?.value, .int(1))
        XCTAssertEqual(blocks[0].block.runs.map(\.text).joined(), "Title")
        XCTAssertEqual(blocks[1].block.runs.map(\.text).joined(), "First")
        XCTAssertEqual(blocks[2].block.runs.map(\.text).joined(), "Second")
        XCTAssertEqual(blocks[3].block.runs.map(\.text).joined(), "One")
        XCTAssertEqual(blocks[4].block.runs.map(\.text).joined(), "Two")
        XCTAssertEqual(blocks[3].depth, 0)
        XCTAssertEqual(blocks[4].depth, 0)
        let table = try XCTUnwrap(TableGrid.tables(in: doc).values.first)
        XCTAssertEqual(table.rows.map { $0.map { $0.runs.map(\.text).joined() } }, [["A", "B"]])
        XCTAssertNotNil(NativeBlockProjection.markdownShadow(doc))

        // Nested inline wrappers around block elements are also transparent.
        let nestedCopies = try BlockNoteHTMLParser.parse("<span><b><p>Alpha</p><p>Beta</p></b></span>")
        let (nestedDoc, nestedBlocks) = try project(nestedCopies)
        defer { nestedDoc.destroy() }
        XCTAssertEqual(nestedBlocks.map(\.block.node), ["paragraph", "paragraph"])
        XCTAssertEqual(nestedBlocks.map { $0.block.runs.map(\.text).joined() }, ["Alpha", "Beta"])
    }

    func testBlockNoteContainerAlwaysWalksNestedBlockGroupWhenContentEmitsNothing() throws {
        let html = """
            <div data-node-type="blockContainer">
              <div data-content-type="paragraph"><p></p></div>
              <div data-node-type="blockGroup">
                <div data-node-type="blockContainer">
                  <div data-content-type="paragraph"><p>From empty</p></div>
                </div>
              </div>
            </div>
            <div data-node-type="blockContainer">
              <div data-content-type="image"><img src="http://insecure.example/x.png" alt="Dropped"></div>
              <div data-node-type="blockGroup">
                <div data-node-type="blockContainer">
                  <div data-content-type="paragraph"><p>From dropped image</p></div>
                </div>
              </div>
            </div>
            <div data-node-type="blockContainer">
              <div data-content-type="bulletListItem"><p>Outer</p></div>
              <div data-node-type="blockGroup">
                <div data-node-type="blockContainer">
                  <div data-content-type="image"><img src="https://images.example/a.png" alt="Hoisted"></div>
                  <div data-node-type="blockGroup">
                    <div data-node-type="blockContainer">
                      <div data-content-type="paragraph"><p>From hoisted media</p></div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
            """
        let copies = try BlockNoteHTMLParser.parse(html)
        let (doc, blocks) = try project(copies)
        defer { doc.destroy() }

        XCTAssertEqual(
            blocks.map(\.block.node),
            ["paragraph", "paragraph", "bulletListItem", "paragraph", "image"])
        XCTAssertEqual(blocks.map(\.depth), [0, 0, 0, 1, 0])
        XCTAssertEqual(
            blocks.map { $0.block.runs.map(\.text).joined() },
            ["From empty", "From dropped image", "Outer", "From hoisted media", ""])
        guard blocks.count == 5 else { return }
        XCTAssertEqual(blocks[4].block.props.first { $0.key == "url" }?.value, .string("https://images.example/a.png"))
        XCTAssertEqual(blocks[4].block.props.first { $0.key == "name" }?.value, .string("Hoisted"))
    }

    func testPreCollectsMultipleCodeChildrenAndBlockNoteCodeBlockReadsNestedLanguage() throws {
        let html =
            "<pre><code>line 1</code>\n<code>line 2</code></pre>"
            + "<div data-content-type=\"codeBlock\"><pre><code class=\"language-swift\">let x = 1\n</code></pre></div>"
        let copies = try BlockNoteHTMLParser.parse(html)
        let (doc, blocks) = try project(copies)
        defer { doc.destroy() }

        XCTAssertEqual(blocks.map(\.block.node), ["codeBlock", "codeBlock"])
        guard blocks.count == 2 else { return }
        XCTAssertEqual(blocks[0].block.props.first { $0.key == "language" }?.value, .string("text"))
        XCTAssertEqual(blocks[0].block.runs.map(\.text).joined(), "line 1\nline 2")
        XCTAssertEqual(blocks[1].block.props.first { $0.key == "language" }?.value, .string("swift"))
        XCTAssertEqual(blocks[1].block.runs.map(\.text).joined(), "let x = 1")
    }

    func testListPreservesStrayParagraphAndLooseTextChildren() throws {
        let html = "<ul><p>Intro</p><li>Item</li></ul><ul>Loose text<li>Next</li></ul>"
        let copies = try BlockNoteHTMLParser.parse(html)
        let (doc, blocks) = try project(copies)
        defer { doc.destroy() }

        XCTAssertEqual(blocks.map(\.block.node), ["paragraph", "bulletListItem", "paragraph", "bulletListItem"])
        XCTAssertEqual(blocks.map(\.depth), [0, 0, 0, 0])
        XCTAssertEqual(blocks.map { $0.block.runs.map(\.text).joined() }, ["Intro", "Item", "Loose text", "Next"])
    }

    func testBlockquoteRecursesThroughDivWrappers() throws {
        let html = "<blockquote><div><p>First</p><p>Second</p></div></blockquote>"
        let copies = try BlockNoteHTMLParser.parse(html)
        let (doc, blocks) = try project(copies)
        defer { doc.destroy() }

        XCTAssertEqual(blocks.map(\.block.node), ["quote", "quote"])
        XCTAssertEqual(blocks.map { $0.block.runs.map(\.text).joined() }, ["First", "Second"])
    }

    func testBlockNoteSelfTaggedTableAndInvalidBeforeValidImage() throws {
        let html =
            "<table data-content-type=\"table\"><tr><td>Cell 1</td><td>Cell 2</td></tr></table>"
            + "<div data-content-type=\"image\">"
            + "<img src=\"http://insecure.example/bad.png\" alt=\"Bad\">"
            + "<img src=\"https://images.example/good.png\" alt=\"Good\"></div>"
        let copies = try BlockNoteHTMLParser.parse(html)
        let (doc, blocks) = try project(copies)
        defer { doc.destroy() }

        XCTAssertEqual(blocks.map(\.block.node), ["table", "image"])
        guard blocks.count == 2 else { return }
        let table = try XCTUnwrap(TableGrid.tables(in: doc).values.first)
        XCTAssertEqual(table.rows.map { $0.map { $0.runs.map(\.text).joined() } }, [["Cell 1", "Cell 2"]])
        XCTAssertEqual(
            blocks[1].block.props.first { $0.key == "url" }?.value, .string("https://images.example/good.png"))
        XCTAssertEqual(blocks[1].block.props.first { $0.key == "name" }?.value, .string("Good"))
    }

    func testOversizedHrefAndMarkByteAmplificationStayBounded() throws {
        // Exact boundary: href at MediaBlock.maxURL keeps the link mark; +1 drops only the mark, keeping text.
        let prefix = "https://example.com/"
        let exactHref = prefix + String(repeating: "a", count: MediaBlock.maxURL - prefix.count)
        let overHref = exactHref + "b"
        let boundaryCopies = try BlockNoteHTMLParser.parse(
            "<p><a href=\"\(exactHref)\">Exact</a> <a href=\"\(overHref)\">Over</a></p>")
        let (boundaryDoc, boundaryBlocks) = try project(boundaryCopies)
        defer { boundaryDoc.destroy() }
        XCTAssertEqual(boundaryBlocks.count, 1)
        let boundaryRuns = boundaryBlocks[0].block.runs
        XCTAssertEqual(boundaryRuns.map(\.text), ["Exact", " Over"])
        if boundaryRuns.count == 2 {
            XCTAssertEqual(boundaryRuns[0].marks.map(\.key), ["link"])
            XCTAssertEqual(YBlockProjection.linkHref(from: boundaryRuns[0].marks[0].valueJSON), exactHref)
            XCTAssertTrue(boundaryRuns[1].marks.isEmpty)
        }

        // 1 MB href over 1,999 <br> must strip the overlong href and produce a tiny payload quickly (never ~2 GB).
        let oneMBHref = prefix + String(repeating: "a", count: 1_000_000)
        let oneMBHTML = "<a href=\"" + oneMBHref + "\">" + String(repeating: "x<br>", count: 1_999) + "x</a>"
        let startLarge = ThreadCPUClock.now
        let largePayload = try XCTUnwrap(try BlockNoteHTMLParser.payload(oneMBHTML))
        let elapsedLarge = ThreadCPUClock.now - startLarge
        XCTAssertLessThan(
            elapsedLarge, .milliseconds(500),
            "1 MB href over 1,999 <br> should strip overlong href quickly, took \(elapsedLarge)")
        XCTAssertLessThan(
            largePayload.count, oneMBHref.utf8.count,
            "payload (\(largePayload.count) bytes) must not keep or amplify the 1 MB href")
        let decodedLarge = try BlockNoteSubtreePayload.decode(largePayload)
        XCTAssertEqual(decodedLarge.count, 2_000)
        for container in decodedLarge {
            guard case .element("blockContainer", _, let kids) = container,
                case .element("paragraph", _, let inline)? = kids.first,
                case .text(let values)? = inline.first,
                case .run(let run)? = values.first
            else { return XCTFail("expected plain paragraph block for every split line") }
            XCTAssertEqual(run.text, "x")
            XCTAssertTrue(run.marks.isEmpty, "overlong href link mark must be stripped")
        }

        // Legal maxURL href duplicated over 1,999 <br> (~4 MB of mark bytes) must throw .tooLarge quickly.
        let amplifiedHTML = "<a href=\"" + exactHref + "\">" + String(repeating: "x<br>", count: 1_999) + "x</a>"
        let startAmplified = ThreadCPUClock.now
        do {
            _ = try BlockNoteHTMLParser.parse(amplifiedHTML)
            XCTFail("expected tooLarge when duplicated link marks exceed payload byte bound")
        } catch let error as BlockNoteHTMLParser.Error {
            XCTAssertEqual(error, .tooLarge)
        }
        let elapsedAmplified = ThreadCPUClock.now - startAmplified
        XCTAssertLessThan(
            elapsedAmplified, .milliseconds(250),
            "mark-byte amplification must fail fast during parse, took \(elapsedAmplified)")
    }

    func testTransparentInlineWrappersPropagateMarksToBlockDescendants() throws {
        // 1. <b><p>Important</p></b> keeps bold.
        let boldCopies = try BlockNoteHTMLParser.parse("<b><p>Important</p></b>")
        let (boldDoc, boldBlocks) = try project(boldCopies)
        defer { boldDoc.destroy() }
        XCTAssertEqual(boldBlocks.map(\.block.node), ["paragraph"])
        XCTAssertEqual(boldBlocks.first?.block.runs.map(\.text), ["Important"])
        XCTAssertEqual(boldBlocks.first?.block.runs.first?.marks.map(\.key), ["bold"])

        // 2. <a href="https://example.com"><div><h3>Card</h3><p>Summary</p></div></a> keeps link on both.
        let cardHTML = "<a href=\"https://example.com\"><div><h3>Card</h3><p>Summary</p></div></a>"
        let cardCopies = try BlockNoteHTMLParser.parse(cardHTML)
        let (cardDoc, cardBlocks) = try project(cardCopies)
        defer { cardDoc.destroy() }
        XCTAssertEqual(cardBlocks.map(\.block.node), ["heading", "paragraph"])
        if cardBlocks.count == 2 {
            XCTAssertEqual(cardBlocks[0].block.props.first { $0.key == "level" }?.value, .int(3))
            XCTAssertEqual(cardBlocks[0].block.runs.map(\.text), ["Card"])
            XCTAssertEqual(cardBlocks[0].block.runs.first?.marks.map(\.key), ["link"])
            XCTAssertEqual(
                cardBlocks[0].block.runs.first?.marks.first.flatMap { YBlockProjection.linkHref(from: $0.valueJSON) },
                "https://example.com")
            XCTAssertEqual(cardBlocks[1].block.runs.map(\.text), ["Summary"])
            XCTAssertEqual(cardBlocks[1].block.runs.first?.marks.map(\.key), ["link"])
            XCTAssertEqual(
                cardBlocks[1].block.runs.first?.marks.first.flatMap { YBlockProjection.linkHref(from: $0.valueJSON) },
                "https://example.com")
        }

        // 3. <b>Lead<p>Body</p></b> keeps bold on both paragraphs.
        let leadCopies = try BlockNoteHTMLParser.parse("<b>Lead<p>Body</p></b>")
        let (leadDoc, leadBlocks) = try project(leadCopies)
        defer { leadDoc.destroy() }
        XCTAssertEqual(leadBlocks.map(\.block.node), ["paragraph", "paragraph"])
        XCTAssertEqual(leadBlocks.map { $0.block.runs.map(\.text).joined() }, ["Lead", "Body"])
        for block in leadBlocks {
            XCTAssertEqual(block.block.runs.first?.marks.map(\.key), ["bold"])
        }

        // 4. <blockquote><strong><p>Quoted</p></strong></blockquote> keeps bold on quote.
        let quoteCopies = try BlockNoteHTMLParser.parse("<blockquote><strong><p>Quoted</p></strong></blockquote>")
        let (quoteDoc, quoteBlocks) = try project(quoteCopies)
        defer { quoteDoc.destroy() }
        XCTAssertEqual(quoteBlocks.map(\.block.node), ["quote"])
        XCTAssertEqual(quoteBlocks.first?.block.runs.map(\.text), ["Quoted"])
        XCTAssertEqual(quoteBlocks.first?.block.runs.first?.marks.map(\.key), ["bold"])

        // 5. Google Docs normal-weight <b> stays unbolded, and code blocks ignore wrapper marks.
        let gdocsCopies = try BlockNoteHTMLParser.parse(
            "<b style=\"font-weight:normal;\"><p>Plain</p></b><b><pre><code>let x = 1</code></pre></b>")
        let (gdocsDoc, gdocsBlocks) = try project(gdocsCopies)
        defer { gdocsDoc.destroy() }
        XCTAssertEqual(gdocsBlocks.map(\.block.node), ["paragraph", "codeBlock"])
        if gdocsBlocks.count == 2 {
            XCTAssertEqual(gdocsBlocks[0].block.runs.map(\.text), ["Plain"])
            XCTAssertTrue(gdocsBlocks[0].block.runs.allSatisfy(\.marks.isEmpty))
            XCTAssertEqual(gdocsBlocks[1].block.runs.map(\.text), ["let x = 1"])
            XCTAssertTrue(gdocsBlocks[1].block.runs.allSatisfy(\.marks.isEmpty))
        }
    }

    func testListItemUnwrapsInlineWrappersIntoOwnText() throws {
        // 1. <ul><li><span><p>Buy milk</p></span></li></ul> -> single bulletListItem("Buy milk")
        let spanCopies = try BlockNoteHTMLParser.parse("<ul><li><span><p>Buy milk</p></span></li></ul>")
        let (spanDoc, spanBlocks) = try project(spanCopies)
        defer { spanDoc.destroy() }
        XCTAssertEqual(spanBlocks.map(\.block.node), ["bulletListItem"])
        XCTAssertEqual(spanBlocks.map(\.depth), [0])
        XCTAssertEqual(spanBlocks.map { $0.block.runs.map(\.text).joined() }, ["Buy milk"])

        // 2. <ul><li><label><input type="checkbox"><p>Buy milk</p></label></li></ul> -> checkListItem(false)
        let labelCopies = try BlockNoteHTMLParser.parse(
            "<ul><li><label><input type=\"checkbox\"><p>Buy milk</p></label></li></ul>")
        let (labelDoc, labelBlocks) = try project(labelCopies)
        defer { labelDoc.destroy() }
        XCTAssertEqual(labelBlocks.map(\.block.node), ["checkListItem"])
        XCTAssertEqual(labelBlocks.map(\.depth), [0])
        XCTAssertEqual(labelBlocks.first?.block.props.first { $0.key == "checked" }?.value, .bool(false))
        XCTAssertEqual(labelBlocks.map { $0.block.runs.map(\.text).joined() }, ["Buy milk"])

        // 3. <ul><li><span>Parent<ul><li>Child</li></ul></span></li></ul> -> bullet("Parent") + nested bullet("Child")
        let nestedCopies = try BlockNoteHTMLParser.parse(
            "<ul><li><span>Parent<ul><li>Child</li></ul></span></li></ul>")
        let (nestedDoc, nestedBlocks) = try project(nestedCopies)
        defer { nestedDoc.destroy() }
        XCTAssertEqual(nestedBlocks.map(\.block.node), ["bulletListItem", "bulletListItem"])
        XCTAssertEqual(nestedBlocks.map(\.depth), [0, 1])
        XCTAssertEqual(nestedBlocks.map { $0.block.runs.map(\.text).joined() }, ["Parent", "Child"])

        // 4. Inline marks on wrapper around list item paragraph also propagate.
        let boldCopies = try BlockNoteHTMLParser.parse("<ul><li><b><p>Bold milk</p></b></li></ul>")
        let (boldDoc, boldBlocks) = try project(boldCopies)
        defer { boldDoc.destroy() }
        XCTAssertEqual(boldBlocks.map(\.block.node), ["bulletListItem"])
        XCTAssertEqual(boldBlocks.first?.block.runs.map(\.text), ["Bold milk"])
        XCTAssertEqual(boldBlocks.first?.block.runs.first?.marks.map(\.key), ["bold"])
    }

    func testPreWithSoleCodeChildIgnoresSurroundingWhitespace() throws {
        let html =
            "<pre>\n<code class=\"language-swift\">let x = 1\n</code>\n</pre>"
            + "<pre>\n  <code class=\"language-swift\">let x = 1</code>\n</pre>"
        let copies = try BlockNoteHTMLParser.parse(html)
        let (doc, blocks) = try project(copies)
        defer { doc.destroy() }

        XCTAssertEqual(blocks.map(\.block.node), ["codeBlock", "codeBlock"])
        guard blocks.count == 2 else { return }
        XCTAssertEqual(blocks[0].block.props.first { $0.key == "language" }?.value, .string("swift"))
        XCTAssertEqual(blocks[0].block.runs.map(\.text).joined(), "let x = 1")
        XCTAssertEqual(blocks[1].block.props.first { $0.key == "language" }?.value, .string("swift"))
        XCTAssertEqual(blocks[1].block.runs.map(\.text).joined(), "let x = 1")
    }
}
