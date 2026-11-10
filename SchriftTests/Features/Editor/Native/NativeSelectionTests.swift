import UIKit
import XCTest

@testable import Schrift

/// PR04b: the native selection is kept as directed engine relative positions
/// across blocks. It survives peer edits and rebuilds with affinity, and falls
/// back visibly to the nearest surviving block when its target disappears.
@MainActor
final class NativeSelectionTests: NativeEditingTestCase {
    private func selection(_ harness: Harness) async -> EditorSelection? {
        await harness.engine { try? $0.currentSelection() } ?? nil
    }

    func testForwardAndBackwardSelectionsAcrossBlocksAreDirected() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        try select(harness, from: (Self.firstID, 6), to: (Self.thirdID, 5))
        await harness.settle()
        let forwardSelection = await selection(harness)
        XCTAssertEqual(
            forwardSelection,
            EditorSelection(
                anchor: EditorPosition(blockID: Self.firstID, offset: 6, assoc: 0),
                head: EditorPosition(blockID: Self.thirdID, offset: 5, assoc: -1)))

        try select(harness, from: (Self.thirdID, 5), to: (Self.firstID, 6))
        await harness.settle()
        let backwardSelection = await selection(harness)
        XCTAssertEqual(
            backwardSelection,
            EditorSelection(
                anchor: EditorPosition(blockID: Self.thirdID, offset: 5, assoc: -1),
                head: EditorPosition(blockID: Self.firstID, offset: 6, assoc: 0)))
        XCTAssertTrue(harness.input.selection.isBackward)
        try await assertConsistent(harness, localCommands: 0)
    }

    /// The sequence of ranges hardware Shift-arrows produce, one character at
    /// a time across a separator: forward from a caret, then backward from a
    /// caret, each typed over as one command.
    func testShiftArrowStepsAcrossASeparator() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let end = try location(session, Self.firstID, 14)
        for length in 0...4 { setSelection(harness, NSRange(location: end, length: length)) }
        await harness.settle()
        let anchor1 = await selection(harness)?.anchor
        let head1 = await selection(harness)?.head
        XCTAssertEqual(anchor1, EditorPosition(blockID: Self.firstID, offset: 14, assoc: 0))
        XCTAssertEqual(head1, EditorPosition(blockID: Self.secondID, offset: 1, assoc: -1))
        harness.view.insertText("Z")
        await harness.settle()
        XCTAssertEqual(texts(session)[0], "First paragrapZecond paragraph has bold words inside it.")
        try await assertConsistent(harness, localCommands: 1)

        let caret = try location(session, Self.thirdID, 2)
        for length in 0...4 { setSelection(harness, NSRange(location: caret - length, length: length)) }
        await harness.settle()
        let anchor2 = await selection(harness)?.anchor
        let head2 = await selection(harness)?.head.blockID
        XCTAssertEqual(anchor2, EditorPosition(blockID: Self.thirdID, offset: 2, assoc: -1))
        XCTAssertEqual(head2, Self.firstID)
        XCTAssertTrue(harness.input.selection.isBackward)
        // Shift-Right shrinks the backward selection from its head.
        setSelection(harness, NSRange(location: caret - 3, length: 3))
        await harness.settle()
        XCTAssertTrue(harness.input.selection.isBackward)
        harness.view.deleteBackward()
        await harness.settle()
        XCTAssertEqual(texts(session), ["First paragrapZecond paragraph has bold words inside it.ird paragraph."])
        try await assertConsistent(harness, localCommands: 2)
    }

    /// Text a peer inserts at either boundary stays outside a non-empty
    /// selection; text inside it moves with it. The view follows.
    func testSelectionSurvivesPeerEditsWithAffinity() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try select(harness, from: (Self.firstID, 6), to: (Self.secondID, 6))
        await harness.settle()
        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        let writer = BlockNoteWriter(doc: peer)
        try await session.integrateServerState(try writer.replaceText(block: Self.firstID, range: 6..<6, with: "<"))
        try await session.integrateServerState(try writer.replaceText(block: Self.secondID, range: 6..<6, with: ">"))
        try await session.integrateServerState(try writer.replaceText(block: Self.firstID, range: 0..<0, with: "Peer "))
        XCTAssertEqual(
            texts(session)[0...1], ["Peer First <paragraph.", "Second> paragraph has bold words inside it."])
        let start = try location(session, Self.firstID, 12)
        let endLoc = try location(session, Self.secondID, 6)
        XCTAssertEqual(
            harness.view.selectedRange,
            NSRange(location: start, length: endLoc - start))
        harness.view.insertText("-")
        await harness.settle()
        XCTAssertEqual(texts(session)[0], "Peer First <-> paragraph has bold words inside it.")
        try await assertConsistent(harness, localCommands: 1)
    }

    /// A peer typing in a block after the selection never sets the view's
    /// selection (that would end a handle drag in progress). An edit before it
    /// moves its document offsets, which UIKit does not follow: the restore
    /// sets it once to keep it on the same text.
    func testAPeerEditAfterTheSelectionNeverSetsTheViewSelection() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try select(harness, from: (Self.secondID, 2), to: (Self.secondID, 9))
        await harness.settle()
        let selected = (harness.view.textStorage.string as NSString).substring(with: harness.view.selectedRange)
        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        let writer = BlockNoteWriter(doc: peer)
        try await session.integrateServerState(
            try writer.replaceText(block: Self.thirdID, range: 0..<0, with: "after "))
        XCTAssertEqual(texts(session)[2], "after Third paragraph.")
        XCTAssertEqual(harness.input.selection.restoredSelections, 0, "an edit after the selection never sets it")
        try await session.integrateServerState(
            try writer.replaceText(block: Self.firstID, range: 0..<0, with: "before "))
        XCTAssertEqual(harness.input.selection.restoredSelections, 1)
        XCTAssertEqual(
            (harness.view.textStorage.string as NSString).substring(with: harness.view.selectedRange), selected)
        let loc = try location(session, Self.secondID, 2)
        XCTAssertEqual(harness.view.selectedRange.location, loc)
    }

    /// A peer splits the selected block: the end in the moved text resolves to
    /// the split point, so the selection stays in the kept block.
    func testSelectionAfterARemoteSplit() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try select(harness, from: (Self.firstID, 2), to: (Self.firstID, 10))
        await harness.settle()
        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        try await session.integrateServerState(
            try BlockNoteWriter(doc: peer).splitBlock(block: Self.firstID, at: 5, newID: "peer-split"))
        XCTAssertEqual(texts(session)[0...1], ["First", " paragraph."])
        let sel = await selection(harness)
        XCTAssertEqual(
            sel,
            EditorSelection(
                anchor: EditorPosition(blockID: Self.firstID, offset: 2, assoc: 0),
                head: EditorPosition(blockID: Self.firstID, offset: 5, assoc: -1)))
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: 2, length: 3))
        harness.view.insertText("x")
        await harness.settle()
        XCTAssertEqual(texts(session)[0], "Fix")
        try await assertConsistent(harness, localCommands: 1)
    }

    /// A peer removes the head's block: the selection collapses to the anchor
    /// that survived. When both endpoints' block goes, the caret moves to the
    /// start of the block after it.
    func testSelectionFallsBackToTheNearestSurvivorAfterARemoteDelete() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        let writer = BlockNoteWriter(doc: peer)

        try select(harness, from: (Self.firstID, 3), to: (Self.secondID, 4))
        await harness.settle()
        try await session.integrateServerState(
            try writer.replaceRange(
                from: try writer.find(Self.firstID), at: 16, to: try writer.find(Self.secondID), at: 42, lines: [""],
                newIDs: []))
        XCTAssertEqual(session.surface.blocks.map(\.id), [Self.firstID, Self.thirdID])
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: 3, length: 0))
        let head1 = await selection(harness)?.head
        XCTAssertEqual(head1, EditorPosition(blockID: Self.firstID, offset: 3, assoc: -1))

        try select(harness, from: (Self.firstID, 2), to: (Self.firstID, 8))
        await harness.settle()
        try await session.integrateServerState(
            try writer.replaceRange(
                from: try writer.find(Self.firstID), at: 0, to: try writer.find(Self.thirdID), at: 0, lines: [""],
                newIDs: []))
        // The peer's range delete emptied the first block's text and moved the
        // third's into it: both endpoints collapse to where the text went.
        XCTAssertEqual(session.surface.blocks.map(\.id), [Self.firstID])
        XCTAssertEqual(harness.view.selectedRange.length, 0)
        harness.view.insertText("ok")
        await harness.settle()
        XCTAssertEqual(texts(session).first?.hasPrefix("ok"), true)
        try await assertConsistent(harness, localCommands: 1)
    }

    func testSelectionInADeletedBlockMovesToTheNextBlock() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try select(harness, from: (Self.secondID, 2), to: (Self.secondID, 9))
        await harness.settle()
        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        // A peer's join removes the second block's container; its text moves up.
        try await session.integrateServerState(try BlockNoteWriter(doc: peer).joinBlocks(block: Self.secondID))
        XCTAssertNil(session.surface.rangeIndex.entry(for: Self.secondID))
        let loc = try location(session, Self.thirdID, 0)
        XCTAssertEqual(
            harness.view.selectedRange, NSRange(location: loc, length: 0),
            "the caret moves visibly to the nearest surviving block")
        let headID = await selection(harness)?.head.blockID
        XCTAssertEqual(headID, Self.thirdID)
        harness.view.insertText("x")
        await harness.settle()
        XCTAssertEqual(texts(session).last, "xThird paragraph.")
        try await assertConsistent(harness, localCommands: 1)
    }

    /// An endpoint in a preserved placeholder is not tracked: the engine
    /// selection is cleared rather than left stale.
    func testASelectionEndingInAPlaceholderIsNotTracked() async throws {
        let harness = try await makeHarness([
            paragraph("text", "Text"), BlockNoteBlock(node: "table", props: [], runs: [], id: "table"),
        ])
        addTeardownBlock { await harness.close() }
        try select(harness, from: ("text", 1), to: ("text", 3))
        await harness.settle()
        let sel1 = await selection(harness)
        XCTAssertNotNil(sel1)
        try select(harness, from: ("text", 1), to: ("table", 1))
        await harness.settle()
        let sel2 = await selection(harness)
        XCTAssertNil(sel2)
    }

    /// The keyboard holds an autocorrection or inline prediction computed
    /// from the text it last saw. A caret moved outside a text change makes
    /// UIKit accept it at that stale range (`prepareForSelectionChange`):
    /// "elsewh" typed at a paragraph end became "elseeleresewhereh". Each
    /// command's storage edit and caret must reach the keyboard as one change.
    func testCommandsMoveTheCaretInsideOneKeyboardTextChange() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let input = harness.input
        let end = try XCTUnwrap(session.surface.rangeIndex.entry(for: Self.firstID)).textRange.upperBound
        session.textView.selectedRange = NSRange(location: end, length: 0)
        let keyboard = KeyboardInputDelegateSpy()
        session.textView.inputDelegate = keyboard
        XCTAssertTrue(input.replace(range: NSRange(location: end, length: 0), with: "h"))
        XCTAssertEqual(session.textView.selectedRange, NSRange(location: end + 1, length: 0))
        await harness.settle()
        let inserted = await harness.run { input.insertNewline() }
        XCTAssertTrue(inserted)
        // A peer's edit before the caret: its restored caret is a move too.
        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        try await session.integrateServerState(
            try BlockNoteWriter(doc: peer).replaceText(block: Self.firstID, range: 0..<0, with: "peer "))
        XCTAssertEqual(input.selection.restoredSelections, 1, "the peer's edit moved the caret")
        XCTAssertTrue(keyboard.events.contains("selectionWillChange"), "\(keyboard.events)")
        XCTAssertEqual(keyboard.strayCaretMoves, 0, "every caret move is inside a text change: \(keyboard.events)")
        XCTAssertEqual(keyboard.depth, 0, "every text change ended")
        XCTAssertEqual(keyboard.events.filter { $0 == "textWillChange" }.count, 3, "one change per command or patch")
    }
}

/// Records what the keyboard (`UITextView.inputDelegate`) is told.
@MainActor
private final class KeyboardInputDelegateSpy: NSObject, @preconcurrency UITextInputDelegate {
    var events: [String] = []
    var depth = 0
    var strayCaretMoves = 0
    func selectionWillChange(_ textInput: (any UITextInput)?) {
        events.append("selectionWillChange")
        if depth == 0 { strayCaretMoves += 1 }
    }
    func selectionDidChange(_ textInput: (any UITextInput)?) { events.append("selectionDidChange") }
    func textWillChange(_ textInput: (any UITextInput)?) {
        events.append("textWillChange")
        depth += 1
    }
    func textDidChange(_ textInput: (any UITextInput)?) {
        events.append("textDidChange")
        depth -= 1
    }
    func conversationContext(_ context: UIConversationContext?, didChange textInput: (any UITextInput)?) {}
}
