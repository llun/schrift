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

    /// Grouping must not depend on CI speed: steps here split only at explicit boundaries.
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

    /// The session's undo stack depth, after everything posted.
    private func steps(_ harness: Harness) async -> Int {
        await harness.session.history { $0.history.undoStack.count } ?? -1
    }

    /// Plain-argument asserts, so an awaited value can be checked in place.
    private func yes(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(value, message, file: file, line: line)
    }

    private func no(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(value, message, file: file, line: line)
    }

    private func equal<T: Equatable>(
        _ a: T, _ b: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(a, b, message, file: file, line: line)
    }

    private func undo(_ harness: Harness) async -> Bool { await harness.run { harness.input.undo() } }
    private func redo(_ harness: Harness) async -> Bool { await harness.run { harness.input.redo() } }

    private var seedTexts: [String] { Self.seedBlocks().map { $0.runs.map(\.text).joined() } }

    func testTypingIsOneStepThatUndoesAndRedoesDurably() async throws {
        let harness = try await makeHarness()
        let session = harness.session
        try caret(harness, Self.firstID, 5)
        for character in ["a", "b", "c"] { type(harness, character) }
        XCTAssertEqual(texts(session)[0], "Firstabc paragraph.")
        await harness.settle()
        equal(await steps(harness), 1, "typing within the capture window is one step")
        XCTAssertFalse(harness.input.canRedo)

        let before = session.surface.blocks
        yes(await undo(harness))
        XCTAssertEqual(texts(session), seedTexts)
        XCTAssertEqual(harness.log.commands.last?.kind, .undo)
        XCTAssertEqual(harness.log.blocksAtPersist.last, before, "journaled before the surface saw it")
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(session, Self.firstID, 5), length: 0))
        XCTAssertFalse(harness.input.canUndo)
        XCTAssertTrue(harness.input.canRedo)
        try await assertConsistent(harness, localCommands: 4)

        yes(await redo(harness))
        XCTAssertEqual(texts(session)[0], "Firstabc paragraph.")
        XCTAssertEqual(harness.log.commands.last?.kind, .redo)
        XCTAssertEqual(
            harness.view.selectedRange, NSRange(location: try location(session, Self.firstID, 8), length: 0),
            "redo restores the selection from before the undo")
        try await assertConsistent(harness, localCommands: 5)
        no(await redo(harness), "nothing left to redo")
        try await assertConsistent(harness, localCommands: 5)
    }

    func testEachStepIsJournaledOnceInTheOutbox() async throws {
        let harness = try await makeHarness()
        try caret(harness, Self.firstID, 0)
        type(harness, "x")
        yes(await undo(harness))
        let undo = try XCTUnwrap(harness.log.commands.last)
        let manifest = try XCTUnwrap(try harness.store.manifest(for: harness.scope))
        XCTAssertEqual(manifest.journal.filter { $0.commandID == undo.id }.count, 1)
        XCTAssertEqual(manifest.outbox.count, 2, "the typing and its undo are both sent, once each")
        equal(await harness.engine { $0.revision }, 2)
        try await assertConsistent(harness, localCommands: 2)
    }

    func testBoundariesSplitSteps() async throws {
        let harness = try await makeHarness()
        let session = harness.session
        try caret(harness, Self.firstID, 0)
        type(harness, "a")
        type(harness, "b")
        equal(await steps(harness), 1)
        // A caret moved by a tap or an arrow key, not by typing.
        try caret(harness, Self.thirdID, 0)
        type(harness, "c")
        equal(await steps(harness), 2)
        // A structural command is a step of its own, and so is what follows it.
        yes(await harness.run { harness.input.insertNewline() })
        equal(await steps(harness), 3)
        type(harness, "d")
        equal(await steps(harness), 4)

        yes(await undo(harness))
        XCTAssertEqual(texts(session)[3], "Third paragraph.")
        yes(await undo(harness))
        XCTAssertEqual(session.surface.blocks.count, 3, "the split is undone on its own")
        XCTAssertEqual(texts(session)[2], "cThird paragraph.")
        yes(await undo(harness))
        XCTAssertEqual(texts(session)[2], "Third paragraph.")
        XCTAssertEqual(texts(session)[0], "abFirst paragraph.")
        yes(await undo(harness))
        XCTAssertEqual(texts(session), seedTexts)
        try await assertConsistent(harness, localCommands: 9)
    }

    func testFormatSplitAndJoinUndo() async throws {
        let harness = try await makeHarness()
        let session = harness.session
        let seed = session.surface.blocks
        try caret(harness, Self.firstID, 0, length: 5)
        yes(await harness.run { harness.input.toggleMark("bold") })
        XCTAssertNotEqual(session.surface.blocks, seed)
        yes(await undo(harness))
        XCTAssertEqual(session.surface.blocks, seed, "the mark is gone, the text untouched")

        try caret(harness, Self.firstID, 5)
        yes(await harness.run { harness.input.insertNewline() })
        XCTAssertEqual(texts(session).prefix(2), ["First", " paragraph."])
        yes(await undo(harness))
        XCTAssertEqual(session.surface.blocks, seed)

        try caret(harness, Self.secondID, 0)
        yes(await harness.run { harness.input.deleteBackwardAtBlockStart() })
        XCTAssertEqual(session.surface.blocks.count, 2)
        yes(await undo(harness))
        XCTAssertEqual(session.surface.blocks.map(\.id), seed.map(\.id))
        XCTAssertEqual(texts(session), seedTexts)
        try await assertConsistent(harness, localCommands: 6)
    }

    func testTreeAndBlockCommandsUndo() async throws {
        let harness = try await makeHarness([paragraph("a", "Alpha"), bullet("b", "Beta"), bullet("c", "Gamma")])
        let session = harness.session
        try caret(harness, "c", 2)
        yes(await harness.run { harness.input.indent() })
        XCTAssertEqual(session.surface.blocks.map(\.depth), [0, 0, 1])
        yes(await undo(harness))
        XCTAssertEqual(session.surface.blocks.map(\.depth), [0, 0, 0])
        XCTAssertEqual(session.surface.blocks.map(\.id), ["a", "b", "c"])

        try caret(harness, "a", 1)
        yes(await harness.run { harness.input.performBlockAction(.moveDown) })
        XCTAssertEqual(session.surface.blocks.map(\.id), ["b", "a", "c"])
        yes(await undo(harness))
        XCTAssertEqual(session.surface.blocks.map(\.id), ["a", "b", "c"])

        try caret(harness, "b", 0)
        yes(await harness.run { harness.input.performBlockAction(.duplicate) })
        XCTAssertEqual(session.surface.blocks.count, 4)
        yes(await undo(harness))
        XCTAssertEqual(session.surface.blocks.map(\.id), ["a", "b", "c"])

        try caret(harness, "b", 2)
        yes(await harness.run { harness.input.performBlockAction(.delete) })
        XCTAssertEqual(session.surface.blocks.map(\.id), ["a", "c"])
        yes(await undo(harness))
        XCTAssertEqual(session.surface.blocks.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(texts(session), ["Alpha", "Beta", "Gamma"])
        XCTAssertEqual(
            harness.view.selectedRange, NSRange(location: try location(session, "b", 2), length: 0),
            "the caret returns to the restored block")
        try await assertConsistent(harness, localCommands: 8)
    }

    func testAPeerInsertBetweenEditAndUndoIsKept() async throws {
        let harness = try await makeHarness()
        let session = harness.session
        try caret(harness, Self.firstID, 16)
        type(harness, "!")
        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        try await session.integrateServerState(
            try BlockNoteWriter(doc: peer).replaceText(block: Self.firstID, range: 0..<0, with: "Peer "))
        XCTAssertEqual(texts(session)[0], "Peer First paragraph.!")
        yes(await undo(harness))
        XCTAssertEqual(texts(session)[0], "Peer First paragraph.", "only our own edit is undone")
        XCTAssertFalse(harness.input.canUndo, "the peer's edit is not undoable")
        yes(await redo(harness))
        XCTAssertEqual(texts(session)[0], "Peer First paragraph.!")
        try await assertConsistent(harness, localCommands: 3)
    }

    func testRemoteEditsAreNeverUndoable() async throws {
        let harness = try await makeHarness()
        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        try await harness.session.integrateServerState(
            try BlockNoteWriter(doc: peer).replaceText(block: Self.secondID, range: 0..<0, with: "Remote "))
        XCTAssertFalse(harness.input.canUndo)
        no(await undo(harness))
        XCTAssertTrue(harness.log.commands.isEmpty)
    }

    func testAPeerDeletingTheStoredSelectionResolvesSafely() async throws {
        let harness = try await makeHarness()
        let session = harness.session
        try caret(harness, Self.firstID, 5)
        type(harness, "abc")
        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        try await session.integrateServerState(
            try BlockNoteWriter(doc: peer).replaceText(block: Self.firstID, range: 0..<10, with: ""))
        yes(await undo(harness))
        XCTAssertEqual(texts(session)[0], "graph.")
        let current = await session.engine { try? $0.currentSelection() }
        let selection = try XCTUnwrap(current ?? nil)
        XCTAssertEqual(selection.head.blockID, Self.firstID)
        XCTAssertLessThanOrEqual(NSMaxRange(harness.view.selectedRange), session.textView.textStorage.length)
        try await assertConsistent(harness, localCommands: 2)
    }

    func testACompositionCommitIsOneStepAndUndoWaitsForIt() async throws {
        let harness = try await makeHarness()
        let session = harness.session
        try caret(harness, Self.firstID, 0)
        type(harness, "x")
        for marked in ["に", "にほ", "日本"] {
            session.textView.setMarkedText(marked, selectedRange: NSRange(location: marked.utf16.count, length: 0))
        }
        XCTAssertNotNil(session.textView.markedTextRange)
        await harness.settle()
        XCTAssertFalse(harness.input.canUndo, "refused while text is marked")
        XCTAssertFalse(session.textView.canPerformAction(NSSelectorFromString("undo:"), withSender: nil))
        no(await undo(harness))
        XCTAssertEqual(harness.log.commands.count, 1)

        session.textView.unmarkText()
        await harness.settle()
        XCTAssertEqual(texts(session)[0], "x日本First paragraph.")
        equal(await steps(harness), 2, "the commit does not merge into the typing before it")
        yes(await undo(harness))
        XCTAssertEqual(texts(session)[0], "xFirst paragraph.")
        yes(await undo(harness))
        XCTAssertEqual(texts(session), seedTexts)
        try await assertConsistent(harness, localCommands: 4)
    }

    func testReadOnlyAndFrozenEditorsOfferNoUndo() async throws {
        let harness = try await makeHarness()
        try caret(harness, Self.firstID, 0)
        type(harness, "x")
        await harness.settle()
        XCTAssertTrue(harness.input.canUndo)
        harness.input.stopAfterStorageFailure()
        XCTAssertFalse(harness.input.canUndo)
        no(await undo(harness))
        XCTAssertEqual(harness.log.commands.count, 1)

        let reader = try await NativeEditorSession.inspect(
            state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID))
        defer { reader.close() }
        XCTAssertNil(reader.textView.undoManager)
        XCTAssertFalse(reader.textView.canPerformAction(NSSelectorFromString("undo:"), withSender: nil))
    }

    func testSystemUndoRoutesToTheNativeHistory() async throws {
        let harness = try await makeHarness()
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
        await harness.settle()
        XCTAssertTrue(system.canUndo)
        XCTAssertTrue(view.canPerformAction(NSSelectorFromString("undo:"), withSender: nil))
        XCTAssertFalse(view.canPerformAction(NSSelectorFromString("redo:"), withSender: nil))

        system.undo()
        await harness.settle()
        XCTAssertEqual(texts(session)[0], "xFirst paragraph.", "one native step, never UIKit's")
        view.perform(NSSelectorFromString("undo:"), with: nil)
        await harness.settle()
        XCTAssertEqual(texts(session), seedTexts)
        XCTAssertTrue(system.canRedo)
        view.perform(NSSelectorFromString("redo:"), with: nil)
        await harness.settle()
        XCTAssertEqual(texts(session)[0], "xFirst paragraph.")
        system.redo()
        await harness.settle()
        XCTAssertEqual(texts(session)[0], "x日本First paragraph.")
        try await assertConsistent(harness, localCommands: 6)
    }

    func testTheHistoryIsBounded() async throws {
        let harness = try await makeHarness()
        let session = harness.session
        try caret(harness, Self.firstID, 0)
        let count = NativeUndoManager.maxDepth + 5
        for _ in 0..<count {
            type(harness, "x")
            _ = await harness.session.history { $0.stopCapturing() }
        }
        equal(await steps(harness), NativeUndoManager.maxDepth, "the oldest steps are dropped")
        try await assertConsistent(harness, localCommands: count)
        while harness.input.canUndo { yes(await undo(harness)) }
        XCTAssertEqual(texts(session)[0], "xxxxxFirst paragraph.", "the dropped steps stay")
        try await assertConsistent(harness, localCommands: count + NativeUndoManager.maxDepth)
    }

    func testTheHistoryGoesWithTheSession() async throws {
        weak var history: NativeUndoManager?
        let replica = WeakDoc()
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let scope = ReplicaScope(
                serverOrigin: "https://example.test", ownerUserID: UUID(), org: "docs", documentID: UUID())
            let store = ReplicaStore(directory: directory)
            _ = try store.create(
                for: scope, checkpoint: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID))
            var session = try await NativeEditorSession.restore(store: store, scope: scope, editable: true)
            let view = try XCTUnwrap(session?.textView)
            view.selectedRange = NSRange(location: 0, length: 0)
            XCTAssertTrue(try XCTUnwrap(session?.input).replace(range: view.selectedRange, with: "x"))
            await session?.settle()
            history = session?.input?.history
            _ = await session?.replicaDoc { replica.doc = $0 }
            XCTAssertTrue(history?.canUndo == true)
            await session?.close().value
            XCTAssertNil(view.undoManager, "no history after close")
            session = nil
        }
        XCTAssertNil(history, "the history is released with the session")
        // The replica session's isolated deinit runs on its own executor.
        await waitUntil { replica.doc == nil }
        XCTAssertNil(replica.doc, "nothing keeps the replica alive")
    }
}

/// Watches the replica from the test without keeping it (it lives on the session).
private final class WeakDoc: @unchecked Sendable {
    weak var doc: YDoc?
}
