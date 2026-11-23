import XCTest

@testable import Schrift

@MainActor
final class DocumentEngineBlockPasteTests: DocumentEngineTestCase {
    private func paragraph(_ id: String, _ text: String, props: [(key: String, value: YAnyValue)]? = nil)
        -> BlockNoteBlock
    {
        BlockNoteBlock(
            node: "paragraph", props: props ?? Self.paragraphProps,
            runs: text.isEmpty ? [] : [InlineRun(text)], id: id)
    }

    private func heading(_ id: String, level: Int, _ text: String, toggleable: Bool = false) -> BlockNoteBlock {
        BlockNoteBlock(
            node: "heading",
            props: Self.paragraphProps + [("level", .int(level)), ("isToggleable", .bool(toggleable))],
            runs: text.isEmpty ? [] : [InlineRun(text)], id: id)
    }

    private func bullet(_ id: String, _ text: String, children: [BlockNoteBlock] = []) -> BlockNoteBlock {
        BlockNoteBlock(
            node: "bulletListItem", props: Self.paragraphProps,
            runs: text.isEmpty ? [] : [InlineRun(text)], id: id, children: children)
    }

    private func codeBlock(_ id: String, language: String = "swift", _ text: String) -> BlockNoteBlock {
        BlockNoteBlock(
            node: "codeBlock", props: [("language", .string(language))],
            runs: text.isEmpty ? [] : [InlineRun(text)], id: id)
    }

    @discardableResult
    private func paste(
        _ engine: DocumentEngine, payload: Data, blockID: String, startOffset: Int,
        endBlockID: String? = nil, endOffset: Int? = nil
    ) throws -> EditorPosition {
        let range = NativePasteRange(
            startOffset: startOffset, endBlockID: endBlockID ?? blockID, endOffset: endOffset ?? startOffset)
        return try engine.applyStructural(
            NativeEditCommand(
                id: UUID(), baseRevision: engine.revision, blockID: blockID,
                kind: .insertSubtrees(payload: payload, replacing: range)),
            persist: { _ in })
    }

    private func tableDoc(cellText: String = "before after") throws -> YDoc {
        let tableCopy = try XCTUnwrap(
            try BlockNoteHTMLParser.parse("<table><tr><td>\(cellText)</td><td>B</td></tr></table>").first)
        let bytes = try BlockNoteSubtreePayload.encode([tableCopy])
        let doc = YDoc(clientID: 2, gc: true)
        try doc.applyUpdate(YUpdateDecoder.decode(bytes))
        return doc
    }

    // MARK: - 3A Slice Merge

    func testPasteMidParagraphMergesPrefixAndSuffixAndPlacesCaret() throws {
        let doc = try makeDoc([paragraph("p1", "Hello world")], clientID: 2)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        defer { engine.detach() }

        let payload = try XCTUnwrap(try BlockNoteHTMLParser.payload("<h1><strong>Big</strong></h1><p>End </p>"))
        let caret = try paste(engine, payload: payload, blockID: "p1", startOffset: 6)

        assertSurfaceMatchesProjection(surface, doc, "mid-paragraph paste")
        XCTAssertEqual(surface.blocks.count, 2)
        XCTAssertEqual(surface.blocks[0].id, "p1")
        XCTAssertEqual(surface.blocks[0].node, "paragraph")
        XCTAssertEqual(text(of: surface.blocks[0]), "Hello Big")
        XCTAssertEqual(surface.blocks[0].runs.last?.marks.map(\.key), ["bold"])
        XCTAssertEqual(surface.blocks[1].node, "paragraph")
        XCTAssertEqual(text(of: surface.blocks[1]), "Endworld")
        XCTAssertEqual(caret, EditorPosition(blockID: surface.blocks[1].id, offset: 3, assoc: -1))
        XCTAssertNotNil(NativeBlockProjection.markdownShadow(doc))
    }

    func testPasteOverMultiBlockSelectionDeletesMiddleAndMergesEndpoints() throws {
        let doc = try makeDoc(
            [paragraph("p1", "Alpha beta"), paragraph("p2", "Middle gone"), paragraph("p3", "gamma delta")],
            clientID: 2)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        defer { engine.detach() }

        let payload = try XCTUnwrap(try BlockNoteMarkdownPaste.payload("ONE\n- TWO\nTHREE"))
        let caret = try paste(
            engine, payload: payload, blockID: "p1", startOffset: 6, endBlockID: "p3", endOffset: 6)

        assertSurfaceMatchesProjection(surface, doc, "multi-block selection paste")
        XCTAssertEqual(surface.blocks.map(\.node), ["paragraph", "bulletListItem", "paragraph"])
        XCTAssertEqual(surface.blocks.map(text(of:)), ["Alpha ONE", "TWO", "THREEdelta"])
        XCTAssertEqual(surface.blocks[0].id, "p1")
        XCTAssertEqual(caret, EditorPosition(blockID: surface.blocks[2].id, offset: 5, assoc: -1))
        XCTAssertNotNil(NativeBlockProjection.markdownShadow(doc))
    }

    func testPasteIntoEmptyParagraphReplacesItPreservingPastedBlockTypes() throws {
        let doc = try makeDoc([paragraph("empty", "")], clientID: 2)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        defer { engine.detach() }

        let payload = try XCTUnwrap(try BlockNoteMarkdownPaste.payload("# Title\n- Bullet\nBody"))
        let caret = try paste(engine, payload: payload, blockID: "empty", startOffset: 0)

        assertSurfaceMatchesProjection(surface, doc, "empty paragraph replaced")
        XCTAssertEqual(surface.blocks.map(\.node), ["heading", "bulletListItem", "paragraph"])
        XCTAssertEqual(surface.blocks.map(text(of:)), ["Title", "Bullet", "Body"])
        XCTAssertEqual(surface.blocks[0].props.first { $0.key == "level" }?.value, .int(1))
        XCTAssertEqual(caret, EditorPosition(blockID: surface.blocks[2].id, offset: 4, assoc: -1))
        XCTAssertNotNil(NativeBlockProjection.markdownShadow(doc))
    }

    func testPasteIntoHeadingAndListItemKeepsTargetTypeAndProps() throws {
        let doc = try makeDoc(
            [heading("h2", level: 2, "Chapter End"), bullet("b1", "")], clientID: 2)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        defer { engine.detach() }

        let multi = try XCTUnwrap(try BlockNoteMarkdownPaste.payload("One\nTwo"))
        _ = try paste(engine, payload: multi, blockID: "h2", startOffset: 8)

        assertSurfaceMatchesProjection(surface, doc, "heading paste")
        XCTAssertEqual(surface.blocks[0].id, "h2")
        XCTAssertEqual(surface.blocks[0].node, "heading")
        XCTAssertEqual(surface.blocks[0].props.first { $0.key == "level" }?.value, .int(2))
        XCTAssertEqual(text(of: surface.blocks[0]), "Chapter One")
        XCTAssertEqual(surface.blocks[1].node, "paragraph")
        XCTAssertEqual(text(of: surface.blocks[1]), "TwoEnd")

        // Pasting a paragraph into an empty bullet list item keeps it a bullet list item.
        let single = try XCTUnwrap(try BlockNoteMarkdownPaste.payload("Item text"))
        let caret = try paste(engine, payload: single, blockID: "b1", startOffset: 0)
        assertSurfaceMatchesProjection(surface, doc, "empty bullet paste")
        let b1 = try XCTUnwrap(block(surface, "b1"))
        XCTAssertEqual(b1.node, "bulletListItem")
        XCTAssertEqual(text(of: b1), "Item text")
        XCTAssertEqual(caret, EditorPosition(blockID: "b1", offset: 9, assoc: -1))
    }

    func testPasteWithImageAndTableSplitsAroundNonTextblocks() throws {
        // 1. Image in the middle of a multi-block paste mid-paragraph.
        let doc1 = try makeDoc([paragraph("p1", "Hello world")], clientID: 2)
        defer { doc1.destroy() }
        let surface1 = HeadlessSurface(blocks: projection(doc1))
        let engine1 = DocumentEngine(doc: doc1, surface: surface1)
        defer { engine1.detach() }

        let withImage = try XCTUnwrap(
            try BlockNoteMarkdownPaste.payload("Lead\n![Cat](https://images.example/cat.png)\nTrail"))
        _ = try paste(engine1, payload: withImage, blockID: "p1", startOffset: 6)
        assertSurfaceMatchesProjection(surface1, doc1, "image in middle")
        XCTAssertEqual(surface1.blocks.map(\.node), ["paragraph", "image", "paragraph"])
        XCTAssertEqual(text(of: surface1.blocks[0]), "Hello Lead")
        XCTAssertEqual(text(of: surface1.blocks[2]), "Trailworld")
        XCTAssertNotNil(NativeBlockProjection.markdownShadow(doc1))

        // 2. Single table pasted mid-paragraph splits prefix and suffix into separate blocks.
        let doc2 = try makeDoc([paragraph("p1", "Hello world")], clientID: 2)
        defer { doc2.destroy() }
        let surface2 = HeadlessSurface(blocks: projection(doc2))
        let engine2 = DocumentEngine(doc: doc2, surface: surface2)
        defer { engine2.detach() }

        let onlyTable = try XCTUnwrap(try BlockNoteMarkdownPaste.payload("| A | B |\n| - | - |\n| 1 | 2 |"))
        let caret2 = try paste(engine2, payload: onlyTable, blockID: "p1", startOffset: 6)
        assertSurfaceMatchesProjection(surface2, doc2, "table splits paragraph")
        XCTAssertEqual(surface2.blocks.map(\.node), ["paragraph", "table", "paragraph"])
        guard surface2.blocks.count == 3 else { return }
        XCTAssertEqual(text(of: surface2.blocks[0]), "Hello ")
        XCTAssertEqual(text(of: surface2.blocks[2]), "world")
        XCTAssertEqual(caret2, EditorPosition(blockID: surface2.blocks[2].id, offset: 0, assoc: -1))
        XCTAssertNotNil(NativeBlockProjection.markdownShadow(doc2))

        // 3. Single code block pasted at offset 0 inserts before without an empty leading paragraph.
        let doc3 = try makeDoc([paragraph("p1", "After")], clientID: 2)
        defer { doc3.destroy() }
        let surface3 = HeadlessSurface(blocks: projection(doc3))
        let engine3 = DocumentEngine(doc: doc3, surface: surface3)
        defer { engine3.detach() }

        let onlyCode = try XCTUnwrap(try BlockNoteMarkdownPaste.payload("```js\n1 + 1\n```"))
        let caret3 = try paste(engine3, payload: onlyCode, blockID: "p1", startOffset: 0)
        assertSurfaceMatchesProjection(surface3, doc3, "code at offset 0")
        XCTAssertEqual(surface3.blocks.map(\.node), ["codeBlock", "paragraph"])
        XCTAssertEqual(text(of: surface3.blocks[0]), "1 + 1")
        XCTAssertEqual(text(of: surface3.blocks[1]), "After")
        XCTAssertEqual(caret3, EditorPosition(blockID: "p1", offset: 0, assoc: -1))
    }

    // MARK: - 4A Table Cell & Code Block

    func testPasteIntoTableCellFlattensToInlineRunsWithMarksAndHardBreaks() throws {
        let doc = try tableDoc(cellText: "before after")
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        defer { engine.detach() }

        let tableID = try XCTUnwrap(surface.blocks.first?.id)
        XCTAssertTrue(engine.openTable(tableID))
        let cellID = try XCTUnwrap(engine.tableParagraphs(tableID)?.first?.id)

        let html = "<h2><strong>Title</strong></h2><p>Line 1<br><a href=\"https://example.com\">Link</a></p>"
        let payload = try XCTUnwrap(try BlockNoteHTMLParser.payload(html))
        let caret = try paste(engine, payload: payload, blockID: cellID, startOffset: 6, endOffset: 7)

        let grid = try XCTUnwrap(engine.tableGrid(tableID))
        XCTAssertTrue(grid.isFamiliar)
        let runs = grid.rows[0][0].runs
        XCTAssertEqual(runs.map(\.text).joined(), "beforeTitle\nLine 1\nLinkafter")
        XCTAssertEqual(runs.first { $0.text == "Title" }?.marks.map(\.key), ["bold"])
        let linkRun = try XCTUnwrap(runs.first { $0.text == "Link" })
        XCTAssertEqual(linkRun.marks.map(\.key), ["link"])
        XCTAssertEqual(YBlockProjection.linkHref(from: linkRun.marks[0].valueJSON), "https://example.com")
        // Inserted UTF-16 length: "Title"(5) + "\n"(1) + "Line 1"(6) + "\n"(1) + "Link"(4) = 17
        XCTAssertEqual(caret, EditorPosition(blockID: cellID, offset: 6 + 17, assoc: -1))
        XCTAssertNotNil(NativeBlockProjection.markdownShadow(doc))
    }

    func testPasteIntoCodeBlockInsertsUnmarkedPlainText() throws {
        let doc = try makeDoc([codeBlock("c1", "let x = 0")], clientID: 2)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        defer { engine.detach() }

        let payload = try XCTUnwrap(try BlockNoteHTMLParser.payload("<h1><strong>Head</strong></h1><p>a<br>b</p>"))
        let caret = try paste(engine, payload: payload, blockID: "c1", startOffset: 8, endOffset: 9)

        assertSurfaceMatchesProjection(surface, doc, "code block plain paste")
        XCTAssertEqual(surface.blocks.count, 1)
        XCTAssertEqual(surface.blocks[0].node, "codeBlock")
        XCTAssertEqual(text(of: surface.blocks[0]), "let x = Head\na\nb")
        XCTAssertTrue(surface.blocks[0].runs.allSatisfy(\.marks.isEmpty))
        XCTAssertEqual(caret, EditorPosition(blockID: "c1", offset: 8 + "Head\na\nb".utf16.count, assoc: -1))
    }

    // MARK: - Single-step Undo

    func testSingleStepUndoRestoresWholeDocumentAcrossContexts() throws {
        // 1. Multi-block selection + image split paste undone in one step.
        let doc = try makeDoc(
            [paragraph("p1", "Hello world"), paragraph("p2", "Middle"), paragraph("p3", "Tail end")],
            clientID: 2)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        defer { engine.detach() }
        let root = try XCTUnwrap(doc.share[BlockNoteYjs.fragmentField])
        let undo = YUndoManager(doc: doc, scope: [root], captureTimeout: 0, trackedOrigins: [.localUser])
        defer { undo.destroy() }

        let before = projection(doc)
        let payload = try XCTUnwrap(
            try BlockNoteMarkdownPaste.payload("First\n![Img](https://images.example/a.png)\nSecond"))
        _ = try paste(engine, payload: payload, blockID: "p1", startOffset: 6, endBlockID: "p3", endOffset: 5)
        XCTAssertEqual(undo.undoStack.count, 1, "paste must record one undo step")
        XCTAssertEqual(surface.blocks.map(\.node), ["paragraph", "image", "paragraph"])

        let undone = try engine.applyHistoryStep(
            NativeEditCommand(id: UUID(), baseRevision: engine.revision, blockID: "", kind: .undo),
            step: { try undo.undo() != nil }, persist: { _ in })
        XCTAssertTrue(undone)
        assertSurfaceMatchesProjection(surface, doc, "after single undo")
        XCTAssertEqual(surface.blocks, before)
        XCTAssertEqual(undo.undoStack.count, 0)

        // 2. Table cell flattened paste undone in one step.
        let tDoc = try tableDoc(cellText: "cell text")
        defer { tDoc.destroy() }
        let tSurface = HeadlessSurface(blocks: projection(tDoc))
        let tEngine = DocumentEngine(doc: tDoc, surface: tSurface)
        defer { tEngine.detach() }
        let tRoot = try XCTUnwrap(tDoc.share[BlockNoteYjs.fragmentField])
        let tUndo = YUndoManager(doc: tDoc, scope: [tRoot], captureTimeout: 0, trackedOrigins: [.localUser])
        defer { tUndo.destroy() }

        let tableID = try XCTUnwrap(tSurface.blocks.first?.id)
        XCTAssertTrue(tEngine.openTable(tableID))
        let cellID = try XCTUnwrap(tEngine.tableParagraphs(tableID)?.first?.id)
        let cellPayload = try XCTUnwrap(try BlockNoteHTMLParser.payload("<p><strong>A</strong></p><p>B</p>"))
        _ = try paste(tEngine, payload: cellPayload, blockID: cellID, startOffset: 5)
        XCTAssertEqual(tUndo.undoStack.count, 1)
        XCTAssertEqual(tEngine.tableGrid(tableID)?.rows[0][0].runs.map(\.text).joined(), "cell A\nBtext")

        _ = try tEngine.applyHistoryStep(
            NativeEditCommand(id: UUID(), baseRevision: tEngine.revision, blockID: "", kind: .undo),
            step: { try tUndo.undo() != nil }, persist: { _ in })
        XCTAssertEqual(tEngine.tableGrid(tableID)?.rows[0][0].runs.map(\.text).joined(), "cell text")
    }

    // MARK: - Guards

    func testPasteRespectsGuardsForLockedOpaqueToggleSourceNestingAndSize() throws {
        let styledProps: [(key: String, value: YAnyValue)] = [
            ("backgroundColor", .string("default")), ("textColor", .string("red")), ("textAlignment", .string("left")),
        ]
        let lockedProps = Self.paragraphProps + [("x-unknown", .string("kept"))]
        let doc = try makeDoc(
            [
                paragraph("styled", "Red text", props: styledProps),
                paragraph("locked", "Locked text", props: lockedProps),
                heading("toggle", level: 1, "Folded title", toggleable: true),
                bullet("parent", "Parent", children: [paragraph("nested", "Nested child")]),
                BlockNoteBlock(node: "mathBlock", props: [], runs: [InlineRun("x^2")], id: "math1"),
            ], clientID: 2)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        defer { engine.detach() }

        let twoBlocks = try XCTUnwrap(try BlockNoteMarkdownPaste.payload("A\nB"))
        let imagePayload = try XCTUnwrap(try BlockNoteMarkdownPaste.payload("![x](https://images.example/a.png)"))

        // Toggle (folded-content guard) is refused.
        do {
            _ = try paste(engine, payload: twoBlocks, blockID: "toggle", startOffset: 0)
            XCTFail("expected toggle refusal")
        } catch let error as DocumentEngineError {
            XCTAssertEqual(error, .unsupportedNativeInput)
        }

        // Locked-text `.lossy` block refuses multi-block split paste.
        do {
            _ = try paste(engine, payload: twoBlocks, blockID: "locked", startOffset: 3)
            XCTFail("expected locked-text refusal")
        } catch let error as DocumentEngineError {
            XCTAssertEqual(error, .unsupportedNativeInput)
        }

        // Open source surface (`mathBlock`) refuses block paste.
        let sourceID = try XCTUnwrap(engine.openSource(.block(id: "math1")))
        do {
            _ = try paste(engine, payload: twoBlocks, blockID: sourceID, startOffset: 0)
            XCTFail("expected source editor refusal")
        } catch let error as DocumentEngineError {
            XCTAssertEqual(error, .unsupportedNativeInput)
        }

        // Nesting an image/table inside a nested block (`depth > 0`) is refused.
        do {
            _ = try paste(engine, payload: imagePayload, blockID: "nested", startOffset: 0)
            XCTFail("expected nested media refusal")
        } catch let error as DocumentEngineError {
            XCTAssertEqual(error, .unsupportedNativeInput)
        }

        // Oversized payload throws `.payloadTooLarge`.
        let oversized = Data(count: BlockNoteSubtreePayload.maxBytes + 1)
        do {
            _ = try paste(engine, payload: oversized, blockID: "styled", startOffset: 0)
            XCTFail("expected payloadTooLarge")
        } catch let error as DocumentEngineError {
            XCTAssertEqual(error, .payloadTooLarge)
        }

        // Styled-only `.lossy` block admits multi-block paste and keeps its styling prop.
        _ = try paste(engine, payload: twoBlocks, blockID: "styled", startOffset: 4)
        assertSurfaceMatchesProjection(surface, doc, "styled-only lossy paste")
        XCTAssertEqual(text(of: surface.blocks[0]), "Red A")
        XCTAssertEqual(surface.blocks[0].props.first { $0.key == "textColor" }?.value, .string("red"))
        XCTAssertEqual(text(of: surface.blocks[1]), "Btext")

        // Opaque block and surrogate-splitting offsets are refused without freezing the engine.
        let emojiDoc = try makeDoc(
            [
                BlockNoteBlock(node: "unknownWidget", props: [], runs: [], id: "opaque1"),
                paragraph("emoji", "😀"),
            ], clientID: 2)
        defer { emojiDoc.destroy() }
        let emojiEngine = DocumentEngine(doc: emojiDoc, surface: HeadlessSurface(blocks: projection(emojiDoc)))
        defer { emojiEngine.detach() }
        do {
            _ = try paste(emojiEngine, payload: twoBlocks, blockID: "opaque1", startOffset: 0)
            XCTFail("expected opaque block refusal")
        } catch let error as DocumentEngineError {
            XCTAssertEqual(error, .unsupportedNativeInput)
        }
        do {
            _ = try paste(emojiEngine, payload: twoBlocks, blockID: "emoji", startOffset: 1)
            XCTFail("expected surrogate-split refusal")
        } catch let error as DocumentEngineError {
            XCTAssertEqual(error, .unsupportedNativeInput)
        }
        XCTAssertFalse(emojiEngine.nativeWriteFailed)
    }
}
