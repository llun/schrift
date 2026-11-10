import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import Schrift

/// PR04b's plain-text clipboard, through the view's own `copy:`/`cut:`/
/// `paste:` actions: copy is one line per block and writes nothing; cut is copy
/// plus one range delete; paste is one command, newlines splitting blocks, and
/// rich content contributes only its plain text.
@MainActor
final class NativeClipboardTests: NativeEditingTestCase {
    func testCopyGivesOneLinePerBlockInEitherDirection() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        for (anchor, head) in [((Self.firstID, 6), (Self.thirdID, 5)), ((Self.thirdID, 5), (Self.firstID, 6))] {
            try select(harness, from: anchor, to: head)
            harness.view.copy(nil)
            XCTAssertEqual(harness.pasteboard.string, "paragraph.\nSecond paragraph has bold words inside it.\nThird")
        }
        // From a block's end to the next block's start: one line break.
        let end = try location(harness.session, Self.firstID, 16)
        setSelection(harness, NSRange(location: end, length: 1))
        harness.view.copy(nil)
        XCTAssertEqual(harness.pasteboard.string, "\n")
        // Through the end of the document: the last block's text, no trailing break.
        setSelection(harness, NSRange(location: 0, length: harness.view.textStorage.length))
        harness.view.copy(nil)
        XCTAssertEqual(
            harness.pasteboard.string,
            "First paragraph.\nSecond paragraph has bold words inside it.\nThird paragraph.")
        try assertConsistent(harness, localCommands: 0)
    }

    func testCopySkipsPreservedPlaceholdersAndKeepsEmojiCombiningAndRTL() throws {
        let harness = try makeHarness([
            paragraph("a", "a😀e\u{301}"), BlockNoteBlock(node: "table", props: [], runs: [], id: "table"),
            paragraph("rtl", "مرحبا"), paragraph("blank", ""),
        ])
        defer { harness.close() }
        setSelection(harness, NSRange(location: 1, length: harness.view.textStorage.length - 1))
        harness.view.copy(nil)
        XCTAssertEqual(harness.pasteboard.string, "😀e\u{301}\nمرحبا\n")
        try assertConsistent(harness, localCommands: 0)
    }

    /// Nothing copyable (only a placeholder) leaves the pasteboard alone.
    func testCopyingOnlyAPlaceholderKeepsThePasteboard() throws {
        let harness = try makeHarness([
            paragraph("a", "Alpha"), BlockNoteBlock(node: "table", props: [], runs: [], id: "table"),
        ])
        defer { harness.close() }
        harness.pasteboard.string = "kept"
        let table = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "table"))
        setSelection(harness, NSRange(location: table.textRange.location + 1, length: 3))
        harness.view.copy(nil)
        harness.view.cut(nil)
        XCTAssertEqual(harness.pasteboard.string, "kept")
        try assertConsistent(harness, localCommands: 0)
    }

    /// While text is marked, storage offsets do not match the model: copy,
    /// like cut and paste, does nothing.
    func testCopyDuringCompositionDoesNothing() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        harness.pasteboard.string = "kept"
        setSelection(harness, NSRange(location: 2, length: 0))
        harness.view.setMarkedText("にほん", selectedRange: NSRange(location: 0, length: 3))
        XCTAssertEqual(harness.input.composition.isActive, true)
        XCTAssertEqual(harness.view.selectedRange.length, 3)
        harness.view.copy(nil)
        harness.view.cut(nil)
        harness.view.paste(nil)
        XCTAssertEqual(harness.pasteboard.string, "kept")
        harness.view.unmarkText()
        try assertConsistent(harness, localCommands: 1)
    }

    /// A paste over either bound is refused whole with a notice; nothing is
    /// written, not even its first lines.
    func testAnOversizedPasteIsRefusedWhole() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let original = harness.view.textStorage.string
        setSelection(harness, NSRange(location: 2, length: 0))
        for text in [
            Array(repeating: "line", count: NativeClipboard.maxPasteLines + 1).joined(separator: "\r\n"),
            String(repeating: "x", count: NativeClipboard.maxPasteUTF16 + 1),
        ] {
            harness.pasteboard.string = text
            harness.view.paste(nil)
            XCTAssertEqual(harness.input.noticeKey, .native_editor_paste_too_large)
            XCTAssertEqual(harness.view.textStorage.string, original)
        }
        try assertConsistent(harness, localCommands: 0)
        // At the line bound it is one command.
        harness.pasteboard.string = Array(repeating: "l", count: NativeClipboard.maxPasteLines).joined(separator: "\n")
        harness.view.paste(nil)
        XCTAssertNil(harness.input.noticeKey)
        XCTAssertEqual(harness.session.surface.blocks.count, 3 + NativeClipboard.maxPasteLines - 1)
        try assertConsistent(harness, localCommands: 1)
    }

    func testCutIsCopyPlusOneRangeDelete() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let session = harness.session
        try select(harness, from: (Self.secondID, 7), to: (Self.firstID, 6))
        harness.view.cut(nil)
        XCTAssertEqual(harness.pasteboard.string, "paragraph.\nSecond ")
        XCTAssertEqual(texts(session), ["First paragraph has bold words inside it.", "Third paragraph."])
        XCTAssertEqual(lastRange(harness)?.replacement, "")
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: 6, length: 0))
        try assertConsistent(harness, localCommands: 1)
    }

    /// Multi-line paste over a selection is one command; newlines (CRLF too)
    /// split blocks and the last line takes the selection's tail.
    func testMultiLinePasteOverASelectionIsOneCommand() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let session = harness.session
        try select(harness, from: (Self.firstID, 6), to: (Self.secondID, 7))
        harness.pasteboard.string = "one\r\ntwo\n\nthree "
        harness.view.paste(nil)
        let range = try XCTUnwrap(lastRange(harness))
        XCTAssertEqual(range.replacement, "one\ntwo\n\nthree ")
        XCTAssertEqual(range.newBlockIDs.count, 3)
        XCTAssertEqual(session.surface.blocks.map(\.id), [Self.firstID] + range.newBlockIDs + [Self.thirdID])
        XCTAssertEqual(
            texts(session), ["First one", "two", "", "three paragraph has bold words inside it.", "Third paragraph."])
        let last = try block(session, try XCTUnwrap(range.newBlockIDs.last))
        XCTAssertEqual(last.runs.first { $0.text == "bold words" }?.marks.map(\.key), ["bold"], "the tail keeps marks")
        XCTAssertEqual(
            harness.view.selectedRange,
            NSRange(location: try location(session, try XCTUnwrap(range.newBlockIDs.last), 6), length: 0))
        try assertConsistent(harness, localCommands: 1)
    }

    /// Copy then paste at a caret rebuilds the copied structure; a single
    /// pasted line inside one block is ordinary typing.
    func testCopyThenPasteAtACaretRoundTrips() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let session = harness.session
        try select(harness, from: (Self.firstID, 0), to: (Self.secondID, 6))
        harness.view.copy(nil)
        setSelection(harness, NSRange(location: try location(session, Self.thirdID, 16), length: 0))
        harness.view.paste(nil)
        XCTAssertEqual(texts(session).suffix(2), ["Third paragraph.First paragraph.", "Second"])
        try assertConsistent(harness, localCommands: 1)

        harness.pasteboard.string = " pasted"
        harness.view.paste(nil)
        XCTAssertEqual(texts(session).last, "Second pasted")
        XCTAssertEqual(harness.log.commands.last?.kind, .replace(range: 6..<6, replacement: " pasted"))
        try assertConsistent(harness, localCommands: 2)
    }

    /// Rich content on the pasteboard contributes only its plain text: the
    /// pasted runs carry the marks at the caret, never the source's styles.
    func testRichPasteTakesOnlyThePlainText() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let session = harness.session
        let rich = NSAttributedString(
            string: "Rich\ntext", attributes: [.font: UIFont.boldSystemFont(ofSize: 30), .foregroundColor: UIColor.red])
        let rtf = try rich.data(
            from: NSRange(location: 0, length: rich.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        harness.pasteboard.setItems([
            [UTType.rtf.identifier: rtf, UTType.utf8PlainText.identifier: "Rich\ntext"]
        ])
        setSelection(harness, NSRange(location: try location(session, Self.firstID, 5), length: 0))
        harness.view.paste(nil)
        XCTAssertEqual(texts(session)[0...1], ["FirstRich", "text paragraph."])
        XCTAssertTrue(session.surface.blocks[0...1].allSatisfy { $0.runs.allSatisfy(\.marks.isEmpty) })
        try assertConsistent(harness, localCommands: 1)
    }

    /// The view's edit actions route exactly once: UIKit never applies a
    /// paste or a cut itself, and an empty pasteboard is a no-op.
    func testEditActionsRouteOnceAndNeverThroughUIKit() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let session = harness.session
        harness.pasteboard.items = []
        setSelection(harness, NSRange(location: 2, length: 0))
        harness.view.paste(nil)
        harness.view.cut(nil)
        harness.view.copy(nil)
        XCTAssertNil(harness.pasteboard.string)
        try assertConsistent(harness, localCommands: 0)

        harness.pasteboard.string = "a\nb"
        harness.view.pasteAndMatchStyle(nil)
        XCTAssertEqual(texts(session)[0...1], ["Fia", "brst paragraph."])
        try assertConsistent(harness, localCommands: 1)
    }

    // MARK: - PR06d lossless subtrees

    private var payloadType: String { BlockNoteSubtreePayload.pasteboardType }

    private func nested(_ block: BlockNoteBlock, _ children: [BlockNoteBlock]) -> BlockNoteBlock {
        var block = block
        block.children = children
        return block
    }

    private func caret(_ harness: Harness, _ id: String, _ offset: Int) throws {
        setSelection(harness, NSRange(location: try location(harness.session, id, offset), length: 0))
    }

    /// A bullet with an unknown mark, a link and an unknown prop over two
    /// nested levels, then an empty paragraph.
    private func richSeed() -> [BlockNoteBlock] {
        var rich = bullet("b", "")
        rich.runs = [
            InlineRun("Plain "), InlineRun("custom", marks: [("x-custom", #"{"v":1}"#), ("bold", "{}")]),
            InlineRun(" link", marks: [("link", #"{"href":"https://example.test/"}"#)]),
        ]
        rich.props += [("x-extra", .string("kept"))]
        return [
            paragraph("a", "Alpha"), nested(rich, [nested(bullet("b1", "Child"), [paragraph("b11", "Deep")])]),
            paragraph("c", "Gamma"), paragraph("empty", ""),
        ]
    }

    /// Copy block puts the lossless payload beside the plain text; a paste at
    /// a caret is one command inserting the subtree with fresh ids after the
    /// caret's block, or in place of an empty paragraph. Byte-identical
    /// payloads (only the ids differ) prove the round trip lossless.
    func testCopyBlockThenPasteRoundTripsLosslesslyWithFreshIDs() throws {
        let harness = try makeHarness(richSeed())
        defer { harness.close() }
        let session = harness.session
        try caret(harness, "b", 0)
        XCTAssertTrue(harness.input.performBlockAction(.copy))
        let copied = try XCTUnwrap(harness.pasteboard.data(forPasteboardType: payloadType))
        XCTAssertEqual(copied, session.engine.subtreePayload(["b"]))
        XCTAssertEqual(harness.pasteboard.string, "Plain custom link\nChild\nDeep")
        try assertConsistent(harness, localCommands: 0)

        try caret(harness, "c", 2)
        harness.view.paste(nil)
        guard case .insertSubtrees(let payload, let newIDs)? = harness.log.commands.last?.kind else {
            return XCTFail("not a lossless paste")
        }
        XCTAssertEqual(payload, copied)
        XCTAssertEqual(newIDs.count, 3)
        XCTAssertEqual(session.surface.blocks.map(\.id), ["a", "b", "b1", "b11", "c"] + newIDs + ["empty"])
        XCTAssertEqual(session.surface.blocks.map(\.depth), [0, 0, 1, 2, 0, 0, 1, 2, 0])
        var fresh = newIDs[...]
        let original = try XCTUnwrap(try BlockNoteSubtreePayload.decode(copied).first)
        let expected = try BlockNoteSubtreePayload.encode([original.replacingIDs(&fresh)])
        XCTAssertEqual(session.engine.subtreePayload([newIDs[0]]), expected, "every raw value, mark and prop")
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(session, newIDs[2], 4), length: 0))
        try assertConsistent(harness, localCommands: 1)

        try caret(harness, "empty", 0)
        harness.view.paste(nil)
        guard case .insertSubtrees(_, let second)? = harness.log.commands.last?.kind else {
            return XCTFail("not a lossless paste")
        }
        XCTAssertTrue(Set(second).isDisjoint(with: newIDs), "every paste mints fresh ids")
        XCTAssertEqual(session.surface.blocks.map(\.id).suffix(4), [newIDs[2]] + second, "the empty block is replaced")
        try assertConsistent(harness, localCommands: 2)
    }

    /// A selection of whole sibling subtrees copies them losslessly; part of
    /// a block, or a block whose visible children are left out, is plain only.
    func testOnlyWholeSubtreeSelectionsCarryAPayload() throws {
        let harness = try makeHarness(richSeed())
        defer { harness.close() }
        let session = harness.session
        try select(harness, from: ("b", 0), to: ("b11", 4))
        harness.view.copy(nil)
        XCTAssertEqual(harness.pasteboard.data(forPasteboardType: payloadType), session.engine.subtreePayload(["b"]))
        try select(harness, from: ("c", 5), to: ("a", 0))
        harness.view.copy(nil)
        XCTAssertEqual(
            harness.pasteboard.data(forPasteboardType: payloadType), session.engine.subtreePayload(["a", "b", "c"]))
        for (anchor, head) in [(("a", 1), ("c", 5)), (("b", 0), ("b", 17)), (("b1", 0), ("c", 5))] {
            try select(harness, from: anchor, to: head)
            harness.view.copy(nil)
            XCTAssertNotNil(harness.pasteboard.string)
            XCTAssertNil(harness.pasteboard.data(forPasteboardType: payloadType), "\(anchor)–\(head): plain only")
        }
        try assertConsistent(harness, localCommands: 0)
    }

    /// A folded toggle's title copies with its hidden children.
    func testCopyingAFoldedToggleCarriesItsHiddenChildren() throws {
        let toggle = BlockNoteBlock(
            node: "toggleListItem", props: Self.paragraphProps, runs: [InlineRun("Title")], id: "t",
            children: [paragraph("c1", "Hidden one"), paragraph("c2", "Hidden two")])
        let harness = try makeHarness([toggle, paragraph("x", "After")])
        defer { harness.close() }
        try select(harness, from: ("t", 0), to: ("t", 5))
        harness.view.copy(nil)
        XCTAssertEqual(harness.pasteboard.string, "Title")
        let payload = try XCTUnwrap(harness.pasteboard.data(forPasteboardType: payloadType))
        XCTAssertEqual(try BlockNoteSubtreePayload.decode(payload).first?.containerCount, 3)
        try assertConsistent(harness, localCommands: 0)
    }

    private func pasteRefused(
        _ harness: Harness, _ payload: Data, notice: L10nKey, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let before = texts(harness.session)
        harness.pasteboard.setItems([[payloadType: payload, UTType.utf8PlainText.identifier: "plain"]])
        harness.view.paste(nil)
        XCTAssertEqual(harness.input.noticeKey, notice, file: file, line: line)
        XCTAssertEqual(
            texts(harness.session), before, "nothing written, not even the plain text", file: file, line: line)
    }

    /// The payload is untrusted: garbage, a node BlockNote cannot hold, a
    /// container without an id and nesting past the bound are refused whole,
    /// by the coordinator and again by the engine.
    func testMalformedPayloadsAreRefusedWithoutAWrite() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let session = harness.session
        try caret(harness, Self.firstID, 2)
        var deep = paragraph("d17", "Deep")
        for level in (0..<17).reversed() { deep = nested(paragraph("d\(level)", "L\(level)"), [deep]) }
        let malformed = [
            Data([1, 2, 3]),
            BlockNoteYjs.encode([BlockNoteBlock(node: "fancyWidget", props: [], runs: [], id: "w")], clientID: 7),
            BlockNoteYjs.encode([paragraph("", "No id")], clientID: 7),
            BlockNoteYjs.encode([deep], clientID: 7),
        ]
        for payload in malformed {
            try pasteRefused(harness, payload, notice: .native_editor_paste_unavailable)
            XCTAssertThrowsError(
                try session.engine.applyStructural(
                    NativeEditCommand(
                        id: UUID(), baseRevision: session.engine.revision, blockID: Self.firstID,
                        kind: .insertSubtrees(payload: payload, newIDs: (0..<18).map { "n\($0)" }))
                ) { _ in XCTFail("refused before any write") }
            ) { XCTAssertEqual($0 as? DocumentEngineError, .unsupportedNativeInput) }
        }
        // A well-formed payload with the wrong number of ids is refused too.
        let one = BlockNoteYjs.encode([paragraph("p", "One")], clientID: 7)
        XCTAssertThrowsError(
            try session.engine.applyStructural(
                NativeEditCommand(
                    id: UUID(), baseRevision: session.engine.revision, blockID: Self.firstID,
                    kind: .insertSubtrees(payload: one, newIDs: ["x", "y"]))
            ) { _ in XCTFail("refused before any write") })
        try assertConsistent(harness, localCommands: 0)
        // A valid foreign payload (BlockNote's own document encoding) pastes.
        harness.pasteboard.setItems([[payloadType: one]])
        harness.view.paste(nil)
        XCTAssertEqual(texts(session)[1], "One")
        try assertConsistent(harness, localCommands: 1)
    }

    func testOversizedPayloadsAreRefusedWhole() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        try caret(harness, Self.firstID, 2)
        try pasteRefused(
            harness, Data(count: BlockNoteSubtreePayload.maxBytes + 1), notice: .native_editor_paste_too_large)
        let many = (0...BlockNoteSubtreePayload.maxBlocks).map { paragraph("p\($0)", "P") }
        try pasteRefused(harness, BlockNoteYjs.encode(many, clientID: 7), notice: .native_editor_paste_too_large)
        try assertConsistent(harness, localCommands: 0)
    }

    /// Over a selection the plain text replaces it, as one range command.
    func testAPayloadOverASelectionPastesThePlainText() throws {
        let harness = try makeHarness(richSeed())
        defer { harness.close() }
        let session = harness.session
        try caret(harness, "b1", 0)
        XCTAssertTrue(harness.input.performBlockAction(.copy))
        try select(harness, from: ("c", 1), to: ("c", 3))
        harness.view.paste(nil)
        XCTAssertEqual(text(of: try block(session, "c")), "GChild")
        guard case .range? = harness.log.commands.last?.kind else { return XCTFail("not a plain range paste") }
        try assertConsistent(harness, localCommands: 1)
    }
}
