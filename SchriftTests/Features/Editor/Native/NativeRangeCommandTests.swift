import UIKit
import XCTest

@testable import Schrift

/// PR04b: a replacement over a range that may span blocks is one durable
/// command in one grouped transaction (delete the span, join the first and
/// last block, insert the text, newlines splitting blocks), refused before any
/// mutation when it touches a block the editor cannot write.
@MainActor
final class NativeRangeCommandTests: NativeEditingTestCase {
    func testTypingOverForwardAndBackwardMultiBlockSelectionsIsOneCommand() throws {
        for backward in [false, true] {
            let harness = try makeHarness()
            defer { harness.close() }
            let session = harness.session
            let recorder = RangePatchRecorder(session.surface)
            session.engine.surface = recorder
            if backward {
                try select(harness, from: (Self.thirdID, 6), to: (Self.firstID, 6))
            } else {
                try select(harness, from: (Self.firstID, 6), to: (Self.thirdID, 6))
            }
            harness.view.insertText("X")

            let command = try XCTUnwrap(harness.log.commands.first)
            XCTAssertEqual(command.blockID, Self.firstID, "a range command starts at its first block")
            XCTAssertEqual(
                command.kind,
                .range(
                    NativeRangeCommand(
                        startOffset: 6, endBlockID: Self.thirdID, endOffset: 6, replacement: "X", newBlockIDs: [])))
            XCTAssertEqual(session.surface.blocks.map(\.id), [Self.firstID])
            XCTAssertEqual(texts(session), ["First Xparagraph."])
            XCTAssertEqual(harness.view.selectedRange, NSRange(location: 7, length: 0))
            XCTAssertEqual(session.engine.revision, 1)
            XCTAssertNil(harness.input.noticeKey)
            XCTAssertEqual(recorder.patches.count, 1, "one grouped transaction, one stamped emission")
            XCTAssertNotNil(recorder.patches.first?.nativeCommand)
            XCTAssertFalse(recorder.didReset, "slices are reconciled, never the whole storage")
            try assertConsistent(harness, localCommands: 1)
        }
    }

    /// Backspace and Delete over a selection delete it and join the ends;
    /// marks in the moved tail survive. Forward Delete at a block end reaches
    /// the delegate as the separator: the same range join.
    func testBackspaceAndDeleteOverASelectionJoinTheEnds() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let session = harness.session
        try select(harness, from: (Self.firstID, 5), to: (Self.secondID, 6))
        harness.view.deleteBackward()
        XCTAssertEqual(session.surface.blocks.map(\.id), [Self.firstID, Self.thirdID])
        let joined = try block(session, Self.firstID)
        XCTAssertEqual(text(of: joined), "First paragraph has bold words inside it.")
        XCTAssertEqual(joined.runs.first { $0.text == "bold words" }?.marks.map(\.key), ["bold"])
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: 5, length: 0))
        try assertConsistent(harness, localCommands: 1)

        // Forward Delete at the end of the first block.
        let end = try location(session, Self.firstID, text(of: joined).utf16.count)
        setSelection(harness, NSRange(location: end, length: 0))
        let separator = try XCTUnwrap(session.surface.rangeIndex.entry(for: Self.firstID)).separatorRange
        XCTAssertFalse(harness.input.textView(harness.view, shouldChangeTextIn: separator, replacementText: ""))
        XCTAssertEqual(texts(session), ["First paragraph has bold words inside it.Third paragraph."])
        XCTAssertEqual(lastRange(harness)?.endBlockID, Self.thirdID)
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: end, length: 0))
        try assertConsistent(harness, localCommands: 2)
    }

    func testEmojiCombiningCharactersAndRTLKeepWholeCharacters() throws {
        let harness = try makeHarness([
            paragraph("emoji", "a😀b"), paragraph("combining", "e\u{301}x"), paragraph("rtl", "مرحبا بالعالم"),
        ])
        defer { harness.close() }
        let session = harness.session
        // After the emoji (3 UTF-16 units) to after "é" (2 units).
        try select(harness, from: ("emoji", 3), to: ("combining", 2))
        harness.view.insertText("—")
        XCTAssertEqual(texts(session), ["a😀—x", "مرحبا بالعالم"])
        try assertConsistent(harness, localCommands: 1)

        // Backward across the RTL block's first word.
        try select(harness, from: ("rtl", 5), to: ("emoji", 1))
        harness.view.insertText("😀")
        XCTAssertEqual(texts(session), ["a😀 بالعالم"])
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: 3, length: 0))
        try assertConsistent(harness, localCommands: 2)

        // A range endpoint inside a surrogate pair is refused before arming.
        XCTAssertThrowsError(
            try session.engine.applyStructural(
                NativeEditCommand(
                    id: UUID(), baseRevision: 2, blockID: "emoji",
                    kind: .range(
                        NativeRangeCommand(
                            startOffset: 2, endBlockID: "emoji", endOffset: 4, replacement: "x", newBlockIDs: [])))
            ) { _ in XCTFail("a refusal must not persist") }
        ) { XCTAssertEqual($0 as? DocumentEngineError, .unsupportedNativeInput) }
        try assertConsistent(harness, localCommands: 2)
    }

    /// A blank paragraph in the middle, the final paragraph's end, and the
    /// end-of-document boundary as a range's end (never as a caret).
    func testBlankAndFinalParagraphs() throws {
        let harness = try makeHarness([paragraph("a", "Alpha"), paragraph("blank", ""), paragraph("last", "Omega")])
        defer { harness.close() }
        let session = harness.session
        try select(harness, from: ("a", 5), to: ("last", 5))
        harness.view.insertText("!")
        XCTAssertEqual(texts(session), ["Alpha!"])
        try assertConsistent(harness, localCommands: 1)

        harness.view.insertText("\n")
        harness.view.insertText("\n")
        harness.view.insertText("end")
        XCTAssertEqual(texts(session), ["Alpha!", "", "end"])
        try assertConsistent(harness, localCommands: 4)

        // From the blank paragraph through the end of the document.
        let blank = session.surface.blocks[1].id
        setSelection(
            harness,
            NSRange(
                location: try location(session, blank, 0),
                length: harness.view.textStorage.length - (try location(session, blank, 0))))
        harness.view.deleteBackward()
        XCTAssertEqual(session.surface.blocks.map(\.id), [session.surface.blocks[0].id, blank])
        XCTAssertEqual(texts(session), ["Alpha!", ""])
        try assertConsistent(harness, localCommands: 5)

        // Only the last separator: nothing a block owns, refused with a notice.
        setSelection(harness, NSRange(location: harness.view.textStorage.length - 1, length: 1))
        harness.view.deleteBackward()
        XCTAssertEqual(harness.input.noticeKey, .native_editor_input_unavailable)
        try assertConsistent(harness, localCommands: 5)
    }

    /// Return over a selection replaces it with one block break, then an IME
    /// composition starts at once in the new block.
    func testReturnOverASelectionThenImmediateComposition() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let session = harness.session
        try select(harness, from: (Self.firstID, 5), to: (Self.secondID, 6))
        harness.view.insertText("\n")
        let range = try XCTUnwrap(lastRange(harness))
        XCTAssertEqual(range.replacement, "\n")
        let created = try XCTUnwrap(range.newBlockIDs.first)
        XCTAssertEqual(session.surface.blocks.map(\.id), [Self.firstID, created, Self.thirdID])
        XCTAssertEqual(texts(session)[0...1], ["First", " paragraph has bold words inside it."])
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(session, created, 0), length: 0))
        try assertConsistent(harness, localCommands: 1)

        harness.view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertEqual(harness.input.composition.isActive, true)
        harness.view.unmarkText()
        XCTAssertEqual(harness.log.commands.last?.blockID, created)
        XCTAssertEqual(text(of: try block(session, created)), "に paragraph has bold words inside it.")
        harness.view.insertText("x")
        XCTAssertEqual(text(of: try block(session, created)), "にx paragraph has bold words inside it.")
        try assertConsistent(harness, localCommands: 3)
    }

    /// The final dictation result over a selection is one range command; a
    /// dictation correction arrives as UITextInput `replace` and may carry a
    /// line break.
    func testDictationShapedReplacementsAreOneCommand() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let session = harness.session
        try select(harness, from: (Self.firstID, 6), to: (Self.secondID, 7))
        harness.view.insertDictationResult([Phrase("dictated"), Phrase(" words ")])
        XCTAssertEqual(texts(session)[0], "First dictated words paragraph has bold words inside it.")
        try assertConsistent(harness, localCommands: 1)

        let start = try XCTUnwrap(harness.view.position(from: harness.view.beginningOfDocument, offset: 6))
        let end = try XCTUnwrap(
            harness.view.position(
                from: harness.view.beginningOfDocument, offset: try location(session, Self.thirdID, 5)))
        harness.view.replace(try XCTUnwrap(harness.view.textRange(from: start, to: end)), withText: "one\ntwo ")
        let range = try XCTUnwrap(lastRange(harness))
        XCTAssertEqual(range.endBlockID, Self.thirdID)
        XCTAssertEqual(texts(session), ["First one", "two  paragraph."])
        XCTAssertEqual(session.surface.blocks[1].id, range.newBlockIDs.first)
        try assertConsistent(harness, localCommands: 2)
    }

    /// New blocks keep a list item's kind (like Return) and default props;
    /// a heading's lines after the first are paragraphs.
    func testNewLinesTakeTheSplitKindOfTheFirstBlock() throws {
        let harness = try makeHarness([bullet("item", "Item"), heading("title", "Title")])
        defer { harness.close() }
        let session = harness.session
        setSelection(harness, NSRange(location: try location(session, "item", 4), length: 0))
        XCTAssertTrue(harness.input.replace(range: harness.view.selectedRange, with: "\none\ntwo"))
        XCTAssertEqual(
            session.surface.blocks.map(\.node), ["bulletListItem", "bulletListItem", "bulletListItem", "heading"])
        XCTAssertEqual(texts(session), ["Item", "one", "two", "Title"])
        setSelection(harness, NSRange(location: try location(session, "title", 5), length: 0))
        XCTAssertTrue(harness.input.replace(range: harness.view.selectedRange, with: "\r\nbody"))
        XCTAssertEqual(session.surface.blocks.last?.node, "paragraph")
        XCTAssertEqual(texts(session).last, "body")
        try assertConsistent(harness, localCommands: 2)
    }

    /// Every block a range touches is validated before the command is armed:
    /// a placeholder, code, a toggle heading or nested children anywhere
    /// refuses the whole command with a notice, writes nothing and never
    /// freezes the editor.
    func testARangeTouchingAnUnsupportedBlockIsRefusedWithNoWrite() throws {
        var nested = paragraph("parent", "Parent")
        nested.children = [paragraph("child", "Child")]
        let blockers: [BlockNoteBlock] = [
            BlockNoteBlock(node: "table", props: [], runs: [], id: "blocker"),
            BlockNoteBlock(
                node: "codeBlock", props: [("language", .string("swift"))], runs: [InlineRun("let x = 1")],
                id: "blocker"),
            heading("blocker", "Toggle", toggle: true),
            {
                var block = nested
                block.id = "blocker"
                return block
            }(),
        ]
        for blocker in blockers {
            let harness = try makeHarness([paragraph("before", "Before"), blocker, paragraph("after", "After")])
            defer { harness.close() }
            let session = harness.session
            let original = harness.view.textStorage.string
            harness.pasteboard.string = "kept"
            let selections = [
                (("before", 2), ("after", 2)), (("after", 2), ("before", 2)),
            ]
            for (anchor, head) in selections {
                try select(harness, from: anchor, to: head)
                // Typing, Backspace, Return, paste and cut over the range.
                harness.view.insertText("x")
                XCTAssertEqual(harness.input.noticeKey, .native_editor_range_unavailable, blocker.node)
                harness.view.deleteBackward()
                harness.view.insertText("\n")
                harness.view.paste(nil)
                harness.view.cut(nil)
                XCTAssertEqual(harness.pasteboard.string, "kept", "a refused cut leaves the pasteboard")
                XCTAssertTrue(harness.log.commands.isEmpty, blocker.node)
            }
            // An endpoint inside the unsupported block itself.
            setSelection(
                harness,
                NSRange(
                    location: try location(session, "before", 1),
                    length: try location(session, "blocker", 1) - (try location(session, "before", 1))))
            harness.view.insertText("x")
            XCTAssertEqual(harness.view.textStorage.string, original, blocker.node)
            XCTAssertEqual(session.engine.revision, 0)
            // Nothing froze: typing in a supported block still works.
            setSelection(harness, NSRange(location: 0, length: 0))
            harness.view.insertText("y")
            XCTAssertEqual(texts(session).first, "yBefore")
            try assertConsistent(harness, localCommands: 1)
        }
    }

    /// Validation covers a command built by hand too: a stale base, a range
    /// running backwards, a reused or missing id, or an object character.
    func testEngineRefusesMalformedRangeCommandsBeforeArming() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let engine = harness.session.engine
        func command(
            _ start: Int, _ endBlock: String, _ end: Int, _ text: String, _ ids: [String], base: UInt64 = 0
        ) -> NativeEditCommand {
            NativeEditCommand(
                id: UUID(), baseRevision: base, blockID: Self.secondID,
                kind: .range(
                    NativeRangeCommand(
                        startOffset: start, endBlockID: endBlock, endOffset: end, replacement: text,
                        newBlockIDs: ids)))
        }
        for (candidate, expected) in [
            (command(0, Self.firstID, 0, "x", []), DocumentEngineError.unsupportedNativeInput),
            (command(4, Self.secondID, 2, "x", []), .unsupportedNativeInput),
            (command(2, Self.secondID, 2, "", []), .unsupportedNativeInput),
            (command(0, Self.thirdID, 0, "a\nb", []), .unsupportedNativeInput),
            (command(0, Self.thirdID, 0, "a\nb", [Self.firstID]), .unsupportedNativeInput),
            (command(0, Self.thirdID, 0, "a\nb\nc", ["n", "n"]), .unsupportedNativeInput),
            (command(0, Self.thirdID, 0, "a\u{2028}b", []), .unsupportedNativeInput),
            (command(0, Self.thirdID, 0, "\u{fffc}", []), .unsupportedNativeInput),
            (command(0, Self.thirdID, 99, "x", []), .unsupportedNativeInput),
            (command(0, Self.thirdID, 0, "x", [], base: 7), .staleNativeCommand),
        ] {
            XCTAssertThrowsError(try engine.applyStructural(candidate) { _ in XCTFail("refused") }) {
                XCTAssertEqual($0 as? DocumentEngineError, expected)
            }
        }
        XCTAssertFalse(engine.nativeWriteFailed)
        try assertConsistent(harness, localCommands: 0)
    }

    func testRelaunchReplaysRangeCommands() throws {
        let harness = try makeHarness()
        let session = harness.session
        try select(harness, from: (Self.firstID, 6), to: (Self.secondID, 7))
        harness.view.insertText("p")
        try select(harness, from: (Self.thirdID, 5), to: (Self.firstID, 3))
        XCTAssertTrue(harness.input.replace(range: harness.view.selectedRange, with: "1\n2\n"))
        try assertConsistent(harness, localCommands: 2)
        let expected = session.surface.blocks
        let expectedText = harness.view.textStorage.string
        session.close()

        let restored = try XCTUnwrap(NativeEditorSession.restore(store: harness.store, scope: harness.scope))
        defer {
            restored.close()
            UIPasteboard.remove(withName: harness.pasteboard.name)
            try? FileManager.default.removeItem(at: harness.directory)
        }
        XCTAssertEqual(restored.surface.blocks, expected)
        XCTAssertEqual(restored.surface.blocks.map { text(of: $0) }, ["Fir1", "2", " paragraph."])
        XCTAssertEqual(restored.textView.textStorage.string, expectedText)
        XCTAssertEqual(restored.engine.revision, 2)
    }

    // MARK: - Node oracle (yjs 13.6.33 + BlockNote 0.56.0 captures)

    /// Deleting from one paragraph's end to the next one's start is the same
    /// write as BlockNote's Backspace merge.
    func testRangeDeleteAcrossOneSeparatorConvergesToTheMergeOracle() throws {
        try assertOracle(
            BlockNote056MergeParagraphsTests.checkpoints, blockID: "p-d-first",
            range: NativeRangeCommand(
                startOffset: 5, endBlockID: "p-d-second", endOffset: 0, replacement: "", newBlockIDs: []))
    }

    /// A pasted line break at Hello|World is the same write as Enter there.
    func testPastedLineBreakConvergesToTheSplitOracle() throws {
        try assertOracle(
            BlockNote056SplitParagraphTests.checkpoints, blockID: "p-c",
            range: NativeRangeCommand(
                startOffset: 5, endBlockID: "p-c", endOffset: 5, replacement: "\n", newBlockIDs: ["1"]))
    }

    private func assertOracle(
        _ checkpoints: [(label: String, updateBase64: String, xml: String)], blockID: String,
        range: NativeRangeCommand
    ) throws {
        let seed = try XCTUnwrap(Data(base64Encoded: checkpoints[0].updateBase64))
        let session = try NativeEditorSession(state: seed)
        defer { session.close() }
        var updates: [Data] = []
        try session.engine.applyStructural(
            NativeEditCommand(id: UUID(), baseRevision: 0, blockID: blockID, kind: .range(range))
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

/// A final dictation phrase; UIKit's own initializer leaves `text` empty.
private final class Phrase: UIDictationPhrase {
    private let value: String
    init(_ value: String) {
        self.value = value
        super.init()
    }
    override var text: String { value }
}

@MainActor
private final class RangePatchRecorder: @preconcurrency EditorSurface {
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
