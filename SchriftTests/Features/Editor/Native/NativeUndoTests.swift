import UIKit
import XCTest

@testable import Schrift

/// PR07b: the native editor's collaborative undo. Undo and redo are durable
/// engine commands over a real `NativeTextView` and a restored durable replica
/// (journaled before publication, replayable, never the unjournaled freeze);
/// only local user edits are captured; typing groups until a boundary; the
/// selection a step stored comes back; UIKit's undo routes here. No sleeps:
/// typing within one test runs well inside the 500 ms capture window.
@MainActor
final class NativeUndoTests: NativeEditingTestCase {
    private func caret(_ harness: Harness, _ id: String, _ offset: Int, length: Int = 0) throws {
        setSelection(harness, NSRange(location: try location(harness.session, id, offset), length: length))
    }

    /// One keystroke at the view's selection, as `insertText` sends it.
    private func type(_ harness: Harness, _ text: String) {
        XCTAssertTrue(harness.input.replace(range: harness.view.selectedRange, with: text))
    }

    private func steps(_ harness: Harness) -> Int { harness.input.history.history.undoStack.count }

    private var seedTexts: [String] { Self.seedBlocks().map { $0.runs.map(\.text).joined() } }

    func testTypingIsOneStepThatUndoesAndRedoesDurably() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let session = harness.session
        try caret(harness, Self.firstID, 5)
        for character in ["a", "b", "c"] { type(harness, character) }
        XCTAssertEqual(texts(session)[0], "Firstabc paragraph.")
        XCTAssertEqual(steps(harness), 1, "typing within the capture window is one step")
        XCTAssertFalse(harness.input.canRedo)

        let before = session.surface.blocks
        XCTAssertTrue(harness.input.undo())
        XCTAssertEqual(texts(session), seedTexts)
        XCTAssertEqual(harness.log.commands.last?.kind, .undo)
        XCTAssertEqual(harness.log.blocksAtPersist.last, before, "journaled before the surface saw it")
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(session, Self.firstID, 5), length: 0))
        XCTAssertFalse(harness.input.canUndo)
        XCTAssertTrue(harness.input.canRedo)
        try assertConsistent(harness, localCommands: 4)

        XCTAssertTrue(harness.input.redo())
        XCTAssertEqual(texts(session)[0], "Firstabc paragraph.")
        XCTAssertEqual(harness.log.commands.last?.kind, .redo)
        XCTAssertEqual(
            harness.view.selectedRange, NSRange(location: try location(session, Self.firstID, 8), length: 0),
            "redo restores the selection from before the undo")
        try assertConsistent(harness, localCommands: 5)
        XCTAssertFalse(harness.input.redo(), "nothing left to redo")
        try assertConsistent(harness, localCommands: 5)
    }

    func testEachStepIsJournaledOnceInTheOutbox() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        try caret(harness, Self.firstID, 0)
        type(harness, "x")
        XCTAssertTrue(harness.input.undo())
        let undo = try XCTUnwrap(harness.log.commands.last)
        let manifest = try XCTUnwrap(try harness.store.manifest(for: harness.scope))
        XCTAssertEqual(manifest.journal.filter { $0.commandID == undo.id }.count, 1)
        XCTAssertEqual(manifest.outbox.count, 2, "the typing and its undo are both sent, once each")
        XCTAssertEqual(harness.session.engine.revision, 2)
        try assertConsistent(harness, localCommands: 2)
    }

    func testBoundariesSplitSteps() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let session = harness.session
        try caret(harness, Self.firstID, 0)
        type(harness, "a")
        type(harness, "b")
        XCTAssertEqual(steps(harness), 1)
        // A caret moved by a tap or an arrow key, not by typing.
        try caret(harness, Self.thirdID, 0)
        type(harness, "c")
        XCTAssertEqual(steps(harness), 2)
        // A structural command is a step of its own, and so is what follows it.
        XCTAssertTrue(harness.input.insertNewline())
        XCTAssertEqual(steps(harness), 3)
        type(harness, "d")
        XCTAssertEqual(steps(harness), 4)

        XCTAssertTrue(harness.input.undo())
        XCTAssertEqual(texts(session)[3], "Third paragraph.")
        XCTAssertTrue(harness.input.undo())
        XCTAssertEqual(session.surface.blocks.count, 3, "the split is undone on its own")
        XCTAssertEqual(texts(session)[2], "cThird paragraph.")
        XCTAssertTrue(harness.input.undo())
        XCTAssertEqual(texts(session)[2], "Third paragraph.")
        XCTAssertEqual(texts(session)[0], "abFirst paragraph.")
        XCTAssertTrue(harness.input.undo())
        XCTAssertEqual(texts(session), seedTexts)
        try assertConsistent(harness, localCommands: 9)
    }

    func testFormatSplitAndJoinUndo() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let session = harness.session
        let seed = session.surface.blocks
        try caret(harness, Self.firstID, 0, length: 5)
        XCTAssertTrue(harness.input.toggleMark("bold"))
        XCTAssertNotEqual(session.surface.blocks, seed)
        XCTAssertTrue(harness.input.undo())
        XCTAssertEqual(session.surface.blocks, seed, "the mark is gone, the text untouched")

        try caret(harness, Self.firstID, 5)
        XCTAssertTrue(harness.input.insertNewline())
        XCTAssertEqual(texts(session).prefix(2), ["First", " paragraph."])
        XCTAssertTrue(harness.input.undo())
        XCTAssertEqual(session.surface.blocks, seed)

        try caret(harness, Self.secondID, 0)
        XCTAssertTrue(harness.input.deleteBackwardAtBlockStart())
        XCTAssertEqual(session.surface.blocks.count, 2)
        XCTAssertTrue(harness.input.undo())
        XCTAssertEqual(session.surface.blocks.map(\.id), seed.map(\.id))
        XCTAssertEqual(texts(session), seedTexts)
        try assertConsistent(harness, localCommands: 6)
    }

    func testTreeAndBlockCommandsUndo() throws {
        let harness = try makeHarness([paragraph("a", "Alpha"), bullet("b", "Beta"), bullet("c", "Gamma")])
        defer { harness.close() }
        let session = harness.session
        try caret(harness, "c", 2)
        XCTAssertTrue(harness.input.indent())
        XCTAssertEqual(session.surface.blocks.map(\.depth), [0, 0, 1])
        XCTAssertTrue(harness.input.undo())
        XCTAssertEqual(session.surface.blocks.map(\.depth), [0, 0, 0])
        XCTAssertEqual(session.surface.blocks.map(\.id), ["a", "b", "c"])

        try caret(harness, "a", 1)
        XCTAssertTrue(harness.input.performBlockAction(.moveDown))
        XCTAssertEqual(session.surface.blocks.map(\.id), ["b", "a", "c"])
        XCTAssertTrue(harness.input.undo())
        XCTAssertEqual(session.surface.blocks.map(\.id), ["a", "b", "c"])

        try caret(harness, "b", 0)
        XCTAssertTrue(harness.input.performBlockAction(.duplicate))
        XCTAssertEqual(session.surface.blocks.count, 4)
        XCTAssertTrue(harness.input.undo())
        XCTAssertEqual(session.surface.blocks.map(\.id), ["a", "b", "c"])

        try caret(harness, "b", 2)
        XCTAssertTrue(harness.input.performBlockAction(.delete))
        XCTAssertEqual(session.surface.blocks.map(\.id), ["a", "c"])
        XCTAssertTrue(harness.input.undo())
        XCTAssertEqual(session.surface.blocks.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(texts(session), ["Alpha", "Beta", "Gamma"])
        XCTAssertEqual(
            harness.view.selectedRange, NSRange(location: try location(session, "b", 2), length: 0),
            "the caret returns to the restored block")
        try assertConsistent(harness, localCommands: 8)
    }

    func testAPeerInsertBetweenEditAndUndoIsKept() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let session = harness.session
        try caret(harness, Self.firstID, 16)
        type(harness, "!")
        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        try session.integrateServerState(
            try BlockNoteWriter(doc: peer).replaceText(block: Self.firstID, range: 0..<0, with: "Peer "))
        XCTAssertEqual(texts(session)[0], "Peer First paragraph.!")
        XCTAssertTrue(harness.input.undo())
        XCTAssertEqual(texts(session)[0], "Peer First paragraph.", "only our own edit is undone")
        XCTAssertFalse(harness.input.canUndo, "the peer's edit is not undoable")
        XCTAssertTrue(harness.input.redo())
        XCTAssertEqual(texts(session)[0], "Peer First paragraph.!")
        try assertConsistent(harness, localCommands: 3)
    }

    func testRemoteEditsAreNeverUndoable() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        try harness.session.integrateServerState(
            try BlockNoteWriter(doc: peer).replaceText(block: Self.secondID, range: 0..<0, with: "Remote "))
        XCTAssertFalse(harness.input.canUndo)
        XCTAssertFalse(harness.input.undo())
        XCTAssertTrue(harness.log.commands.isEmpty)
    }

    func testAPeerDeletingTheStoredSelectionResolvesSafely() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let session = harness.session
        try caret(harness, Self.firstID, 5)
        type(harness, "abc")
        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        try session.integrateServerState(
            try BlockNoteWriter(doc: peer).replaceText(block: Self.firstID, range: 0..<10, with: ""))
        XCTAssertTrue(harness.input.undo())
        XCTAssertEqual(texts(session)[0], "graph.")
        let selection = try XCTUnwrap(try session.engine.currentSelection())
        XCTAssertEqual(selection.head.blockID, Self.firstID)
        XCTAssertLessThanOrEqual(NSMaxRange(harness.view.selectedRange), session.textView.textStorage.length)
        try assertConsistent(harness, localCommands: 2)
    }

    func testACompositionCommitIsOneStepAndUndoWaitsForIt() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let session = harness.session
        try caret(harness, Self.firstID, 0)
        type(harness, "x")
        for marked in ["に", "にほ", "日本"] {
            session.textView.setMarkedText(marked, selectedRange: NSRange(location: marked.utf16.count, length: 0))
        }
        XCTAssertNotNil(session.textView.markedTextRange)
        XCTAssertFalse(harness.input.canUndo, "refused while text is marked")
        XCTAssertFalse(session.textView.canPerformAction(NSSelectorFromString("undo:"), withSender: nil))
        XCTAssertFalse(harness.input.undo())
        XCTAssertEqual(harness.log.commands.count, 1)

        session.textView.unmarkText()
        XCTAssertEqual(texts(session)[0], "x日本First paragraph.")
        XCTAssertEqual(steps(harness), 2, "the commit does not merge into the typing before it")
        XCTAssertTrue(harness.input.undo())
        XCTAssertEqual(texts(session)[0], "xFirst paragraph.")
        XCTAssertTrue(harness.input.undo())
        XCTAssertEqual(texts(session), seedTexts)
        try assertConsistent(harness, localCommands: 4)
    }

    func testReadOnlyAndFrozenEditorsOfferNoUndo() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        try caret(harness, Self.firstID, 0)
        type(harness, "x")
        XCTAssertTrue(harness.input.canUndo)
        harness.input.stopAfterStorageFailure()
        XCTAssertFalse(harness.input.canUndo)
        XCTAssertFalse(harness.input.undo())
        XCTAssertEqual(harness.log.commands.count, 1)

        let reader = try NativeEditorSession(state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID))
        defer { reader.close() }
        XCTAssertNil(reader.textView.undoManager)
        XCTAssertFalse(reader.textView.canPerformAction(NSSelectorFromString("undo:"), withSender: nil))
    }

    func testSystemUndoRoutesToTheNativeHistory() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let session = harness.session
        let view = session.textView
        let system = try XCTUnwrap(view.undoManager)
        XCTAssertTrue(system === harness.input.history.system)
        XCTAssertFalse(system.canUndo)
        XCTAssertFalse(view.canPerformAction(NSSelectorFromString("undo:"), withSender: nil))
        try caret(harness, Self.firstID, 0)
        type(harness, "x")
        // UIKit's own marked-text writes go through `super`; they must not become a second history.
        view.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
        view.unmarkText()
        XCTAssertTrue(system.canUndo)
        XCTAssertTrue(view.canPerformAction(NSSelectorFromString("undo:"), withSender: nil))
        XCTAssertFalse(view.canPerformAction(NSSelectorFromString("redo:"), withSender: nil))

        system.undo()
        XCTAssertEqual(texts(session)[0], "xFirst paragraph.", "one native step, never UIKit's")
        view.perform(NSSelectorFromString("undo:"), with: nil)
        XCTAssertEqual(texts(session), seedTexts)
        XCTAssertTrue(system.canRedo)
        view.perform(NSSelectorFromString("redo:"), with: nil)
        XCTAssertEqual(texts(session)[0], "xFirst paragraph.")
        system.redo()
        XCTAssertEqual(texts(session)[0], "x日本First paragraph.")
        try assertConsistent(harness, localCommands: 6)
    }

    func testTheHistoryIsBounded() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let session = harness.session
        try caret(harness, Self.firstID, 0)
        let count = NativeUndoManager.maxDepth + 5
        for _ in 0..<count {
            type(harness, "x")
            harness.input.history.stopCapturing()
        }
        XCTAssertEqual(steps(harness), NativeUndoManager.maxDepth, "the oldest steps are dropped")
        try assertConsistent(harness, localCommands: count)
        while harness.input.canUndo { XCTAssertTrue(harness.input.undo()) }
        XCTAssertEqual(texts(session)[0], "xxxxxFirst paragraph.", "the dropped steps stay")
        try assertConsistent(harness, localCommands: count + NativeUndoManager.maxDepth)
    }

    func testTheHistoryGoesWithTheSession() throws {
        weak var history: NativeUndoManager?
        weak var replica: YDoc?
        try autoreleasepool {
            let harness = try makeHarness()
            try caret(harness, Self.firstID, 0)
            type(harness, "x")
            history = harness.input.history
            replica = harness.input.history.history.doc
            XCTAssertTrue(history?.canUndo == true)
            harness.close()
            XCTAssertNil(harness.view.undoManager, "no history after close")
        }
        XCTAssertNil(history, "the history is released with the session")
        XCTAssertNil(replica, "nothing keeps the replica alive")
    }
}
