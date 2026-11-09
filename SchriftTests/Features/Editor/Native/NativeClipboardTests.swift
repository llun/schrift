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
}
