import UIKit
import XCTest

@testable import Schrift

/// PR04a: Return and Backspace at a block start are structural, each one
/// durable command through journal-before-publication. Real `NativeTextView`
/// input over a restored durable replica (so the unjournaled-transaction
/// freeze is armed), no sleeps. Every action asserts exactly one journaled
/// command, storage equal to the projection and replay equal to the surface.
@MainActor
final class NativeStructuralTests: DocumentEngineTestCase {
    private final class WriteLog {
        var commands: [NativeEditCommand] = []
    }

    @MainActor
    private struct Harness {
        let session: NativeEditorSession
        let store: ReplicaStore
        let scope: ReplicaScope
        let log: WriteLog
        let directory: URL

        func close() {
            session.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeHarness(_ blocks: [BlockNoteBlock] = seedBlocks()) throws -> Harness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scope = ReplicaScope(
            serverOrigin: "https://example.test", ownerUserID: UUID(), org: "docs", documentID: UUID())
        let store = ReplicaStore(directory: directory)
        _ = try store.create(for: scope, checkpoint: BlockNoteYjs.encode(blocks, clientID: Self.seedClientID))
        let session = try XCTUnwrap(NativeEditorSession.restore(store: store, scope: scope))
        let log = WriteLog()
        session.enableTyping { command, update in
            log.commands.append(command)
            try store.append(
                update, for: scope, commandID: command.id, baseRevision: command.baseRevision, origin: .local)
        }
        return Harness(session: session, store: store, scope: scope, log: log, directory: directory)
    }

    /// Storage equals a fresh projection of the surface's blocks, the range
    /// index is current, and the durable journal replays to those blocks.
    private func assertConsistent(
        _ harness: Harness, localCommands: Int, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let session = harness.session
        let fresh = AttributedDocumentProjection.attributedString(
            blocks: session.surface.blocks, traits: session.surface.traits, labels: session.surface.labels)
        XCTAssertTrue(
            session.textView.textStorage.isEqual(to: fresh), "storage equals the projection", file: file, line: line)
        XCTAssertEqual(
            session.surface.rangeIndex.entries,
            ProjectionRangeIndex(blocks: session.surface.blocks, labels: session.surface.labels).entries,
            file: file, line: line)
        let restored = try XCTUnwrap(harness.store.restore(for: harness.scope), file: file, line: line)
        XCTAssertEqual(
            restored.manifest.journal.filter { $0.origin == .local }.map(\.commandID),
            harness.log.commands.map(\.id), file: file, line: line)
        XCTAssertEqual(
            harness.log.commands.count, localCommands, "one journaled command per action", file: file, line: line)
        let replica = YDoc(clientID: 99)
        defer { replica.destroy() }
        try replica.applyUpdate(YUpdateDecoder.decode(restored.checkpoint), origin: .remote)
        for update in restored.updates { try replica.applyUpdate(YUpdateDecoder.decode(update), origin: .remote) }
        XCTAssertEqual(session.surface.blocks, projection(replica), "replay equals the surface", file: file, line: line)
        XCTAssertFalse(session.engine.nativeWriteFailed, file: file, line: line)
        XCTAssertTrue(session.textView.isEditable, file: file, line: line)
    }

    private func caret(_ session: NativeEditorSession, _ blockID: String, _ offset: Int) throws -> Int {
        try XCTUnwrap(session.surface.rangeIndex.entry(for: blockID)).textRange.location + offset
    }

    private func place(_ session: NativeEditorSession, _ blockID: String, _ offset: Int) throws {
        session.textView.selectedRange = NSRange(location: try caret(session, blockID, offset), length: 0)
    }

    private func block(_ session: NativeEditorSession, _ id: String) throws -> BlockSnapshot {
        try XCTUnwrap(session.surface.blocks.first { $0.id == id })
    }

    private func newID(_ harness: Harness, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard case .split(_, let id)? = harness.log.commands.last?.kind else {
            XCTFail("the last command is not a split", file: file, line: line)
            return ""
        }
        return id
    }

    private func paragraph(_ id: String, _ text: String) -> BlockNoteBlock {
        BlockNoteBlock(
            node: "paragraph", props: Self.paragraphProps, runs: text.isEmpty ? [] : [InlineRun(text)], id: id)
    }

    private func heading(_ id: String, _ text: String, level: Int = 1) -> BlockNoteBlock {
        BlockNoteBlock(
            node: "heading", props: Self.paragraphProps + [("level", .int(level)), ("isToggleable", .bool(false))],
            runs: [InlineRun(text)], id: id)
    }

    private func listItem(_ node: String, _ id: String, _ text: String) -> BlockNoteBlock {
        let extra: [(key: String, value: YAnyValue)] =
            node == "checkListItem"
            ? [("checked", .bool(false))] : node == "numberedListItem" ? [("start", .undefined)] : []
        return BlockNoteBlock(
            node: node, props: Self.paragraphProps + extra, runs: text.isEmpty ? [] : [InlineRun(text)], id: id)
    }

    // MARK: - Return

    func testReturnSplitsAtTheStartMiddleAndEnd() throws {
        // (offset, block keeping the old id, new block's text, new block's index, caret block)
        for (offset, kept, created, createdIndex, caretOnNew) in [
            (0, "First paragraph.", "", 0, false),
            (5, "First", " paragraph.", 1, true),
            (16, "First paragraph.", "", 1, true),
        ] {
            let harness = try makeHarness()
            defer { harness.close() }
            let session = harness.session
            let recorder = StructuralPatchRecorder(session.surface)
            session.engine.surface = recorder
            try place(session, Self.firstID, offset)
            session.textView.insertText("\n")

            let command = try XCTUnwrap(harness.log.commands.first)
            XCTAssertEqual(command.blockID, Self.firstID)
            XCTAssertEqual(command.baseRevision, 0)
            let id = newID(harness)
            XCTAssertEqual(command.kind, .split(offset: offset, newID: id))
            XCTAssertEqual(session.surface.blocks.count, 4)
            XCTAssertEqual(text(of: try block(session, Self.firstID)), kept)
            XCTAssertEqual(try block(session, id).node, "paragraph")
            XCTAssertEqual(text(of: try block(session, id)), created)
            XCTAssertEqual(session.surface.blocks[createdIndex].id, id)
            // The caret starts the lower block: at offset 0 that is the text
            // that moved down, which keeps its id.
            XCTAssertEqual(
                session.textView.selectedRange,
                NSRange(location: try caret(session, caretOnNew ? id : Self.firstID, 0), length: 0))
            XCTAssertEqual(session.engine.revision, 1)
            XCTAssertNil(session.input?.noticeKey)
            XCTAssertEqual(recorder.patches.count, 1, "one stamped emission, reconciled once")
            XCTAssertNotNil(recorder.patches.first?.nativeCommand)
            XCTAssertFalse(recorder.didReset, "slices are reconciled, never the whole storage")
            try assertConsistent(harness, localCommands: 1)
        }
    }

    func testHeadingSplitKeepsTheHeadingAndCreatesAParagraph() throws {
        let harness = try makeHarness([heading("heading", "Heading text", level: 2)])
        defer { harness.close() }
        let session = harness.session
        try place(session, "heading", 8)
        session.textView.insertText("\n")

        let id = newID(harness)
        let source = try block(session, "heading")
        XCTAssertEqual(source.node, "heading")
        XCTAssertEqual(text(of: source), "Heading ")
        XCTAssertEqual(source.props.first { $0.key == "level" }?.value, .int(2))
        let created = try block(session, id)
        XCTAssertEqual(created.node, "paragraph")
        XCTAssertEqual(text(of: created), "text")
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: created.props.map { ($0.key, $0.value) }),
            Dictionary(uniqueKeysWithValues: Self.paragraphProps.map { ($0.key, $0.value) }), "default props")
        XCTAssertEqual(session.textView.selectedRange.location, try caret(session, id, 0))
        try assertConsistent(harness, localCommands: 1)
    }

    func testListItemSplitKeepsTheSameKind() throws {
        for node in ["bulletListItem", "numberedListItem", "checkListItem"] {
            let harness = try makeHarness([listItem(node, "item", "Item text")])
            defer { harness.close() }
            let session = harness.session
            try place(session, "item", 5)
            session.textView.insertText("\n")

            let id = newID(harness)
            XCTAssertEqual(try block(session, "item").node, node)
            XCTAssertEqual(text(of: try block(session, "item")), "Item ")
            XCTAssertEqual(try block(session, id).node, node, "a split list item keeps its kind")
            XCTAssertEqual(text(of: try block(session, id)), "text")
            XCTAssertEqual(session.textView.selectedRange.location, try caret(session, id, 0))
            try assertConsistent(harness, localCommands: 1)
        }
    }

    /// BlockNote's list-item Enter: an empty item becomes a paragraph in
    /// place. No block is created, so the minted id never reaches the model.
    func testReturnOnAnEmptyListItemTurnsItIntoAParagraph() throws {
        let harness = try makeHarness([
            listItem("bulletListItem", "full", "Full"), listItem("bulletListItem", "empty", ""),
        ])
        defer { harness.close() }
        let session = harness.session
        try place(session, "empty", 0)
        session.textView.insertText("\n")

        let id = newID(harness)
        XCTAssertEqual(session.surface.blocks.map(\.id), ["full", "empty"])
        XCTAssertFalse(session.surface.blocks.contains { $0.id == id })
        XCTAssertEqual(try block(session, "empty").node, "paragraph")
        XCTAssertEqual(try block(session, "full").node, "bulletListItem")
        XCTAssertEqual(session.textView.selectedRange.location, try caret(session, "empty", 0))
        try assertConsistent(harness, localCommands: 1)
    }

    // MARK: - Backspace

    func testBackspaceJoinsAParagraphIntoAParagraph() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let session = harness.session
        let recorder = StructuralPatchRecorder(session.surface)
        session.engine.surface = recorder
        try place(session, Self.secondID, 0)
        session.textView.deleteBackward()

        let command = try XCTUnwrap(harness.log.commands.first)
        XCTAssertEqual(command.blockID, Self.secondID)
        XCTAssertEqual(command.kind, .join)
        XCTAssertEqual(session.surface.blocks.map(\.id), [Self.firstID, Self.thirdID])
        let joined = try block(session, Self.firstID)
        XCTAssertEqual(text(of: joined), "First paragraph.Second paragraph has bold words inside it.")
        XCTAssertEqual(joined.runs.first { $0.text == "bold words" }?.marks.map(\.key), ["bold"], "marks survive")
        XCTAssertEqual(
            session.textView.selectedRange, NSRange(location: try caret(session, Self.firstID, 16), length: 0))
        XCTAssertEqual(session.engine.revision, 1)
        XCTAssertNil(session.input?.noticeKey)
        XCTAssertFalse(recorder.didReset)
        try assertConsistent(harness, localCommands: 1)
    }

    func testBackspaceJoinsAParagraphIntoAHeading() throws {
        let harness = try makeHarness([heading("heading", "Heading"), paragraph("body", "Body")])
        defer { harness.close() }
        let session = harness.session
        try place(session, "body", 0)
        session.textView.deleteBackward()

        XCTAssertEqual(session.surface.blocks.map(\.id), ["heading"])
        let joined = try block(session, "heading")
        XCTAssertEqual(joined.node, "heading")
        XCTAssertEqual(text(of: joined), "HeadingBody")
        XCTAssertEqual(session.textView.selectedRange.location, try caret(session, "heading", 7))
        try assertConsistent(harness, localCommands: 1)
    }

    /// An empty paragraph above with the same props is removed instead; the
    /// source keeps its id and the caret stays at its start.
    func testBackspaceAfterAnEmptyParagraphRemovesIt() throws {
        let harness = try makeHarness([paragraph("empty", ""), paragraph("body", "Body")])
        defer { harness.close() }
        let session = harness.session
        try place(session, "body", 0)
        session.textView.deleteBackward()

        XCTAssertEqual(session.surface.blocks.map(\.id), ["body"])
        XCTAssertEqual(session.textView.selectedRange.location, try caret(session, "body", 0))
        try assertConsistent(harness, localCommands: 1)
    }

    /// BlockNote's Backspace at a heading or list item start resets it to a
    /// paragraph (even the first block); only a paragraph joins.
    func testBackspaceAtAHeadingOrListItemStartResetsItToAParagraph() throws {
        let harness = try makeHarness([heading("heading", "Title"), listItem("checkListItem", "item", "Task")])
        defer { harness.close() }
        let session = harness.session
        for (count, id) in [(1, "heading"), (2, "item")] {
            try place(session, id, 0)
            session.textView.deleteBackward()
            XCTAssertEqual(harness.log.commands.last?.kind, .join)
            XCTAssertEqual(try block(session, id).node, "paragraph")
            XCTAssertEqual(session.surface.blocks.count, 2)
            XCTAssertEqual(session.textView.selectedRange.location, try caret(session, id, 0))
            try assertConsistent(harness, localCommands: count)
        }
    }

    func testBackspaceAtTheFirstParagraphAndAroundAnOpaqueBlockIsAQuietNoOp() throws {
        let table = BlockNoteBlock(node: "table", props: [], runs: [], id: "table")
        let harness = try makeHarness([
            paragraph("first", "First"), table, paragraph("second", "Second"), paragraph("third", "Third"),
        ])
        defer { harness.close() }
        let session = harness.session
        let original = session.textView.textStorage.string
        for id in ["first", "table", "second"] {
            try place(session, id, 0)
            session.textView.deleteBackward()
        }
        XCTAssertTrue(harness.log.commands.isEmpty)
        XCTAssertEqual(session.textView.textStorage.string, original)
        XCTAssertNil(session.input?.noticeKey, "an unsupported join is a quiet no-op")
        XCTAssertEqual(session.engine.revision, 0)
        // Return in a placeholder is refused with a notice, never written.
        try place(session, "table", 0)
        session.textView.insertText("\n")
        XCTAssertEqual(session.input?.noticeKey, .native_editor_input_unavailable)
        XCTAssertTrue(harness.log.commands.isEmpty)

        // The same Backspace between text blocks joins.
        try place(session, "third", 0)
        session.textView.deleteBackward()
        XCTAssertEqual(text(of: try block(session, "second")), "SecondThird")
        XCTAssertNil(session.input?.noticeKey)
        try assertConsistent(harness, localCommands: 1)
    }

    /// A toggle heading projects opaque and `splitBlock` refuses it: Return is
    /// refused before the command is armed, through the view and the engine.
    func testReturnInAToggleHeadingIsRefusedWithoutFreezing() throws {
        let toggle = BlockNoteBlock(
            node: "heading", props: Self.paragraphProps + [("level", .int(1)), ("isToggleable", .bool(true))],
            runs: [InlineRun("Toggle")], id: "toggle")
        let harness = try makeHarness([toggle, paragraph("body", "Body")])
        defer { harness.close() }
        let session = harness.session
        XCTAssertTrue(try block(session, "toggle").isOpaque)
        try place(session, "toggle", 0)
        session.textView.insertText("\n")
        XCTAssertEqual(session.input?.noticeKey, .native_editor_input_unavailable)
        for kind: NativeEditCommand.Kind in [.split(offset: 3, newID: "new"), .join] {
            XCTAssertThrowsError(
                try session.engine.applyStructural(
                    NativeEditCommand(id: UUID(), baseRevision: 0, blockID: "toggle", kind: kind)
                ) { _ in XCTFail("a refusal must not persist") }
            ) { XCTAssertEqual($0 as? DocumentEngineError, .unsupportedNativeInput) }
        }
        XCTAssertEqual(session.engine.revision, 0)
        // Typing elsewhere still works: nothing froze.
        try place(session, "body", 0)
        session.textView.insertText("x")
        XCTAssertEqual(text(of: try block(session, "body")), "xBody")
        try assertConsistent(harness, localCommands: 1)
    }

    // MARK: - Concurrency, IME and scroll

    /// A peer that never saw the split edits the same block; its durable
    /// remote entry converges, and the join afterwards is still one command.
    func testPeerEditInTheSameBlockConverges() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let session = harness.session
        try place(session, Self.firstID, 5)
        session.textView.insertText("\n")
        let id = newID(harness)
        try assertConsistent(harness, localCommands: 1)

        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        let writer = BlockNoteWriter(doc: peer)
        try session.integrateServerState(try writer.replaceText(block: Self.firstID, range: 16..<16, with: "!"))
        try session.integrateServerState(try writer.replaceText(block: Self.firstID, range: 0..<0, with: "Peer "))
        XCTAssertEqual(text(of: try block(session, Self.firstID)), "Peer First!")
        XCTAssertEqual(text(of: try block(session, id)), " paragraph.")
        try assertConsistent(harness, localCommands: 1)

        try place(session, id, 0)
        session.textView.deleteBackward()
        XCTAssertEqual(text(of: try block(session, Self.firstID)), "Peer First! paragraph.")
        XCTAssertEqual(session.textView.selectedRange.location, try caret(session, Self.firstID, 11))
        XCTAssertEqual(session.engine.revision, 4)
        try assertConsistent(harness, localCommands: 2)
    }

    func testReturnThenImmediateCompositionCommitsInTheNewBlock() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let session = harness.session
        try place(session, Self.firstID, 16)
        session.textView.insertText("\n")
        let id = newID(harness)
        try assertConsistent(harness, localCommands: 1)

        // The new block is empty (no XmlText yet) and a valid composition target.
        session.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertEqual(session.input?.composition.isActive, true)
        session.textView.unmarkText()

        XCTAssertEqual(harness.log.commands.last?.blockID, id)
        XCTAssertEqual(harness.log.commands.last?.kind, .replace(range: 0..<0, replacement: "に"))
        XCTAssertEqual(text(of: try block(session, id)), "に")
        XCTAssertEqual(session.engine.revision, 2)
        // Typing continues in the new block after the commit.
        session.textView.insertText("x")
        XCTAssertEqual(text(of: try block(session, id)), "にx")
        try assertConsistent(harness, localCommands: 3)
    }

    func testReturnWhileMarkedCommitsTheCompositionAndDoesNotSplit() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let session = harness.session
        try place(session, Self.firstID, 5)
        session.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertEqual(session.input?.composition.isActive, true)
        session.textView.insertText("\n")

        XCTAssertEqual(session.input?.composition.isActive, false)
        XCTAssertEqual(harness.log.commands.first?.kind, .replace(range: 5..<5, replacement: "に"))
        XCTAssertEqual(session.surface.blocks.count, 3, "never split mid-composition")
        XCTAssertEqual(text(of: try block(session, Self.firstID)), "Firstに paragraph.")
        try assertConsistent(harness, localCommands: 1)
    }

    /// Return and Backspace edit the visible slice only: the scroll offset of a
    /// laid-out view stays where the reader left it.
    func testReturnAndBackspaceKeepTheScrollPosition() throws {
        let blocks = (0..<200).map { paragraph("p\($0)", "Paragraph \($0) has enough words to wrap on a phone line.") }
        let harness = try makeHarness(blocks)
        defer { harness.close() }
        let session = harness.session
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        session.textView.frame = window.bounds
        window.addSubview(session.textView)
        window.isHidden = false
        defer { window.isHidden = true }
        session.textView.layoutIfNeeded()
        session.textView.setContentOffset(CGPoint(x: 0, y: 2_000), animated: false)
        session.textView.layoutIfNeeded()
        let before = session.textView.contentOffset.y
        XCTAssertEqual(before, 2_000, accuracy: 1)
        // A block in the middle of the viewport.
        let visible = try XCTUnwrap(session.textView.closestPosition(to: CGPoint(x: 60, y: before + 300)))
        let location = session.textView.offset(from: session.textView.beginningOfDocument, to: visible)
        let id = try XCTUnwrap(session.surface.rangeIndex.entry(atUTF16: location)).blockID
        let original = text(of: try block(session, id))

        try place(session, id, 9)
        session.textView.insertText("\n")
        session.textView.layoutIfNeeded()
        XCTAssertEqual(session.textView.contentOffset.y, before, accuracy: 1)
        session.textView.deleteBackward()
        session.textView.layoutIfNeeded()
        XCTAssertEqual(session.textView.contentOffset.y, before, accuracy: 1)
        XCTAssertEqual(text(of: try block(session, id)), original)
        try assertConsistent(harness, localCommands: 2)
    }

    /// The UI test's key sequence: Return, Return (an empty block above the
    /// moved text), Backspace (that empty block is removed), then typing.
    func testReturnTwiceThenBackspaceRemovesTheEmptyBlock() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let session = harness.session
        try place(session, Self.firstID, 5)
        session.textView.insertText("\n")
        let lower = newID(harness)
        session.textView.insertText("\n")
        XCTAssertEqual(session.surface.blocks.count, 5)
        XCTAssertEqual(session.textView.selectedRange.location, try caret(session, lower, 0))
        session.textView.deleteBackward()
        session.textView.insertText("beta")
        XCTAssertEqual(session.surface.blocks.map { text(of: $0) }.prefix(2), ["First", "beta paragraph."])
        XCTAssertNil(session.input?.noticeKey)
        try assertConsistent(harness, localCommands: 4)
    }

    /// The simulator's software keyboard deletes the separator before the caret
    /// through the delegate (or UITextInput `replace`) instead of `deleteBackward`.
    func testKeyboardSeparatorDeletionAtABlockStartIsTheSameJoin() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let session = harness.session
        let input = try XCTUnwrap(session.input)
        try place(session, Self.secondID, 0)
        let separator = try XCTUnwrap(session.surface.rangeIndex.entry(for: Self.firstID)).separatorRange
        XCTAssertFalse(input.textView(session.textView, shouldChangeTextIn: separator, replacementText: ""))
        XCTAssertEqual(harness.log.commands.map(\.kind), [.join])
        XCTAssertEqual(session.surface.blocks.map(\.id), [Self.firstID, Self.thirdID])
        XCTAssertNil(input.noticeKey)
        try place(session, Self.thirdID, 0)
        let textInputRange = try XCTUnwrap(
            session.textView.textRange(
                from: try XCTUnwrap(
                    session.textView.position(
                        from: session.textView.beginningOfDocument, offset: try caret(session, Self.thirdID, 0) - 1)),
                to: try XCTUnwrap(
                    session.textView.position(
                        from: session.textView.beginningOfDocument, offset: try caret(session, Self.thirdID, 0)))))
        session.textView.replace(textInputRange, withText: "")
        XCTAssertEqual(session.surface.blocks.count, 1)
        XCTAssertNil(input.noticeKey)
        try assertConsistent(harness, localCommands: 2)
    }

    // MARK: - Relaunch

    func testRelaunchReplayEqualsTheProjection() throws {
        let harness = try makeHarness([heading("heading", "Title"), paragraph("body", "Body text")])
        let session = harness.session
        try place(session, "body", 4)
        session.textView.insertText("\n")
        try place(session, "body", 0)
        session.textView.deleteBackward()
        try assertConsistent(harness, localCommands: 2)
        let expected = session.surface.blocks
        let expectedText = session.textView.textStorage.string
        session.close()

        let restored = try XCTUnwrap(NativeEditorSession.restore(store: harness.store, scope: harness.scope))
        defer {
            restored.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }
        XCTAssertEqual(restored.surface.blocks, expected)
        XCTAssertEqual(restored.surface.blocks.map { text(of: $0) }, ["TitleBody", " text"])
        XCTAssertEqual(restored.textView.textStorage.string, expectedText)
        XCTAssertEqual(restored.engine.revision, 2)
    }

    // MARK: - Node oracle (yjs 13.6.33 + BlockNote 0.56.0 captures)

    func testSplitConvergesToTheNodeOracleXML() throws {
        try assertOracle(
            BlockNote056SplitParagraphTests.checkpoints, blockID: "p-c", kind: .split(offset: 5, newID: "1"))
    }

    func testJoinConvergesToTheNodeOracleXML() throws {
        try assertOracle(BlockNote056MergeParagraphsTests.checkpoints, blockID: "p-d-second", kind: .join)
    }

    private func assertOracle(
        _ checkpoints: [(label: String, updateBase64: String, xml: String)], blockID: String,
        kind: NativeEditCommand.Kind
    ) throws {
        let seed = try XCTUnwrap(Data(base64Encoded: checkpoints[0].updateBase64))
        let session = try NativeEditorSession(state: seed)
        defer { session.close() }
        var updates: [Data] = []
        try session.engine.applyStructural(
            NativeEditCommand(id: UUID(), baseRevision: 0, blockID: blockID, kind: kind)
        ) { updates.append($0) }
        XCTAssertEqual(updates.count, 1)

        let replica = YDoc(clientID: 9, gc: false)
        defer { replica.destroy() }
        try replica.applyUpdate(YUpdateDecoder.decode(seed))
        try replica.applyUpdate(YUpdateDecoder.decode(try XCTUnwrap(updates.first)))
        XCTAssertEqual(YXMLString.fragment(replica), checkpoints[1].xml)
        XCTAssertNil(replica.store.pendingStructs)
        XCTAssertNil(replica.store.pendingDs)
    }
}

@MainActor
private final class StructuralPatchRecorder: @preconcurrency EditorSurface {
    let surface: NativeTextSurface
    var patches: [BlockPatch] = []
    var didReset: Bool {
        patches.contains { $0.changes.contains { if case .reset = $0 { true } else { false } } }
    }
    init(_ surface: NativeTextSurface) { self.surface = surface }
    func applyPatch(_ patch: BlockPatch) {
        patches.append(patch)
        surface.applyPatch(patch)
    }
    func setCompositionDeferred(_ deferred: Bool) {
        surface.setCompositionDeferred(deferred)
    }
}
