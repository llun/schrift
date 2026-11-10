import XCTest

@testable import Schrift

/// The native save's Markdown shadow becomes `lastPushedMarkdown`, which
/// `draftSyncDecision` compares (`canonicalMarkdown`) with the server's
/// Markdown export. For a nested list, a callout, a toggle or a page break the
/// two must agree, or every save of such a document reads as a conflict.
@MainActor
final class NativeShadowExportParityTests: NativeEditingTestCase {
    private static var review: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".review")
    }

    /// The real capture (`.review/`, git-ignored): its raw Yjs state and the
    /// server's formatted-content export, or a skip.
    private func capture() throws -> (doc: YDoc, export: String) {
        guard let state = try? Data(contentsOf: Self.review.appendingPathComponent("state.bin")),
            let formatted = try? Data(contentsOf: Self.review.appendingPathComponent("formatted.json")),
            let export = (try JSONSerialization.jsonObject(with: formatted) as? [String: Any])?["content"] as? String
        else { throw XCTSkip("no .review capture") }
        let doc = YDoc(clientID: 7, gc: true)
        try doc.applyUpdate(YUpdateDecoder.decode(state))
        return (doc, export)
    }

    private func nested(_ block: BlockNoteBlock, _ children: [BlockNoteBlock]) -> BlockNoteBlock {
        var block = block
        block.children = children
        return block
    }

    private func toggle(_ id: String, _ text: String, _ children: [BlockNoteBlock] = []) -> BlockNoteBlock {
        BlockNoteBlock(
            node: "toggleListItem", props: Self.paragraphProps, runs: [InlineRun(text)], id: id, children: children)
    }

    private func callout(_ id: String, _ text: String, emoji: String = "💡", background: String = "default")
        -> BlockNoteBlock
    {
        BlockNoteBlock(
            node: "callout",
            props: [
                ("backgroundColor", .string(background)), ("emoji", .string(emoji)), ("textAlignment", .string("left")),
            ], runs: [InlineRun(text)], id: id)
    }

    private func pageBreak(_ id: String) -> BlockNoteBlock {
        BlockNoteBlock(node: "pageBreak", props: [], runs: [], id: id)
    }

    /// Canonical blocks (`canonicalMarkdown`'s parse), compared item by item.
    private func assertCanonicalItems(
        _ shadow: String, _ export: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let lhs = parseEditorBlocks(canonicalMarkdown(shadow))
        let rhs = parseEditorBlocks(canonicalMarkdown(export))
        XCTAssertEqual(lhs.count, rhs.count, "same block count", file: file, line: line)
        for (index, (a, b)) in zip(lhs, rhs).enumerated() {
            XCTAssertEqual(a.kind, b.kind, "item \(index) kind", file: file, line: line)
            XCTAssertEqual(a.text, b.text, "item \(index) text", file: file, line: line)
            XCTAssertEqual(a.indent, b.indent, "item \(index) indent", file: file, line: line)
        }
        XCTAssertEqual(canonicalMarkdown(shadow), canonicalMarkdown(export), file: file, line: line)
    }

    /// The real capture of the test document (`.review/`, not committed): its
    /// raw Yjs state and the server's formatted-content export. The list blocks
    /// are compared: every root list block and its subtree from the state,
    /// against the export's list items. Skipped where the capture is absent.
    func testTheRealCapturesNestedListsMatchTheServerExport() throws {
        let (doc, export) = try capture()
        defer { doc.destroy() }
        let lists: Set<String> = ["bulletListItem", "numberedListItem", "checkListItem"]
        let tree = NativeBlockProjection.project(doc)
        XCTAssertTrue(tree.blocks.contains { $0.depth > 1 }, "the capture holds third-level lists")
        // Keep the root list blocks (with their subtrees); drop the rest.
        let root = try XCTUnwrap(doc.share[BlockNoteYjs.fragmentField])
        guard case .type(let group)? = YBlockProjection.children(of: root, includeFormats: false).first?.content
        else { return XCTFail("no root group") }
        let dropped = YBlockProjection.children(of: group, includeFormats: false).filter {
            !lists.contains(YBlockProjection.projectBlock($0, nestedChildren: true).node)
        }
        try doc.transact { tx in for item in dropped { item.delete(tx) } }
        let kept = NativeBlockProjection.project(doc).blocks
        XCTAssertTrue(kept.allSatisfy { lists.contains($0.block.node) }, "lists nest only lists here")
        let shadow = try XCTUnwrap(NativeBlockProjection.markdownShadow(doc))
        // The export's list items, in order, minus a toggle list item's subtree
        // (a toggle, compared in the rich-block test below).
        let texts = Set(kept.map { $0.block.runs.map(\.text).joined() })
        let exported = parseEditorBlocks(export).filter { blockIsListItem($0.kind) && texts.contains($0.text) }
        XCTAssertEqual(exported.count, kept.count, "every list item is in the export")
        XCTAssertEqual(parseEditorBlocks(shadow).map(\.indent), exported.map(\.indent), "the same nesting")
        XCTAssertEqual(canonicalMarkdown(shadow), canonicalMarkdown(serializeMarkdown(exported)))
    }

    /// The real capture up to its table: headings, marks, nested lists, a
    /// quote, a toggle with a toggle child, code, a divider, a page break and a
    /// callout. Everything from the table on (math, an interlink, a diagram,
    /// columns, media) still has no shadow, so those root blocks are dropped
    /// and the export is cut at the same place. The marks paragraph is dropped
    /// from both too: the shadow spells italic `_x_` and this export `*x*`,
    /// which `canonicalMarkdown` keeps apart (a gap of every shadow, flat ones
    /// included, not of these blocks). The rest matches item by item after
    /// `canonicalMarkdown`.
    func testTheRealCapturesRichBlocksMatchTheServerExport() throws {
        let (doc, export) = try capture()
        defer { doc.destroy() }
        XCTAssertNil(NativeBlockProjection.markdownShadow(doc), "the whole capture still gates (table, media)")
        let root = try XCTUnwrap(doc.share[BlockNoteYjs.fragmentField])
        guard case .type(let group)? = YBlockProjection.children(of: root, includeFormats: false).first?.content
        else { return XCTFail("no root group") }
        let items = YBlockProjection.children(of: group, includeFormats: false)
        let nodes = items.map { YBlockProjection.projectBlock($0, nestedChildren: true).node }
        let table = try XCTUnwrap(nodes.firstIndex(of: "table"))
        for node in ["toggleListItem", "pageBreak", "callout"] {
            XCTAssertTrue(nodes[..<table].contains(node), "the kept section holds a \(node)")
        }
        let marks = try XCTUnwrap(
            items.firstIndex {
                YBlockProjection.projectBlock($0).runs.contains { $0.marks.contains { $0.key == "italic" } }
            })
        try doc.transact { tx in for item in [items[marks]] + items[table...] { item.delete(tx) } }
        let shadow = try XCTUnwrap(NativeBlockProjection.markdownShadow(doc))
        let marksLine = "A paragraph with **bold**, *italic*, underline, ~~strike~~ and `inline code` marks.\n\n"
        XCTAssertTrue(export.contains(marksLine))
        let section = try XCTUnwrap(
            export.replacingOccurrences(of: marksLine, with: "").components(separatedBy: "\n| ").first)
        XCTAssertTrue(section.hasSuffix("👍 A callout with an emoji and a background colour.\n"))
        assertCanonicalItems(shadow, section)
    }

    /// The export's spelling of the native-only blocks, copied from the real
    /// capture's formatted content: a toggle list item (with a toggle child) is
    /// a bullet, a page break is nothing at all, and a callout is a paragraph
    /// with its emoji in front (its background is dropped). The toggle heading
    /// is not in the capture; its spelling is the installed BlockNote 0.56
    /// `blocksToMarkdownLossy` (a plain heading, children flat).
    func testRichBlockSpellingMatchesTheServerExport() throws {
        let doc = try makeDoc(
            [
                toggle("t", "Toggle list item", [toggle("tc", "Child inside the toggle")]),
                BlockNoteBlock(node: "divider", props: [], runs: [], id: "d"), pageBreak("pb"),
                callout("c", "A callout with an emoji and a background colour.", emoji: "👍", background: "yellow"),
                nested(heading("h", "Toggle heading", toggle: true), [paragraph("hc", "Child under heading")]),
            ], clientID: 1)
        defer { doc.destroy() }
        let export = """
            * Toggle list item
              * Child inside the toggle

            ***

            👍 A callout with an emoji and a background colour.

            ## Toggle heading

            Child under heading

            """
        // Classic callers are unchanged: these blocks stay opaque, with no shadow.
        let classic = YBlockProjection.project(doc)
        XCTAssertEqual(classic.blocks.filter(\.fidelity.isOpaque).map(\.id), ["t", "pb", "c", "h"])
        XCTAssertNil(YBlockProjection.projectedMarkdown(classic))
        let shadow = try XCTUnwrap(NativeBlockProjection.markdownShadow(doc))
        assertCanonicalItems(shadow, export)
        XCTAssertEqual(
            shadow,
            "- Toggle list item\n  - Child inside the toggle\n\n---\n\n👍 A callout with an emoji and a background colour."
                + "\n\n## Toggle heading\n\nChild under heading\n")
        // An empty toggle (a fresh slash-menu toggle) exports as an empty bullet
        // (installed BlockNote 0.56 `blocksToMarkdownLossy`).
        let empty = try makeDoc(
            [
                BlockNoteBlock(node: "toggleListItem", props: Self.paragraphProps, runs: [], id: "e"),
                paragraph("x", "x"),
            ], clientID: 1)
        defer { empty.destroy() }
        assertCanonicalItems(try XCTUnwrap(NativeBlockProjection.markdownShadow(empty)), "* \n\nx\n")
    }

    /// A callout without an emoji still has no shadow: the export's spelling
    /// of one is unknown, and the native editor never writes one.
    func testACalloutWithoutAnEmojiHasNoShadow() throws {
        let doc = try makeDoc([callout("c", "Note", emoji: "")], clientID: 1)
        defer { doc.destroy() }
        XCTAssertNil(NativeBlockProjection.markdownShadow(doc))
    }

    /// A callout is Schrift's own block, not core BlockNote's, so how the
    /// server exports one with children or inside a toggle is unknown: those
    /// shapes have no shadow, as before PR06c.
    func testACalloutWithChildrenOrInsideAToggleHasNoShadow() throws {
        let shapes: [[BlockNoteBlock]] = [
            [nested(callout("c", "Note"), [paragraph("k", "Kid")])],
            [toggle("t", "Title", [callout("c", "Note")])],
            [toggle("t", "Title", [paragraph("p", "Child"), callout("c", "Note")])],
        ]
        for blocks in shapes {
            let doc = try makeDoc(blocks, clientID: 1)
            defer { doc.destroy() }
            XCTAssertNil(NativeBlockProjection.markdownShadow(doc), "\(blocks.map(\.id))")
        }
    }

    /// Links in a toggle's continuation paragraph, each with the installed
    /// BlockNote 0.56 `blocksToMarkdownLossy` output (labs/schrift-spikes/s3,
    /// `toggleListItem "T"` holding a paragraph `"x "` + the link). Every text
    /// node is its own innermost `<a>` inside its marks, so a link split by a
    /// mark is two links; `formatLink` writes the bare URL only for a label
    /// equal to a URL that is not `http(s)://`/`www.` or that
    /// `parseAutolinkLiteral` reads back whole, else `[label](escaped)`.
    func testLinksTakeTheExportersSpelling() throws {
        func link(_ text: String, _ href: String, _ marks: [String] = []) -> InlineRun {
            let value = String(data: try! JSONSerialization.data(withJSONObject: ["href": href]), encoding: .utf8)!
            return InlineRun(text, marks: marks.map { ($0, "{}") } + [("link", value)])
        }
        let shapes: [(name: String, runs: [InlineRun], export: String)] = [
            (
                "a link split by bold",
                [link("a", "https://example.com/x"), link("b", "https://example.com/x", ["bold"])],
                "* T\n\n  x [a](https://example.com/x)**[b](https://example.com/x)**\n"
            ),
            (
                "the same link, two styles",
                [
                    link("a", "https://example.com/s", ["bold"]),
                    link("b", "https://example.com/s", ["bold", "italic"]),
                ],
                "* T\n\n  x **[a](https://example.com/s)*****[b](https://example.com/s)***\n"
            ),
            (
                "marks outside the link", [link("i", "https://example.com/i", ["italic", "strike"])],
                "* T\n\n  x *~~[i](https://example.com/i)~~*\n"
            ),
            (
                "trailing space inside a bold link", [link("t ", "https://example.com/t", ["bold"])],
                "* T\n\n  x **[t ](https://example.com/t)**\n"
            ),
            ("code drops the link", [link("c", "https://example.com/c", ["code"])], "* T\n\n  x `c`\n"),
            ("a relative path", [link("/docs/page", "/docs/page")], "* T\n\n  x /docs/page\n"),
            ("a bare domain", [link("example.com", "example.com")], "* T\n\n  x example.com\n"),
            ("mailto", [link("mailto:a@example.com", "mailto:a@example.com")], "* T\n\n  x mailto:a@example.com\n"),
            (
                "an https URL that reads back whole",
                [link("https://example.com/path", "https://example.com/path")], "* T\n\n  x https://example.com/path\n"
            ),
            (
                "an unbalanced paren reads back whole",
                [link("https://example.com/(a)", "https://example.com/(a)")], "* T\n\n  x https://example.com/(a)\n"
            ),
            (
                "an https URL whose trailing dot the autolink drops",
                [link("https://example.com/a.", "https://example.com/a.")],
                "* T\n\n  x [https://example.com/a.](https://example.com/a.)\n"
            ),
            (
                "an https URL whose closing paren the autolink drops, escaped",
                [link("https://example.com/a)", "https://example.com/a)")],
                "* T\n\n  x [https://example.com/a)](https://example.com/a\\))\n"
            ),
            (
                "an entity suffix", [link("https://example.com/a&amp;", "https://example.com/a&amp;")],
                "* T\n\n  x [https://example.com/a&amp;](https://example.com/a&amp;)\n"
            ),
            (
                "an upper-case scheme", [link("HTTPS://example.com/u", "HTTPS://example.com/u")],
                "* T\n\n  x [HTTPS://example.com/u](HTTPS://example.com/u)\n"
            ),
            (
                "www", [link("www.example.com", "www.example.com")],
                "* T\n\n  x [www.example.com](www.example.com)\n"
            ),
            (
                "a label, escaped", [link("label", "https://example.com/(x)")],
                "* T\n\n  x [label](https://example.com/\\(x\\))\n"
            ),
        ]
        for shape in shapes {
            let child = BlockNoteBlock(
                node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("x ")] + shape.runs, id: "p")
            let doc = try makeDoc([toggle("t", "T", [child])], clientID: 1)
            defer { doc.destroy() }
            let tree = NativeBlockProjection.project(doc, nativeMarks: false).blocks
            XCTAssertEqual(
                NativeExportMarkdown.markdown(NativeExportMarkdown.nodes(tree[...])), shape.export, shape.name)
            assertCanonicalItems(try XCTUnwrap(NativeBlockProjection.markdownShadow(doc), shape.name), shape.export)
        }
    }

    /// Toggle subtrees the classic rendering cannot spell, each with the
    /// installed BlockNote 0.56 `blocksToMarkdownLossy` output for the same
    /// blocks (generated in labs/schrift-spikes/s3 with `withPageBreak`): a
    /// toggle's non-list children are indented continuation paragraphs ahead of
    /// its leading list children, a plain block's children flatten after it.
    /// `NativeExportMarkdown` reproduces each byte for byte, and the shadow
    /// matches each after `canonicalMarkdown`.
    func testToggleSubtreesTakeTheExportersSpelling() throws {
        func numbered(_ id: String, _ text: String) -> BlockNoteBlock {
            BlockNoteBlock(node: "numberedListItem", props: Self.paragraphProps, runs: [InlineRun(text)], id: id)
        }
        let quote = BlockNoteBlock(
            node: "quote", props: [("backgroundColor", .string("default")), ("textColor", .string("default"))],
            runs: [InlineRun("Quote")], id: "q")
        let code = BlockNoteBlock(
            node: "codeBlock", props: [("language", .string("swift"))], runs: [InlineRun("let x = 1\nlet y = 2")],
            id: "code")
        let check = BlockNoteBlock(
            node: "checkListItem", props: Self.paragraphProps + [("checked", .bool(true))], runs: [InlineRun("Done")],
            id: "done")
        let marks = BlockNoteBlock(
            node: "paragraph", props: Self.paragraphProps,
            runs: [
                InlineRun("Bold", marks: [("bold", "{}")]), InlineRun(" and "),
                InlineRun("link", marks: [("link", #"{"href":"https://example.com/a(b)"}"#)]), InlineRun(" and "),
                InlineRun("code", marks: [("code", "{}")]),
            ], id: "m")
        let shapes: [(name: String, blocks: [BlockNoteBlock], export: String)] = [
            (
                "paragraph then list", [toggle("t", "Title", [paragraph("c", "Child"), bullet("s", "Sub")])],
                "* Title\n\n  Child\n  * Sub\n"
            ),
            (
                "list then paragraph", [toggle("t", "Title", [bullet("s", "Sub"), paragraph("c", "Child")])],
                "* Title\n\n  Child\n  * Sub\n"
            ),
            (
                "Return in an open toggle", [toggle("t", "Title", [paragraph("c", "")]), paragraph("a", "After")],
                "* Title\n\n  \n\nAfter\n"
            ),
            (
                "paragraphs around a list",
                [toggle("t", "Title", [paragraph("o", "One"), bullet("s", "Sub"), paragraph("w", "Two")])],
                "* Title\n\n  One\n  * Sub\n\n  Two\n"
            ),
            (
                "lists around a paragraph",
                [toggle("t", "Title", [bullet("f", "First"), paragraph("m", "Middle"), numbered("n", "Second")])],
                "* Title\n\n  Middle\n  1. Second\n  * First\n"
            ),
            (
                "nested toggles",
                [
                    toggle(
                        "o", "Outer", [toggle("i", "Inner", [paragraph("d", "Deep")]), paragraph("c", "Outer child")]),
                    paragraph("a", "After"),
                ],
                "* Outer\n\n  Outer child\n  * Inner\n\n    Deep\n\nAfter\n"
            ),
            (
                "toggle in a numbered item",
                [
                    nested(numbered("s", "Step"), [toggle("t", "Toggle", [paragraph("d", "Detail")])]),
                    numbered("n", "Next"),
                ],
                "1. Step\n   * Toggle\n\n     Detail\n2. Next\n"
            ),
            (
                "toggle between bullets",
                [bullet("b", "Before"), toggle("t", "Toggle", [paragraph("d", "Detail")]), bullet("a", "After")],
                "* Before\n* Toggle\n\n  Detail\n* After\n"
            ),
            (
                "mixed blocks",
                [
                    toggle(
                        "t", "Title",
                        [
                            heading("h", "Heading"), quote, code,
                            BlockNoteBlock(node: "divider", props: [], runs: [], id: "d"),
                            pageBreak("pb"), check, paragraph("e", "End"),
                        ])
                ],
                "* Title\n  ## Heading\n\n  > Quote\n\n  ```swift\n  let x = 1\n  let y = 2\n  ```\n\n  ***\n\n  * [x] Done\n\n  End\n"
            ),
            (
                "toggle heading holding a toggle",
                [
                    nested(
                        heading("h", "Section", toggle: true),
                        [toggle("t", "Toggle", [paragraph("d", "Detail")]), paragraph("p", "Plain")])
                ],
                "## Section\n\n* Toggle\n\n  Detail\n\nPlain\n"
            ),
            (
                "toggle heading inside a toggle",
                [
                    toggle(
                        "t", "Title",
                        [
                            nested(heading("h", "Inner heading", toggle: true), [paragraph("u", "Under")]),
                            paragraph("a", "After"),
                        ])
                ],
                "* Title\n  ## Inner heading\n\nUnder\n  After\n"
            ),
            (
                "inline marks", [toggle("t", "Title", [marks])],
                "* Title\n\n  **Bold** and [link](https://example.com/a\\(b\\)) and `code`\n"
            ),
            (
                "bullet with a paragraph and a toggle",
                [
                    nested(
                        bullet("b", "Bullet"),
                        [paragraph("f", "Flat"), toggle("t", "Toggle", [paragraph("d", "Detail")])])
                ],
                "* Bullet\n\nFlat\n\n* Toggle\n\n  Detail\n"
            ),
        ]
        for shape in shapes {
            let doc = try makeDoc(shape.blocks, clientID: 1)
            defer { doc.destroy() }
            let tree = NativeBlockProjection.project(doc, nativeMarks: false).blocks
            XCTAssertEqual(
                NativeExportMarkdown.markdown(NativeExportMarkdown.nodes(tree[...])), shape.export, shape.name)
            let shadow = try XCTUnwrap(NativeBlockProjection.markdownShadow(doc), shape.name)
            assertCanonicalItems(shadow, shape.export)
        }
    }

    /// A document whose only non-flat blocks are a callout, toggles, a page
    /// break and a nested list is typeable in the production route, a toggle
    /// with a paragraph child included.
    func testRichBlocksAreTypeable() throws {
        let harness = try makeHarness(richSeed())
        defer { harness.close() }
        XCTAssertTrue(harness.session.canType)
        let paragraphChild = try makeHarness([toggle("t", "Title", [paragraph("c", "Child")])])
        defer { paragraphChild.close() }
        XCTAssertTrue(paragraphChild.session.canType)
    }

    /// Return in an open toggle makes its first child a paragraph: the
    /// document stays typeable after a relaunch, and the save of what was
    /// typed there is the export's spelling, so no conflict.
    func testReturnInAnOpenToggleStaysTypeableAndSavesWithoutAConflict() throws {
        let harness = try makeHarness([paragraph("p", "Intro"), toggle("t", "Title")])
        defer { harness.close() }
        let session = harness.session
        session.surface.setExpanded("t", true)
        setSelection(harness, NSRange(location: try location(session, "t", 5), length: 0))
        session.textView.insertText("\n")
        let child = try XCTUnwrap(session.surface.blocks.last)
        XCTAssertEqual(child.parentID, "t")
        XCTAssertEqual(child.node, "paragraph")
        let adapter = ReplicaSaveAdapter(store: harness.store, scope: harness.scope)
        XCTAssertNoThrow(try adapter.prepare(), "an empty child still has a shadow")
        session.textView.insertText("Detail")
        try assertConsistent(harness, localCommands: 2)
        let (_, markdown) = try adapter.prepare()
        let export = "Intro\n\n* Title\n\n  Detail\n"  // BlockNote 0.56 `blocksToMarkdownLossy`
        assertCanonicalItems(markdown, export)
        let decision = draftSyncDecision(
            baseline: DraftBaseline(
                serverUpdatedAt: Date(timeIntervalSince1970: 1_000), markdown: "Intro\n", title: "Doc"),
            lastPushedMarkdown: markdown, localMarkdown: markdown + "\nTyped after the save\n", draftTitle: "Doc",
            draftUpdatedAt: Date(timeIntervalSince1970: 2_000), serverTitle: "Doc",
            serverUpdatedAt: Date(timeIntervalSince1970: 3_000), serverMarkdown: export)
        XCTAssertEqual(decision, .push(title: "Doc", evidence: .serverHoldsOurLastPush))

        session.close()
        let restored = try XCTUnwrap(NativeEditorSession.restore(store: harness.store, scope: harness.scope))
        defer { restored.close() }
        XCTAssertTrue(restored.canType, "a toggle with a paragraph child stays typeable")
    }

    /// Typing in such a document and saving: the save's shadow is what the
    /// server exports for the saved body, so `draftSyncDecision` sees our own
    /// last push, not a conflict, after the save bumped `updated_at`.
    func testASavedRichDocumentIsNotAConflict() throws {
        let harness = try makeHarness(richSeed())
        defer { harness.close() }
        let session = harness.session
        XCTAssertTrue(session.canType)
        setSelection(harness, NSRange(location: try location(session, "c", 0), length: 0))
        session.textView.insertText("New ")
        setSelection(harness, NSRange(location: try location(session, "t", 0), length: 0))
        session.textView.insertText("Open ")
        try assertConsistent(harness, localCommands: 2)
        let (_, markdown) = try ReplicaSaveAdapter(store: harness.store, scope: harness.scope).prepare()
        let baseline = DraftBaseline(
            serverUpdatedAt: Date(timeIntervalSince1970: 1_000), markdown: "Intro\n", title: "Doc")
        let export = """
            Intro

            * Open Toggle list item
              * Child inside the toggle
            * Bullet
              * Nested bullet

            💡 New Remember this

            ## Toggle heading

            Child under heading

            """
        let decision = draftSyncDecision(
            baseline: baseline, lastPushedMarkdown: markdown, localMarkdown: markdown + "\nTyped after the save\n",
            draftTitle: "Doc", draftUpdatedAt: Date(timeIntervalSince1970: 2_000), serverTitle: "Doc",
            serverUpdatedAt: Date(timeIntervalSince1970: 3_000), serverMarkdown: export)
        XCTAssertEqual(decision, .push(title: "Doc", evidence: .serverHoldsOurLastPush))
        assertCanonicalItems(markdown, export)
    }

    private func richSeed() -> [BlockNoteBlock] {
        [
            paragraph("p", "Intro"),
            toggle("t", "Toggle list item", [toggle("tc", "Child inside the toggle")]),
            nested(bullet("b", "Bullet"), [bullet("bn", "Nested bullet")]),
            pageBreak("pb"),
            callout("c", "Remember this"),
            nested(heading("h", "Toggle heading", toggle: true), [paragraph("hc", "Child under heading")]),
        ]
    }

    /// The export's own nested-list spelling (copied from that capture's
    /// formatted content) against blocks of the same shape.
    func testNestedListSpellingMatchesTheServerExport() throws {
        func item(_ node: String, _ id: String, _ text: String, _ children: [BlockNoteBlock] = []) -> BlockNoteBlock {
            let extra: [(key: String, value: YAnyValue)] =
                node == "checkListItem"
                ? [("checked", .bool(text.hasPrefix("Checked")))]
                : node == "numberedListItem" ? [("start", .undefined)] : []
            return BlockNoteBlock(
                node: node, props: Self.paragraphProps + extra, runs: [InlineRun(text)], id: id, children: children)
        }
        let doc = try makeDoc(
            [
                item(
                    "bulletListItem", "b1", "Bullet item",
                    [
                        item(
                            "bulletListItem", "b2", "Nested bullet",
                            [item("bulletListItem", "b3", "Third-level bullet")])
                    ]),
                item(
                    "numberedListItem", "n1", "Numbered item",
                    [
                        item(
                            "numberedListItem", "n2", "Nested numbered",
                            [item("numberedListItem", "n3", "Third-level numbered")])
                    ]),
                item("numberedListItem", "n4", "Item two"),
                item(
                    "checkListItem", "c1", "Unchecked task",
                    [item("checkListItem", "c2", "Nested task", [item("checkListItem", "c3", "Third-level task")])]),
                item("checkListItem", "c4", "Checked task"),
            ], clientID: 1)
        defer { doc.destroy() }
        let export = """
            * Bullet item
              * Nested bullet
                * Third-level bullet

            1. Numbered item
               1. Nested numbered
                  1. Third-level numbered
            2. Item two

            * [ ] Unchecked task
              * [ ] Nested task
                * [ ] Third-level task
            * [x] Checked task

            """
        let shadow = try XCTUnwrap(NativeBlockProjection.markdownShadow(doc))
        XCTAssertEqual(canonicalMarkdown(shadow), canonicalMarkdown(export))
        XCTAssertEqual(parseEditorBlocks(shadow).map(\.indent), [0, 1, 2, 0, 1, 2, 0, 0, 1, 2, 0])
    }
}
