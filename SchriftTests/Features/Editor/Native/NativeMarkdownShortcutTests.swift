import UIKit
import XCTest

@testable import Schrift

/// PR09: markdown typing shortcuts in the native editor. A paragraph that
/// starts with a markdown prefix converts as its trailing space is typed, the
/// prefix removed in the same transaction and the caret left at the start; a
/// ``` fence converts on Return. Only typing converts (never paste), only a
/// plain paragraph (never a table cell, a locked block or a scoped source),
/// and one undo after a conversion restores the paragraph with its typed
/// prefix.
@MainActor
final class NativeMarkdownShortcutTests: NativeEditingTestCase {
    /// Grouping must not depend on CI speed: the typing of a prefix and the
    /// conversion that follows it split only at the conversion's boundary.
    override func makeHarness(
        _ blocks: [BlockNoteBlock] = seedBlocks(),
        interrupt: (@Sendable (ReplicaStore.Operation, ReplicaStore.Boundary) throws -> Void)? = nil,
        hooks: DocumentReplicaSession.Hooks = .init()
    ) async throws -> Harness {
        let harness = try await super.makeHarness(blocks, interrupt: interrupt, hooks: hooks)
        _ = await harness.session.history { $0.history.captureTimeout = 60_000 }
        addTeardownBlock { await harness.close() }
        return harness
    }

    private func caret(_ harness: Harness, _ id: String, _ offset: Int) throws {
        setSelection(harness, NSRange(location: try location(harness.session, id, offset), length: 0))
    }

    /// A selection on a table or column surface, whose session is not the harness's.
    private func select(_ session: NativeEditorSession, _ range: NSRange) {
        session.textView.selectedRange = range
        session.input?.textViewDidChangeSelection(session.textView)
    }

    /// Types `text` one character at a time, as the keyboard does.
    private func type(_ session: NativeEditorSession, _ text: String) {
        for character in text { session.textView.insertText(String(character)) }
    }

    private func converted(_ harness: Harness) -> Bool {
        harness.log.commands.contains {
            if case .blockType = $0.kind { true } else { false }
        }
    }

    private func fixture(_ name: String) throws -> Data {
        let base64 =
            BlockNoteTableCaptures.fixtures.first { $0.name == name }?.update
            ?? BlockNoteColumnCaptures.fixtures.first { $0.name == name }?.update
        return try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(base64, name)))
    }

    /// A checkpoint whose `blockID` paragraph carries a mention at `offset`.
    private func stateWithMention(_ blocks: [BlockNoteBlock], blockID: String, at offset: Int) throws -> Data {
        let doc = try makeDoc(blocks, clientID: 1)
        defer { doc.destroy() }
        let writer = BlockNoteWriter(doc: doc)
        _ = try writer.insertInlineObject(
            .mention(userID: "u1", fullName: "Ada"), in: try writer.find(blockID), replacing: offset..<offset)
        return try YStateEncoder.encodeStateAsUpdate(doc)
    }

    // MARK: - Typing shortcuts

    func testTypingShortcutsConvertAtBlockStart() async throws {
        let cases: [(prefix: String, node: String, props: [ProjectedProp])] = [
            ("# ", "heading", [ProjectedProp(key: "level", value: .int(1))]),
            ("## ", "heading", [ProjectedProp(key: "level", value: .int(2))]),
            ("### ", "heading", [ProjectedProp(key: "level", value: .int(3))]),
            ("- ", "bulletListItem", []),
            ("* ", "bulletListItem", []),
            ("+ ", "bulletListItem", []),
            ("1. ", "numberedListItem", []),
            ("1) ", "numberedListItem", []),
            ("[] ", "checkListItem", [ProjectedProp(key: "checked", value: .bool(false))]),
            ("[ ] ", "checkListItem", [ProjectedProp(key: "checked", value: .bool(false))]),
            ("[x] ", "checkListItem", [ProjectedProp(key: "checked", value: .bool(true))]),
            ("> ", "quote", []),
        ]
        for (prefix, node, props) in cases {
            let harness = try await makeHarness([paragraph("p", ""), paragraph("after", "Next")])
            let session = harness.session
            try caret(harness, "p", 0)
            type(session, prefix)
            await harness.settle()
            let block = try block(session, "p")
            XCTAssertEqual(block.node, node, prefix)
            XCTAssertEqual(text(of: block), "", "the prefix is removed: \(prefix)")
            for prop in props {
                XCTAssertTrue(block.props.contains(prop), "\(prefix) carries \(prop.key)")
            }
            XCTAssertEqual(
                harness.view.selectedRange, NSRange(location: try location(session, "p", 0), length: 0),
                "the caret is at the start: \(prefix)")
            XCTAssertEqual(
                harness.log.commands.last?.kind,
                .blockType(node: node, props: props, removing: 0..<prefix.utf16.count), prefix)
            try await assertConsistent(harness, localCommands: prefix.count + 1)
            await harness.close()
        }
    }

    func testHeadingLevelsFourToSixStayLiteral() async throws {
        for prefix in ["#### ", "##### ", "###### "] {
            let harness = try await makeHarness([paragraph("p", "")])
            let session = harness.session
            try caret(harness, "p", 0)
            type(session, prefix)
            await harness.settle()
            XCTAssertEqual(try block(session, "p").node, "paragraph", prefix)
            XCTAssertEqual(text(of: try block(session, "p")), prefix, prefix)
            XCTAssertFalse(converted(harness), prefix)
            try await assertConsistent(harness, localCommands: prefix.count)
            await harness.close()
        }
    }

    func testMidLineShortcutStaysLiteral() async throws {
        let harness = try await makeHarness([paragraph("p", "abc")])
        let session = harness.session
        try caret(harness, "p", 3)
        type(session, "# ")
        await harness.settle()
        XCTAssertEqual(try block(session, "p").node, "paragraph")
        XCTAssertEqual(text(of: try block(session, "p")), "abc# ")
        XCTAssertFalse(converted(harness))
        try await assertConsistent(harness, localCommands: 2)
    }

    func testShortcutInATableCellStaysLiteral() async throws {
        let harness = try await makeHarness(state: try fixture("styled"))
        let table = try await unwrapped(await harness.session.openTable("tbl"), "the table opens")
        addTeardownBlock { await table.close().value }
        let input = try XCTUnwrap(table.input)
        let cellID = table.surface.blocks[0].id
        input.showCell([cellID])
        select(table, NSRange(location: try location(table, cellID, 0), length: 0))
        type(table, "# ")
        await table.settle()
        await harness.settle()
        XCTAssertEqual(table.surface.blocks[0].node, "paragraph")
        XCTAssertEqual(text(of: table.surface.blocks[0]), "# Name")
        XCTAssertFalse(converted(harness))
        await table.close().value
        await harness.settle()
        try await assertConsistent(harness, localCommands: 2)
    }

    func testLockedBlockStaysLiteral() async throws {
        let harness = try await makeHarness([
            paragraph("before", "Before"),
            BlockNoteBlock(
                node: "paragraph", props: Self.paragraphProps + [("futureProp", .string("v1"))],
                runs: [InlineRun("Future")], id: "future"),
            paragraph("after", "After"),
        ])
        let session = harness.session
        try caret(harness, "future", 0)
        type(session, "# ")
        await harness.settle()
        XCTAssertEqual(try block(session, "future").node, "paragraph")
        XCTAssertEqual(text(of: try block(session, "future")), "# Future")
        XCTAssertFalse(converted(harness))
        try await assertConsistent(harness, localCommands: 2)
    }

    func testParagraphWithChildrenKeepsThem() async throws {
        let harness = try await makeHarness([
            BlockNoteBlock(
                node: "paragraph", props: Self.paragraphProps, runs: [], id: "p",
                children: [paragraph("child", "Child")])
        ])
        let session = harness.session
        try caret(harness, "p", 0)
        type(session, "# ")
        await harness.settle()
        XCTAssertEqual(try block(session, "p").node, "heading")
        XCTAssertEqual(session.surface.blocks.map(\.id), ["p", "child"])
        XCTAssertEqual(try block(session, "child").parentID, "p")
        try await assertConsistent(harness, localCommands: 3)
    }

    func testShortcutWorksInAColumn() async throws {
        let harness = try await makeHarness(state: try fixture("two"))
        let column = try await unwrapped(
            await harness.session.openColumn(group: "cl", column: "c1"), "the column opens")
        addTeardownBlock { await column.close().value }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.addSubview(column.textView)
        column.textView.frame = window.bounds
        window.isHidden = false
        addTeardownBlock { window.isHidden = true }
        select(column, NSRange(location: try location(column, "a", 0), length: 0))
        type(column, "# ")
        await column.settle()
        await harness.settle()
        XCTAssertEqual(column.surface.blocks[0].node, "heading")
        XCTAssertEqual(text(of: column.surface.blocks[0]), "Left text")
        XCTAssertEqual(
            column.textView.selectedRange, NSRange(location: try location(column, "a", 0), length: 0))
        await column.close().value
        await harness.settle()
        try await assertConsistent(harness, localCommands: 3)
    }

    // MARK: - Return shortcuts

    func testCodeFenceOnReturnBecomesACodeBlock() async throws {
        for (fence, language) in [("```swift", "swift"), ("```", "text")] {
            let harness = try await makeHarness([paragraph("p", fence), paragraph("after", "Next")])
            let session = harness.session
            try caret(harness, "p", fence.utf16.count)
            let converted = await harness.run { harness.input.insertNewline() }
            XCTAssertTrue(converted, fence)
            let block = try block(session, "p")
            XCTAssertEqual(block.node, "codeBlock", fence)
            XCTAssertEqual(text(of: block), "", fence)
            XCTAssertTrue(
                block.props.contains(ProjectedProp(key: "language", value: .string(language))), fence)
            XCTAssertEqual(
                harness.view.selectedRange, NSRange(location: try location(session, "p", 0), length: 0), fence)
            try await assertConsistent(harness, localCommands: 1)
            await harness.close()
        }
    }

    /// Return with the caret inside a fence splits there: only Return at the end converts.
    func testReturnInsideAFenceSplitsInsteadOfConverting() async throws {
        let harness = try await makeHarness([paragraph("p", "```swift"), paragraph("after", "Next")])
        let session = harness.session
        try caret(harness, "p", 3)
        _ = await harness.run { harness.input.insertNewline() }
        XCTAssertEqual(try block(session, "p").node, "paragraph", "the fence stays a paragraph")
        XCTAssertEqual(text(of: try block(session, "p")), "```", "split at the caret")
        await harness.close()
    }

    func testDividerOnReturnStillConverts() async throws {
        let harness = try await makeHarness([paragraph("p", "---"), paragraph("after", "Next")])
        let session = harness.session
        try caret(harness, "p", 3)
        let converted = await harness.run { harness.input.insertNewline() }
        XCTAssertTrue(converted)
        XCTAssertEqual(session.surface.blocks.map(\.node), ["divider", "paragraph"])
        XCTAssertEqual(text(of: session.surface.blocks[1]), "Next")
        try await assertConsistent(harness, localCommands: 1)
    }

    // MARK: - Paste and undo

    func testPasteOfAMarkdownPrefixDoesNotConvert() async throws {
        let harness = try await makeHarness([paragraph("p", "")])
        let session = harness.session
        try caret(harness, "p", 0)
        harness.pasteboard.string = "# Title"
        let pasted = await harness.run { harness.input.pasteFromPasteboard() }
        XCTAssertTrue(pasted)
        XCTAssertEqual(try block(session, "p").node, "paragraph")
        XCTAssertEqual(text(of: try block(session, "p")), "# Title")
        XCTAssertFalse(converted(harness))
        try await assertConsistent(harness, localCommands: 1)
    }

    func testUndoAfterAShortcutRestoresTheTypedPrefix() async throws {
        let harness = try await makeHarness([paragraph("p", "")])
        let session = harness.session
        try caret(harness, "p", 0)
        type(session, "# ")
        await harness.settle()
        XCTAssertEqual(try block(session, "p").node, "heading")
        XCTAssertEqual(text(of: try block(session, "p")), "")

        let undone = await harness.run { harness.input.undo() }
        XCTAssertTrue(undone)
        XCTAssertEqual(try block(session, "p").node, "paragraph")
        XCTAssertEqual(text(of: try block(session, "p")), "# ", "the typed prefix stays")
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(session, "p", 2), length: 0))

        let redone = await harness.run { harness.input.redo() }
        XCTAssertTrue(redone)
        XCTAssertEqual(try block(session, "p").node, "heading")
        XCTAssertEqual(text(of: try block(session, "p")), "")
        try await assertConsistent(harness, localCommands: 5)
    }

    // MARK: - The barrier path

    /// A paragraph with an inline object shows a typed space only when its
    /// barrier settles: the check must run then, not bail on the busy surface.
    func testShortcutConvertsAParagraphWithAnInlineObject() async throws {
        let harness = try await makeHarness(
            state: try stateWithMention([paragraph("p", "Hi "), paragraph("after", "Next")], blockID: "p", at: 3))
        let session = harness.session
        try caret(harness, "p", 0)
        type(session, "# ")
        await harness.settle()
        let block = try block(session, "p")
        XCTAssertEqual(block.node, "heading")
        XCTAssertEqual(block.runs.last?.inlineObject, .mention(userID: "u1", fullName: "Ada"), "the mention stays")
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(session, "p", 0), length: 0))
        try await assertConsistent(harness, localCommands: 3)
    }

    /// A block the session refused predictions for types through barriers: the
    /// space's check follows the barrier that shows it.
    func testShortcutConvertsInABarrierOnlyBlock() async throws {
        let blocks = [paragraph("p", "Alpha beta"), paragraph("after", "Next")]
        let harness = try await makeHarness(blocks)
        let session = harness.session
        // A peer edit the surface cannot rebase puts the block on the barrier path.
        let peer = try makeDoc(blocks, clientID: 9)
        defer { peer.destroy() }
        let update = try BlockNoteWriter(doc: peer).replaceText(block: "p", range: 2..<8, with: "")
        session.replica?.mailbox.post(.integrate(update, reply: nil))
        try caret(harness, "p", 4)
        session.textView.insertText("x")
        await harness.settle()
        XCTAssertEqual(text(of: try block(session, "p")), "Alta", "the peer edit stands")

        try caret(harness, "p", 0)
        type(session, "# ")
        await harness.settle()
        XCTAssertEqual(try block(session, "p").node, "heading")
        XCTAssertEqual(text(of: try block(session, "p")), "Alta")
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(session, "p", 0), length: 0))
        try await assertConsistent(harness, localCommands: 3)
    }

    // MARK: - Composing keyboards

    /// A ja/ko keyboard's space is written by UIKit and submitted as a command:
    /// it is a typed space, so the prefix converts.
    func testShortcutConvertsAfterAComposingKeyboardsDirectSpace() async throws {
        let harness = try await makeHarness([paragraph("p", ""), paragraph("after", "Next")])
        let session = harness.session
        let input = try XCTUnwrap(session.input)
        input.inputLanguage = { "ja-JP" }
        try caret(harness, "p", 0)
        session.textView.insertText("#")
        await harness.settle()

        let range = NSRange(location: try location(session, "p", 1), length: 0)
        session.textView.selectedRange = range
        XCTAssertTrue(
            input.textView(session.textView, shouldChangeTextInRanges: [NSValue(range: range)], replacementText: " "))
        session.textView.textStorage.replaceCharacters(in: range, with: " ")
        input.textViewDidChange(session.textView)
        await harness.settle()

        XCTAssertEqual(try block(session, "p").node, "heading")
        XCTAssertEqual(text(of: try block(session, "p")), "")
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(session, "p", 0), length: 0))
        try await assertConsistent(harness, localCommands: 3)
    }

    /// An IME composition that commits a bare space is a typed space too.
    func testShortcutConvertsAfterAnIMEBareSpaceCommit() async throws {
        let harness = try await makeHarness([paragraph("p", ""), paragraph("after", "Next")])
        let session = harness.session
        try caret(harness, "p", 0)
        session.textView.insertText("#")
        await harness.settle()

        session.textView.selectedRange = NSRange(location: try location(session, "p", 1), length: 0)
        session.textView.setMarkedText(" ", selectedRange: NSRange(location: 1, length: 0))
        await harness.settle()
        session.textView.unmarkText()
        await harness.settle()

        XCTAssertEqual(try block(session, "p").node, "heading")
        XCTAssertEqual(text(of: try block(session, "p")), "")
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(session, "p", 0), length: 0))
        try await assertConsistent(harness, localCommands: 3)
    }

    // MARK: - Fences

    /// A fence paragraph with an inline object is never a fence: its text
    /// carries the object's placeholder, so Return splits it as ordinary text.
    func testACodeFenceWithAnInlineObjectSplitsAsText() async throws {
        let harness = try await makeHarness(
            state: try stateWithMention([paragraph("p", "```"), paragraph("after", "Next")], blockID: "p", at: 3))
        let session = harness.session
        try caret(harness, "p", 3)
        let split = await harness.run { harness.input.insertNewline() }
        XCTAssertTrue(split)
        XCTAssertNil(harness.input.noticeKey, "no refusal: the fence is never attempted")
        XCTAssertEqual(session.surface.blocks.map(\.node), ["paragraph", "paragraph", "paragraph"])
        XCTAssertEqual(text(of: session.surface.blocks[0]), "```")
        XCTAssertEqual(
            session.surface.blocks[1].runs.first?.inlineObject, .mention(userID: "u1", fullName: "Ada"),
            "the mention stays")
        try await assertConsistent(harness, localCommands: 1)
    }

    /// A language the engine's `language` prop refuses splits as text instead
    /// of turning Return into a refusal.
    func testACodeFenceWithAnInvalidLanguageSplitsAsText() async throws {
        let harness = try await makeHarness([paragraph("p", "```foo bar"), paragraph("after", "Next")])
        let session = harness.session
        try caret(harness, "p", 10)
        let split = await harness.run { harness.input.insertNewline() }
        XCTAssertTrue(split)
        XCTAssertNil(harness.input.noticeKey)
        XCTAssertEqual(session.surface.blocks.map(\.node), ["paragraph", "paragraph", "paragraph"])
        XCTAssertEqual(text(of: session.surface.blocks[0]), "```foo bar")
        try await assertConsistent(harness, localCommands: 1)
    }

    /// The engine and the fence shortcut share one language rule, and it
    /// refuses an inline object's placeholder.
    func testTheSharedLanguageRuleRefusesAnInlineObjectPlaceholder() {
        XCTAssertFalse(isValidCodeBlockLanguage("\u{FFFC}"))
        XCTAssertFalse(isValidCodeBlockLanguage("foo bar"))
        XCTAssertFalse(isValidCodeBlockLanguage(""))
        XCTAssertTrue(isValidCodeBlockLanguage("swift"))
    }
}
