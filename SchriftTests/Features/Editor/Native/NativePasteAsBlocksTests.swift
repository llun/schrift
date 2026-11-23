import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import Schrift

/// Coordinator-level paste-as-blocks tests: web HTML, Markdown plain text,
/// plain-text non-regression, mid-paragraph/selection slice merge, headings/
/// list items, single table cells, code blocks, source editors, Paste and Match
/// Style (edit menu + ⌘⇧V), internal payload priority, oversized HTML notice/
/// fallback, and single-step undo.
@MainActor
final class NativePasteAsBlocksTests: NativeEditingTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows { window.isHidden = true }
        windows = []
        try await super.tearDown()
    }

    private func caret(_ harness: Harness, _ id: String, _ offset: Int) throws {
        setSelection(harness, NSRange(location: try location(harness.session, id, offset), length: 0))
    }

    private func heading(_ id: String, level: Int, _ text: String) -> BlockNoteBlock {
        BlockNoteBlock(
            node: "heading",
            props: Self.paragraphProps + [("level", .int(level)), ("isToggleable", .bool(false))],
            runs: text.isEmpty ? [] : [InlineRun(text)], id: id)
    }

    private func codeBlock(_ id: String, language: String = "swift", _ text: String) -> BlockNoteBlock {
        BlockNoteBlock(
            node: "codeBlock", props: [("language", .string(language))],
            runs: text.isEmpty ? [] : [InlineRun(text)], id: id)
    }

    private final class RecordingProtocol: URLProtocol {
        nonisolated(unsafe) static var requests: [URL] = []
        override class func canInit(with request: URLRequest) -> Bool {
            if let url = request.url { requests.append(url) }
            return false
        }
    }

    private func hostWindow(_ root: UIViewController) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window =
            scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.view.layoutIfNeeded()
        windows.append(window)
        return window
    }

    private func openTable(_ seed: String = "grid") async throws -> (Harness, TableEditorViewController) {
        let data = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(BlockNoteTableClipboardCaptures.seeds[seed])))
        let harness = try await makeHarness(state: data)
        addTeardownBlock { await harness.close() }
        let editor = TableEditorViewController(document: harness.session, tableID: "tbl")
        _ = hostWindow(UINavigationController(rootViewController: editor))
        editor.loadViewIfNeeded()
        await editor.load()
        await waitUntil { editor.isLoaded }
        XCTAssertTrue(editor.isLoaded)
        if let session = editor.cellSession { addTeardownBlock { await session.close().value } }
        return (harness, editor)
    }

    // MARK: - 1. HTML from a web page -> blocks (no image download)

    func testWebHTMLPastesAsBlocksAndNeverDownloadsImages() async throws {
        let harness = try await makeHarness([paragraph("empty", "")])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try caret(harness, "empty", 0)

        RecordingProtocol.requests = []
        URLProtocol.registerClass(RecordingProtocol.self)
        defer { URLProtocol.unregisterClass(RecordingProtocol.self) }

        let html = """
            <script>alert(1)</script><style>.x{color:red}</style>
            <h1>Article Title</h1>
            <p>Read <strong>bold</strong> and <a href="https://example.com/post">link</a>.</p>
            <ul><li>First item</li><li>Second item</li></ul>
            <img src="https://images.example/photo.png" alt="Sunset">
            <img src="http://insecure.example/skip.png" alt="Dropped">
            """
        harness.pasteboard.setItems([
            [
                TableClipboard.htmlType: Data(html.utf8),
                UTType.utf8PlainText.identifier: "Article Title\nRead bold and link.",
            ]
        ])

        harness.view.paste(nil)
        await harness.settle()

        XCTAssertEqual(
            session.surface.blocks.map(\.node),
            ["heading", "paragraph", "bulletListItem", "bulletListItem", "image"])
        XCTAssertEqual(text(of: session.surface.blocks[0]), "Article Title")
        XCTAssertEqual(session.surface.blocks[0].props.first { $0.key == "level" }?.value, .int(1))
        XCTAssertEqual(text(of: session.surface.blocks[1]), "Read bold and link.")
        XCTAssertEqual(
            session.surface.blocks[1].runs.first { $0.text == "bold" }?.marks.map(\.key), ["bold"])
        XCTAssertEqual(
            session.surface.blocks[1].runs.first { $0.text == "link" }?.marks.map(\.key), ["link"])
        XCTAssertEqual(text(of: session.surface.blocks[2]), "First item")
        XCTAssertEqual(text(of: session.surface.blocks[3]), "Second item")
        XCTAssertEqual(
            session.surface.blocks[4].props.first { $0.key == "url" }?.value,
            .string("https://images.example/photo.png"))
        XCTAssertEqual(
            session.surface.blocks[4].props.first { $0.key == "name" }?.value,
            .string("Sunset"))
        harness.view.layoutIfNeeded()
        XCTAssertEqual(RecordingProtocol.requests, [], "https images never download on paste")
        try await assertConsistent(harness, localCommands: 1)

        // One undo restores the empty paragraph.
        let undone = await harness.run { harness.input.undo() }
        XCTAssertTrue(undone)
        XCTAssertEqual(session.surface.blocks.map(\.node), ["paragraph"])
        XCTAssertEqual(texts(session), [""])
        try await assertConsistent(harness, localCommands: 2)
    }

    // MARK: - 2. Markdown plain text -> blocks

    func testMarkdownPlainTextPastesAsBlocksAndUndoesInOneStep() async throws {
        let harness = try await makeHarness([paragraph("empty", "")])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try caret(harness, "empty", 0)

        harness.pasteboard.string = """
            ## Overview
            A **strong** and *italic* note with `code`
            - Bullet one
            - Bullet two
            > Quoted line
            ```swift
            let x = 1
            ```
            """
        harness.view.paste(nil)
        await harness.settle()

        XCTAssertEqual(
            session.surface.blocks.map(\.node),
            ["heading", "paragraph", "bulletListItem", "bulletListItem", "quote", "codeBlock"])
        XCTAssertEqual(text(of: session.surface.blocks[0]), "Overview")
        XCTAssertEqual(session.surface.blocks[0].props.first { $0.key == "level" }?.value, .int(2))
        XCTAssertEqual(text(of: session.surface.blocks[1]), "A strong and italic note with code")
        XCTAssertEqual(
            session.surface.blocks[1].runs.filter { !$0.marks.isEmpty }.map { ($0.text, $0.marks.map(\.key)) }
                .map { "\($0.0):\($0.1.joined(separator: ","))" },
            ["strong:bold", "italic:italic", "code:code"])
        XCTAssertEqual(text(of: session.surface.blocks[2]), "Bullet one")
        XCTAssertEqual(text(of: session.surface.blocks[3]), "Bullet two")
        XCTAssertEqual(text(of: session.surface.blocks[4]), "Quoted line")
        XCTAssertEqual(text(of: session.surface.blocks[5]), "let x = 1")
        XCTAssertEqual(session.surface.blocks[5].props.first { $0.key == "language" }?.value, .string("swift"))
        try await assertConsistent(harness, localCommands: 1)

        // One undo restores the original empty paragraph.
        let undone = await harness.run { harness.input.undo() }
        XCTAssertTrue(undone)
        XCTAssertEqual(session.surface.blocks.map(\.node), ["paragraph"])
        XCTAssertEqual(texts(session), [""])
        try await assertConsistent(harness, localCommands: 2)
    }

    // MARK: - 3. Plain text without Markdown -> unchanged plain path

    func testPlainTextWithoutMarkdownKeepsExistingReplaceAndRangePaths() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try caret(harness, Self.firstID, 5)

        // Single-line plain text (including arithmetic stars and underscores) uses fast `.replace`.
        harness.pasteboard.string = " 2*3*4 snake_case"
        harness.view.paste(nil)
        await harness.settle()
        XCTAssertEqual(texts(session)[0], "First 2*3*4 snake_case paragraph.")
        XCTAssertEqual(harness.log.commands.last?.kind, .replace(range: 5..<5, replacement: " 2*3*4 snake_case"))
        try await assertConsistent(harness, localCommands: 1)

        // Multi-line plain text without Markdown uses `.range` with one paragraph per line break.
        try caret(harness, Self.thirdID, 5)
        harness.pasteboard.string = "line one\n\nline two"
        harness.view.paste(nil)
        await harness.settle()
        guard case .range(let range)? = harness.log.commands.last?.kind else {
            return XCTFail("expected .range command for multi-line plain text")
        }
        XCTAssertEqual(range.replacement, "line one\n\nline two")
        XCTAssertEqual(texts(session).suffix(3), ["Thirdline one", "", "line two paragraph."])
        try await assertConsistent(harness, localCommands: 2)
    }

    // MARK: - 4 & 5. Mid-paragraph HTML merge & paste over selection

    func testMidParagraphHTMLPasteMergesAndSelectionPasteReplacesAndUndoesInOneStep() async throws {
        let harness = try await makeHarness([
            paragraph("p1", "Hello world"),
            paragraph("p2", "Middle block"),
            paragraph("p3", "alpha omega"),
        ])
        addTeardownBlock { await harness.close() }
        let session = harness.session

        // Mid-paragraph HTML paste merges prefix into first pasted block and suffix into last.
        try caret(harness, "p1", 6)
        harness.pasteboard.setItems([
            [
                TableClipboard.htmlType: Data("<h1><strong>Big</strong></h1><p>End </p>".utf8),
                UTType.utf8PlainText.identifier: "Big\nEnd ",
            ]
        ])
        harness.view.paste(nil)
        await harness.settle()
        XCTAssertEqual(texts(session).prefix(2), ["Hello Big", "Endworld"])
        XCTAssertEqual(session.surface.blocks[0].id, "p1")
        XCTAssertEqual(session.surface.blocks[0].node, "paragraph")
        XCTAssertEqual(session.surface.blocks[0].runs.last?.marks.map(\.key), ["bold"])
        try await assertConsistent(harness, localCommands: 1)

        // One undo restores the original paragraph.
        let undoneMid = await harness.run { harness.input.undo() }
        XCTAssertTrue(undoneMid)
        XCTAssertEqual(texts(session), ["Hello world", "Middle block", "alpha omega"])
        try await assertConsistent(harness, localCommands: 2)

        // Paste Markdown over a multi-block selection replaces the selection in one command.
        try select(harness, from: ("p1", 6), to: ("p3", 6))
        harness.pasteboard.string = "ONE\n- TWO\nTHREE "
        harness.view.paste(nil)
        await harness.settle()
        XCTAssertEqual(session.surface.blocks.map(\.node), ["paragraph", "bulletListItem", "paragraph"])
        XCTAssertEqual(texts(session), ["Hello ONE", "TWO", "THREE omega"])
        try await assertConsistent(harness, localCommands: 3)

        let undoneSel = await harness.run { harness.input.undo() }
        XCTAssertTrue(undoneSel)
        XCTAssertEqual(texts(session), ["Hello world", "Middle block", "alpha omega"])
        try await assertConsistent(harness, localCommands: 4)
    }

    // MARK: - 6. Paste into a heading and a list item

    func testPasteIntoHeadingAndListItemPreservesTargetTypeAndProps() async throws {
        let harness = try await makeHarness([heading("h2", level: 2, "Chapter End"), bullet("b1", "")])
        addTeardownBlock { await harness.close() }
        let session = harness.session

        try caret(harness, "h2", 8)
        harness.pasteboard.setItems([
            [
                TableClipboard.htmlType: Data("<p><strong>One</strong></p><p>Two </p>".utf8),
                UTType.utf8PlainText.identifier: "One\nTwo ",
            ]
        ])
        harness.view.paste(nil)
        await harness.settle()

        XCTAssertEqual(session.surface.blocks[0].id, "h2")
        XCTAssertEqual(session.surface.blocks[0].node, "heading")
        XCTAssertEqual(session.surface.blocks[0].props.first { $0.key == "level" }?.value, .int(2))
        XCTAssertEqual(text(of: session.surface.blocks[0]), "Chapter One")
        XCTAssertEqual(session.surface.blocks[1].node, "paragraph")
        XCTAssertEqual(text(of: session.surface.blocks[1]), "TwoEnd")

        // Pasting Markdown into an empty bullet keeps it a bulletListItem.
        try caret(harness, "b1", 0)
        harness.pasteboard.string = "**Bold item**"
        harness.view.paste(nil)
        await harness.settle()
        let b1 = try block(session, "b1")
        XCTAssertEqual(b1.node, "bulletListItem")
        XCTAssertEqual(text(of: b1), "Bold item")
        XCTAssertEqual(b1.runs.first?.marks.map(\.key), ["bold"])
        try await assertConsistent(harness, localCommands: 2)
    }

    // MARK: - 7. Single table cell gets flattened inline formatting + hard breaks

    func testSingleTableCellGetsInlineFormattingAndHardBreaksAndPreservesTableBehavior() async throws {
        let (harness, editor) = try await openTable()
        let table = try XCTUnwrap(editor.cellSession)
        let ref = TableGrid.CellRef(row: 2, index: 2)  // empty cell
        editor.activate(ref, caret: .start)

        // HTML paste at a collapsed caret in a single cell flattens to inline marks + hard breaks.
        harness.pasteboard.setItems([
            [
                TableClipboard.htmlType: Data("<p><strong>Bold</strong> line</p><ul><li>Item</li></ul>".utf8),
                UTType.utf8PlainText.identifier: "Bold line\nItem",
            ]
        ])
        let pastedHTML = await table.run {
            table.textView.paste(nil)
            return true
        }
        XCTAssertTrue(pastedHTML)
        let cellAfterHTML = await harness.engine { $0.tableGrid("tbl")?.rows[2][2].runs }
        XCTAssertEqual(cellAfterHTML?.map(\.text).joined(), "Bold line\nItem")
        XCTAssertEqual(cellAfterHTML?.first?.text, "Bold")
        XCTAssertEqual(cellAfterHTML?.first?.marks.map(\.key), ["bold"])

        // One undo restores the empty cell.
        let undoneCell = await table.run { table.input?.undo() ?? false }
        XCTAssertTrue(undoneCell)
        let cellAfterUndo = await harness.engine { $0.tableGrid("tbl")?.rows[2][2].runs.map(\.text).joined() }
        XCTAssertEqual(cellAfterUndo, "")

        // Markdown paste at a collapsed caret in a single cell flattens to inline marks + hard breaks.
        editor.activate(ref, caret: .start)
        harness.pasteboard.string = "**Strong** and *em*\n- Bullet"
        let pastedMD = await table.run {
            table.textView.paste(nil)
            return true
        }
        XCTAssertTrue(pastedMD)
        let cellAfterMD = await harness.engine { $0.tableGrid("tbl")?.rows[2][2].runs }
        XCTAssertEqual(cellAfterMD?.map(\.text).joined(), "Strong and em\nBullet")
        XCTAssertEqual(cellAfterMD?.first { $0.text == "Strong" }?.marks.map(\.key), ["bold"])
        XCTAssertEqual(cellAfterMD?.first { $0.text == "em" }?.marks.map(\.key), ["italic"])

        // Paste and Match Style in a single cell pastes literal plain text (skipping HTML/Markdown).
        let undoneMD = await table.run { table.input?.undo() ?? false }
        XCTAssertTrue(undoneMD)
        editor.activate(ref, caret: .start)
        harness.pasteboard.setItems([
            [
                TableClipboard.htmlType: Data("<p><strong>Rich</strong></p>".utf8),
                UTType.utf8PlainText.identifier: "**literal**",
            ]
        ])
        let pastedPlain = await table.run {
            table.textView.pasteAndMatchStyle(nil)
            return true
        }
        XCTAssertTrue(pastedPlain)
        let cellAfterPlain = await harness.engine { $0.tableGrid("tbl")?.rows[2][2].runs }
        XCTAssertEqual(cellAfterPlain?.map(\.text).joined(), "**literal**")
        XCTAssertTrue(cellAfterPlain?.allSatisfy(\.marks.isEmpty) == true)

        // Multi-cell CellSelection with Paste and Match Style skips HTML tables and fills cells with plain text.
        editor.select(.init(anchor: TableSlot(row: 1, column: 1), head: TableSlot(row: 2, column: 2)))
        harness.pasteboard.setItems([
            [
                TableClipboard.htmlType: Data("<table><tr><td>X</td><td>Y</td></tr></table>".utf8),
                UTType.utf8PlainText.identifier: "plain",
            ]
        ])
        let filledPlain = await table.run {
            table.textView.pasteAndMatchStyle(nil)
            return true
        }
        XCTAssertTrue(filledPlain)
        let r1c1 = await harness.engine { $0.tableGrid("tbl")?.rows[1][1].runs.map(\.text).joined() }
        let r2c2 = await harness.engine { $0.tableGrid("tbl")?.rows[2][2].runs.map(\.text).joined() }
        XCTAssertEqual(r1c1, "plain")
        XCTAssertEqual(r2c2, "plain")
    }

    // MARK: - 8. Code block stays literal plain text

    func testCodeBlockStaysLiteralForHTMLAndMarkdown() async throws {
        let harness = try await makeHarness([codeBlock("code", "let a = 1")])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try caret(harness, "code", 9)

        // Markdown stays literal inside a code block.
        harness.pasteboard.string = "\n# Heading\n**bold**"
        harness.view.paste(nil)
        await harness.settle()
        XCTAssertEqual(session.surface.blocks.map(\.node), ["codeBlock"])
        XCTAssertEqual(text(of: try block(session, "code")), "let a = 1\n# Heading\n**bold**")
        XCTAssertTrue(try block(session, "code").runs.allSatisfy(\.marks.isEmpty))
        try await assertConsistent(harness, localCommands: 1)

        // HTML + plain text pastes only the plain text literally inside a code block.
        try caret(harness, "code", 0)
        harness.pasteboard.setItems([
            [
                TableClipboard.htmlType: Data("<h1>Ignored HTML</h1>".utf8),
                UTType.utf8PlainText.identifier: "// plain\n",
            ]
        ])
        harness.view.paste(nil)
        await harness.settle()
        XCTAssertEqual(session.surface.blocks.map(\.node), ["codeBlock"])
        XCTAssertEqual(text(of: try block(session, "code")), "// plain\nlet a = 1\n# Heading\n**bold**")
        try await assertConsistent(harness, localCommands: 2)
    }

    // MARK: - 9. Source editor stays literal plain text

    func testSourceEditorStaysLiteralForHTMLAndMarkdown() async throws {
        let harness = try await makeHarness([paragraph("p1", "")])
        addTeardownBlock { await harness.close() }
        setSelection(harness, NSRange(location: 0, length: 0))
        harness.view.insertText("/math")
        await harness.settle()
        let mathItem = try XCTUnwrap(NativeInputCoordinator.slashItems.first { $0.id == "mathBlock" })
        let applied = await harness.run { harness.input.applySlashItem(mathItem) }
        XCTAssertTrue(applied)
        let request = try XCTUnwrap(harness.input.requestedSource)

        let editor = NativeSourceEditorViewController(document: harness.session, request: request)
        _ = hostWindow(UINavigationController(rootViewController: editor))
        await waitUntil { editor.isLoaded }
        XCTAssertTrue(editor.isLoaded)
        let sourceSession = try XCTUnwrap(editor.sourceSession)
        addTeardownBlock { editor.close() }

        let pb = UIPasteboard.withUniqueName()
        sourceSession.input?.pasteboard = pb

        // HTML + Markdown plain text in a source editor pastes literal plain text.
        pb.setItems([
            [
                TableClipboard.htmlType: Data("<h1>Title</h1><p><strong>x</strong></p>".utf8),
                UTType.utf8PlainText.identifier: "# x^2 + **y**",
            ]
        ])
        sourceSession.textView.paste(nil)
        await sourceSession.settle()
        XCTAssertEqual(sourceSession.textView.textStorage.string, "# x^2 + **y**\n")

        // Paste and Match Style also pastes literal plain text in source editors.
        pb.string = "\n- item"
        sourceSession.textView.pasteAndMatchStyle(nil)
        await sourceSession.settle()
        XCTAssertEqual(text(of: sourceSession.surface.blocks[0]), "# x^2 + **y**\n- item")
        XCTAssertEqual(sourceSession.textView.textStorage.string, "# x^2 + **y**\u{2028}- item\n")
    }

    // MARK: - 10 & 11. Paste and Match Style, ⌘⇧V key command, and edit menu

    func testPasteAndMatchStyleCommandKeyCommandAndEditMenu() async throws {
        let harness = try await makeHarness([paragraph("p", "")])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try caret(harness, "p", 0)

        // ⌘⇧V key command exists and targets pasteAndMatchStyle(_:).
        let pastePlainCommand = try XCTUnwrap(
            harness.view.keyCommands?.first {
                $0.input == "v" && $0.modifierFlags == [.command, .shift]
            })
        XCTAssertEqual(pastePlainCommand.action, #selector(UIResponderStandardEditActions.pasteAndMatchStyle(_:)))
        XCTAssertTrue(pastePlainCommand.wantsPriorityOverSystemBehavior)

        // Empty pasteboard: neither paste nor pasteAndMatchStyle is offered.
        harness.pasteboard.items = []
        XCTAssertFalse(
            harness.view.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
        XCTAssertFalse(
            harness.view.canPerformAction(
                #selector(UIResponderStandardEditActions.pasteAndMatchStyle(_:)), withSender: nil))

        // HTML + plain text on pasteboard: both actions enabled, edit menu places Paste and Match Style after Paste.
        harness.pasteboard.setItems([
            [
                TableClipboard.htmlType: Data("<h1><strong>Formatted</strong></h1>".utf8),
                UTType.utf8PlainText.identifier: "Formatted",
            ]
        ])
        XCTAssertTrue(
            harness.view.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
        XCTAssertTrue(
            harness.view.canPerformAction(
                #selector(UIResponderStandardEditActions.pasteAndMatchStyle(_:)), withSender: nil))

        let standardEdit = UIMenu(
            identifier: .standardEdit,
            children: [
                UICommand(title: "Copy", action: #selector(UIResponderStandardEditActions.copy(_:))),
                UICommand(title: "Paste", action: #selector(UIResponderStandardEditActions.paste(_:))),
            ])
        let editMenu = try XCTUnwrap(
            harness.input.textView(
                harness.view, editMenuForTextIn: harness.view.selectedRange, suggestedActions: [standardEdit]))
        let updatedStandard = try XCTUnwrap(editMenu.children.first as? UIMenu)
        let selectors = updatedStandard.children.compactMap { ($0 as? UICommand)?.action }
        XCTAssertEqual(
            selectors,
            [
                #selector(UIResponderStandardEditActions.copy(_:)),
                #selector(UIResponderStandardEditActions.paste(_:)),
                #selector(UIResponderStandardEditActions.pasteAndMatchStyle(_:)),
            ])

        // Invoking the ⌘⇧V key command pastes HTML as literal plain text (no heading, no bold).
        harness.view.perform(pastePlainCommand.action!, with: pastePlainCommand)
        await harness.settle()
        XCTAssertEqual(session.surface.blocks.map(\.node), ["paragraph"])
        XCTAssertEqual(texts(session), ["Formatted"])
        XCTAssertTrue(session.surface.blocks[0].runs.allSatisfy(\.marks.isEmpty))
        try await assertConsistent(harness, localCommands: 1)

        // Paste and Match Style with Markdown pastes literal Markdown syntax.
        let undone = await harness.run { harness.input.undo() }
        XCTAssertTrue(undone)
        harness.pasteboard.string = "# Heading\n**bold**"
        harness.view.pasteAndMatchStyle(nil)
        await harness.settle()
        XCTAssertEqual(session.surface.blocks.map(\.node), ["paragraph", "paragraph"])
        XCTAssertEqual(texts(session), ["# Heading", "**bold**"])
        XCTAssertTrue(session.surface.blocks.allSatisfy { $0.runs.allSatisfy(\.marks.isEmpty) })
        try await assertConsistent(harness, localCommands: 3)

        // One undo restores the empty paragraph after Paste and Match Style.
        let undonePlain = await harness.run { harness.input.undo() }
        XCTAssertTrue(undonePlain)
        XCTAssertEqual(texts(session), [""])
        try await assertConsistent(harness, localCommands: 4)

        // Paste and Match Style still enforces plain-text size limits.
        harness.pasteboard.string = String(repeating: "x", count: NativeClipboard.maxPasteUTF16 + 1)
        harness.view.pasteAndMatchStyle(nil)
        await harness.settle()
        XCTAssertEqual(harness.input.noticeKey, .native_editor_paste_too_large)
        XCTAssertEqual(texts(session), [""])
        try await assertConsistent(harness, localCommands: 4)
    }

    // MARK: - 12. Same-origin doc URL priority over HTML

    func testSameOriginDocumentURLTakesPriorityOverHTMLAndMatchStyleStaysLiteral() async throws {
        let harness = try await makeHarness([paragraph("p", "")])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try caret(harness, "p", 0)

        let docURL = "\(harness.scope.serverOrigin)/docs/11111111-1111-4111-8111-111111111111/"
        harness.pasteboard.setItems([
            [
                TableClipboard.htmlType: Data("<a href=\"\(docURL)\">Linked Doc</a>".utf8),
                UTType.utf8PlainText.identifier: docURL,
            ]
        ])
        harness.view.paste(nil)
        await harness.settle()
        XCTAssertTrue(try block(session, "p").runs.contains { $0.inlineObject != nil })
        try await assertConsistent(harness, localCommands: 1)

        // Paste and Match Style skips interlinking and pastes the literal URL string.
        let undone = await harness.run { harness.input.undo() }
        XCTAssertTrue(undone)
        harness.view.pasteAndMatchStyle(nil)
        await harness.settle()
        XCTAssertEqual(text(of: try block(session, "p")), docURL)
        XCTAssertFalse(try block(session, "p").runs.contains { $0.inlineObject != nil })
        try await assertConsistent(harness, localCommands: 3)
    }

    // MARK: - 13. Oversized and empty HTML -> notice / plain fallback

    func testOversizedAndEmptyHTMLShowNoticeOrFallBackToPlainText() async throws {
        let harness = try await makeHarness([paragraph("p", "Start ")])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try caret(harness, "p", 6)

        // Oversized HTML without plain text shows the paste-too-large notice and writes nothing.
        let tooManyBytes = Data(repeating: UInt8(ascii: "a"), count: TableClipboard.maxHTMLBytes + 1)
        harness.pasteboard.setItems([[TableClipboard.htmlType: tooManyBytes]])
        harness.view.paste(nil)
        await harness.settle()
        XCTAssertEqual(harness.input.noticeKey, .native_editor_paste_too_large)
        XCTAssertEqual(texts(session), ["Start "])
        try await assertConsistent(harness, localCommands: 0)

        // Too many HTML blocks without plain text also shows the paste-too-large notice
        // (start from a clean notice state so a previous refusal cannot mask this check).
        harness.input.refuse(.native_editor_input_unavailable)
        let tooManyBlocks = String(repeating: "<p>x</p>", count: BlockNoteSubtreePayload.maxBlocks + 1)
        harness.pasteboard.setItems([[TableClipboard.htmlType: Data(tooManyBlocks.utf8)]])
        harness.view.paste(nil)
        await harness.settle()
        XCTAssertEqual(harness.input.noticeKey, .native_editor_paste_too_large)
        XCTAssertEqual(texts(session), ["Start "])
        try await assertConsistent(harness, localCommands: 0)

        // Oversized HTML accompanied by small plain text falls back to pasting the plain text.
        harness.pasteboard.setItems([
            [
                TableClipboard.htmlType: tooManyBytes,
                UTType.utf8PlainText.identifier: "plain fallback",
            ]
        ])
        harness.view.paste(nil)
        await harness.settle()
        XCTAssertEqual(texts(session), ["Start plain fallback"])
        try await assertConsistent(harness, localCommands: 1)

        // Unsupported-only HTML falls back to plain text (or drops quietly when no plain text exists).
        harness.pasteboard.setItems([[TableClipboard.htmlType: Data("<script>alert(1)</script>".utf8)]])
        harness.view.paste(nil)
        await harness.settle()
        XCTAssertEqual(texts(session), ["Start plain fallback"])
        try await assertConsistent(harness, localCommands: 1)

        harness.pasteboard.setItems([
            [
                TableClipboard.htmlType: Data("<script>alert(1)</script>".utf8),
                UTType.utf8PlainText.identifier: " ok",
            ]
        ])
        harness.view.paste(nil)
        await harness.settle()
        XCTAssertEqual(texts(session), ["Start plain fallback ok"])
        try await assertConsistent(harness, localCommands: 2)
    }

    // MARK: - 14. Toggles and locked-text blocks take the plain-text path

    func testToggleAndLockedBlockTargetsTakePlainTextPathForHTMLAndMarkdown() async throws {
        let toggleItem = BlockNoteBlock(
            node: "toggleListItem", props: Self.paragraphProps, runs: [InlineRun("Toggle ")], id: "t1")
        let toggleHeading = BlockNoteBlock(
            node: "heading",
            props: Self.paragraphProps + [("level", .int(2)), ("isToggleable", .bool(true))],
            runs: [InlineRun("Header ")], id: "th")
        let locked = BlockNoteBlock(
            node: "paragraph",
            props: Self.paragraphProps + [("futureProp", .string("v1"))],
            runs: [InlineRun("Locked ")], id: "locked")
        let harness = try await makeHarness([toggleItem, toggleHeading, locked])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        XCTAssertTrue(try block(session, "locked").isLocked)

        let safariHTML: [[String: Any]] = [
            [
                TableClipboard.htmlType: Data("<p><strong>hello</strong></p>".utf8),
                UTType.utf8PlainText.identifier: "hello",
            ]
        ]

        // Toggle list item: Safari HTML + plain text pastes "hello"; Markdown pastes literally.
        try caret(harness, "t1", 7)
        harness.pasteboard.setItems(safariHTML)
        harness.view.paste(nil)
        await harness.settle()
        XCTAssertNil(harness.input.noticeKey)
        XCTAssertEqual(text(of: try block(session, "t1")), "Toggle hello")

        try caret(harness, "t1", 12)
        harness.pasteboard.string = " **bold**"
        harness.view.paste(nil)
        await harness.settle()
        XCTAssertNil(harness.input.noticeKey)
        XCTAssertEqual(text(of: try block(session, "t1")), "Toggle hello **bold**")
        XCTAssertTrue(try block(session, "t1").runs.allSatisfy(\.marks.isEmpty))

        // Toggle heading: Safari HTML + plain text pastes "hello"; Markdown pastes literally.
        try caret(harness, "th", 7)
        harness.pasteboard.setItems(safariHTML)
        harness.view.paste(nil)
        await harness.settle()
        XCTAssertNil(harness.input.noticeKey)
        XCTAssertEqual(text(of: try block(session, "th")), "Header hello")

        try caret(harness, "th", 12)
        harness.pasteboard.string = " **bold**"
        harness.view.paste(nil)
        await harness.settle()
        XCTAssertNil(harness.input.noticeKey)
        XCTAssertEqual(text(of: try block(session, "th")), "Header hello **bold**")
        XCTAssertTrue(try block(session, "th").runs.allSatisfy(\.marks.isEmpty))

        // Locked-text lossy block: HTML non-textblock + plain text and Markdown stay plain text.
        try caret(harness, "locked", 7)
        harness.pasteboard.setItems([
            [
                TableClipboard.htmlType: Data("<hr>".utf8),
                UTType.utf8PlainText.identifier: "---",
            ]
        ])
        harness.view.paste(nil)
        await harness.settle()
        XCTAssertNil(harness.input.noticeKey)
        XCTAssertEqual(text(of: try block(session, "locked")), "Locked ---")

        try caret(harness, "locked", 10)
        harness.pasteboard.string = " **bold**"
        harness.view.paste(nil)
        await harness.settle()
        XCTAssertNil(harness.input.noticeKey)
        XCTAssertEqual(text(of: try block(session, "locked")), "Locked --- **bold**")
        XCTAssertTrue(try block(session, "locked").runs.allSatisfy(\.marks.isEmpty))
        try await assertConsistent(harness, localCommands: 6)
    }

    // MARK: - 15. UTF-16 plain text + HTML

    func testUTF16PlainTextWithHTMLIsAcceptedByPlainTextPaths() async throws {
        let harness = try await makeHarness([paragraph("p", ""), codeBlock("code", "")])
        addTeardownBlock { await harness.close() }
        let session = harness.session

        let utf16Plain = try XCTUnwrap("UTF16 plain **text**".data(using: .utf16))
        harness.pasteboard.setItems([
            [
                TableClipboard.htmlType: Data("<h1><strong>HTML</strong></h1>".utf8),
                UTType.utf16PlainText.identifier: utf16Plain,
            ]
        ])
        XCTAssertTrue(harness.input.canPastePlainTextFromPasteboard())
        XCTAssertTrue(
            harness.view.canPerformAction(
                #selector(UIResponderStandardEditActions.pasteAndMatchStyle(_:)), withSender: nil))

        // Paste and Match Style reads the UTF-16 plain text literally.
        try caret(harness, "p", 0)
        harness.view.pasteAndMatchStyle(nil)
        await harness.settle()
        XCTAssertEqual(text(of: try block(session, "p")), "UTF16 plain **text**")
        XCTAssertTrue(try block(session, "p").runs.allSatisfy(\.marks.isEmpty))

        // Code block paste also uses the UTF-16 plain text.
        try caret(harness, "code", 0)
        harness.view.paste(nil)
        await harness.settle()
        XCTAssertEqual(text(of: try block(session, "code")), "UTF16 plain **text**")

        // Oversized HTML with UTF-16 plain text falls back to the UTF-16 plain text.
        let tooManyHTMLBytes = Data(repeating: UInt8(ascii: "a"), count: TableClipboard.maxHTMLBytes + 1)
        let utf16Fallback = try XCTUnwrap(" fallback".data(using: .utf16))
        harness.pasteboard.setItems([
            [
                TableClipboard.htmlType: tooManyHTMLBytes,
                UTType.utf16PlainText.identifier: utf16Fallback,
            ]
        ])
        try caret(harness, "p", 20)
        harness.view.paste(nil)
        await harness.settle()
        XCTAssertEqual(text(of: try block(session, "p")), "UTF16 plain **text** fallback")

        // Oversized UTF-16 plain text is refused with the size-limit notice.
        let tooManyPlainBytes = Data(repeating: 0x41, count: NativeClipboard.maxPasteUTF16 * 4 + 2)
        harness.pasteboard.setItems([
            [
                TableClipboard.htmlType: Data("<p>small</p>".utf8),
                UTType.utf16PlainText.identifier: tooManyPlainBytes,
            ]
        ])
        harness.view.pasteAndMatchStyle(nil)
        await harness.settle()
        XCTAssertEqual(harness.input.noticeKey, .native_editor_paste_too_large)
        XCTAssertEqual(text(of: try block(session, "p")), "UTF16 plain **text** fallback")
        try await assertConsistent(harness, localCommands: 3)
    }

    // MARK: - 16. Table multi-cell Paste and Match Style uses shared plain-text helper

    func testTableMultiCellPasteAndMatchStyleUsesSharedPlainTextHelper() async throws {
        let (harness, editor) = try await openTable()
        let table = try XCTUnwrap(editor.cellSession)
        editor.activate(TableGrid.CellRef(row: 1, index: 1), caret: .start)
        editor.select(.init(anchor: TableSlot(row: 1, column: 1), head: TableSlot(row: 2, column: 2)))

        // UTF-16 plain text + HTML fills the multi-cell selection with the UTF-16 plain text.
        let utf16Cell = try XCTUnwrap("utf16 cell".data(using: .utf16))
        harness.pasteboard.setItems([
            [
                TableClipboard.htmlType: Data("<table><tr><td>HTML</td></tr></table>".utf8),
                UTType.utf16PlainText.identifier: utf16Cell,
            ]
        ])
        XCTAssertTrue(table.input?.canPastePlainTextFromPasteboard() ?? false)
        let filled = await table.run {
            table.textView.pasteAndMatchStyle(nil)
            return true
        }
        XCTAssertTrue(filled)
        let filledR1C1 = await harness.engine { $0.tableGrid("tbl")?.rows[1][1].runs.map(\.text).joined() }
        let filledR2C2 = await harness.engine { $0.tableGrid("tbl")?.rows[2][2].runs.map(\.text).joined() }
        XCTAssertEqual(filledR1C1, "utf16 cell")
        XCTAssertEqual(filledR2C2, "utf16 cell")

        // Oversized UTF-16 plain text refuses via the shared byte bound.
        editor.select(.init(anchor: TableSlot(row: 1, column: 1), head: TableSlot(row: 2, column: 2)))
        harness.pasteboard.setItems([
            [
                TableClipboard.htmlType: Data("<p>small</p>".utf8),
                UTType.utf16PlainText.identifier: Data(repeating: 0x41, count: NativeClipboard.maxPasteUTF16 * 4 + 2),
            ]
        ])
        table.textView.pasteAndMatchStyle(nil)
        await table.settle()
        XCTAssertEqual(table.input?.noticeKey, .native_editor_paste_too_large)
    }

    // MARK: - 17. Internal payloads take priority over HTML and Markdown

    func testInternalSubtreeAndInlinePayloadsTakePriorityOverHTMLAndMarkdown() async throws {
        let harness = try await makeHarness([paragraph("empty", "")])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try caret(harness, "empty", 0)

        // BlockNoteSubtreePayload + public.html + Markdown text -> subtree payload wins.
        let subtreePayload = try BlockNoteSubtreePayload.encode([
            .element(
                "blockContainer", [("id", .string("sub-1"))],
                [
                    .element(
                        "quote",
                        [("backgroundColor", .string("default")), ("textColor", .string("default"))],
                        [.text([.run(InlineRun("From Subtree"))])])
                ])
        ])
        harness.pasteboard.setItems([
            [
                BlockNoteSubtreePayload.pasteboardType: subtreePayload,
                TableClipboard.htmlType: Data("<h1>From HTML</h1>".utf8),
                UTType.utf8PlainText.identifier: "# From Markdown",
            ]
        ])
        harness.view.paste(nil)
        await harness.settle()
        XCTAssertEqual(session.surface.blocks.map(\.node), ["quote"])
        XCTAssertEqual(texts(session), ["From Subtree"])
        try await assertConsistent(harness, localCommands: 1)

        // BlockNoteInlinePayload + public.html + Markdown text -> inline payload wins.
        let math = NativeInlineObject.math(source: "x^2")
        let inlinePayload = try BlockNoteInlinePayload.encode([
            [
                .text([.run(InlineRun(" "))]),
                .element(math.nodeName, math.canonicalProps, math.canonicalChildren),
            ]
        ])
        let quoteID = session.surface.blocks[0].id
        try caret(harness, quoteID, "From Subtree".utf16.count)
        harness.pasteboard.setItems([
            [
                BlockNoteInlinePayload.pasteboardType: inlinePayload,
                TableClipboard.htmlType: Data("<p><strong>From HTML</strong></p>".utf8),
                UTType.utf8PlainText.identifier: "**From Markdown**",
            ]
        ])
        harness.view.paste(nil)
        await harness.settle()
        let updatedQuote = try block(session, quoteID)
        XCTAssertEqual(session.surface.blocks.map(\.node), ["quote"])
        XCTAssertTrue(
            updatedQuote.runs.contains {
                if case .math(source: "x^2") = $0.inlineObject { true } else { false }
            },
            "inline payload must win over HTML and Markdown")
        XCTAssertFalse(text(of: updatedQuote).contains("From HTML"))
        XCTAssertFalse(text(of: updatedQuote).contains("From Markdown"))
        try await assertConsistent(harness, localCommands: 2)
    }

    // MARK: - 18. HTML-only pasteboard: Paste and Match Style pastes its text literally

    func testHTMLOnlyPasteboardMatchStylePastesTheHTMLTextLiterally() async throws {
        let harness = try await makeHarness([paragraph("p", "Keep")])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try caret(harness, "p", 4)

        // With only HTML, iOS offers its text form: Paste and Match Style pastes that text, never blocks.
        harness.pasteboard.setItems([
            [TableClipboard.htmlType: Data("<h1><strong>Formatted</strong></h1>".utf8)]
        ])
        XCTAssertTrue(harness.input.canPastePlainTextFromPasteboard())
        harness.view.pasteAndMatchStyle(nil)
        await harness.settle()
        XCTAssertTrue(session.surface.blocks.allSatisfy { $0.node == "paragraph" })
        XCTAssertEqual(texts(session).first, "KeepFormatted")
        XCTAssertTrue(session.surface.blocks.allSatisfy { $0.runs.allSatisfy(\.marks.isEmpty) })
        try await assertConsistent(harness, localCommands: 1)
    }

    // MARK: - 19. Dropped-only Markdown stays literal (pasted text is never lost)

    func testMarkdownWhoseConstructsAreAllDroppedPastesLiterally() async throws {
        let harness = try await makeHarness([paragraph("p", "")])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try caret(harness, "p", 0)

        let raw = "![photo](http://insecure.example/a.png)"
        harness.pasteboard.string = raw
        harness.view.paste(nil)
        await harness.settle()

        XCTAssertEqual(session.surface.blocks.map(\.node), ["paragraph"])
        XCTAssertEqual(texts(session), [raw])
        try await assertConsistent(harness, localCommands: 1)
    }

    // MARK: - 20. Busy input pastes plain text; composition drops the paste

    func testActiveBarrierPastesPlainAndCompositionDropsHTMLAndMarkdownPaste() async throws {
        let disk = Latch()
        let interrupt: @Sendable (ReplicaStore.Operation, ReplicaStore.Boundary) throws -> Void = {
            operation, boundary in
            if operation == .append, boundary == .payloadWritten { disk.pass() }
        }
        let harness = try await makeHarness([paragraph("p1", "Hello world")], interrupt: interrupt)
        addTeardownBlock {
            disk.open()
            await harness.close()
        }
        let session = harness.session

        // Active barrier: HTML and Markdown paste as plain text, queued behind the barrier as before.
        try caret(harness, "p1", 5)
        harness.view.insertText("\n")
        await waitUntil { disk.waiting == 1 }

        harness.pasteboard.setItems([
            [
                TableClipboard.htmlType: Data("<h1><strong>Queued</strong></h1>".utf8),
                UTType.utf8PlainText.identifier: "Queued",
            ]
        ])
        XCTAssertTrue(harness.input.pasteFromPasteboard())
        XCTAssertNotEqual(harness.input.noticeKey, .native_editor_input_busy)
        harness.pasteboard.string = "## Literal "
        XCTAssertTrue(harness.input.pasteFromPasteboard())

        disk.open()
        await harness.settle()
        XCTAssertEqual(session.surface.blocks.map(\.node), ["paragraph", "paragraph"])
        XCTAssertEqual(texts(session), ["Hello", "Queued## Literal  world"])
        XCTAssertTrue(session.surface.blocks.allSatisfy { $0.runs.allSatisfy(\.marks.isEmpty) })
        try await assertConsistent(harness, localCommands: 3)

        // Composition owns view: HTML and Markdown pastes are dropped without mutating.
        try caret(harness, "p1", 2)
        harness.view.setMarkedText("にほん", selectedRange: NSRange(location: 0, length: 3))
        XCTAssertTrue(harness.input.compositionOwnsView)
        harness.pasteboard.setItems([
            [
                TableClipboard.htmlType: Data("<p><strong>Ignored</strong></p>".utf8),
                UTType.utf8PlainText.identifier: "Ignored",
            ]
        ])
        XCTAssertFalse(harness.input.pasteFromPasteboard())
        harness.pasteboard.string = "**Ignored**"
        XCTAssertFalse(harness.input.pasteFromPasteboard())
        harness.view.unmarkText()
        await harness.settle()
        XCTAssertEqual(texts(session), ["Heにほんllo", "Queued## Literal  world"])
        try await assertConsistent(harness, localCommands: 4)
    }
}
