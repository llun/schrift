import UIKit
import XCTest

@testable import Schrift

/// PR04b: the native selection is kept as directed engine relative positions
/// across blocks. It survives peer edits and rebuilds with affinity, and falls
/// back visibly to the nearest surviving block when its target disappears.
@MainActor
final class NativeSelectionTests: NativeEditingTestCase {
    private func selection(_ harness: Harness) throws -> EditorSelection? {
        try harness.session.engine.currentSelection()
    }

    func testForwardAndBackwardSelectionsAcrossBlocksAreDirected() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        try select(harness, from: (Self.firstID, 6), to: (Self.thirdID, 5))
        XCTAssertEqual(
            try selection(harness),
            EditorSelection(
                anchor: EditorPosition(blockID: Self.firstID, offset: 6, assoc: 0),
                head: EditorPosition(blockID: Self.thirdID, offset: 5, assoc: -1)))

        try select(harness, from: (Self.thirdID, 5), to: (Self.firstID, 6))
        XCTAssertEqual(
            try selection(harness),
            EditorSelection(
                anchor: EditorPosition(blockID: Self.thirdID, offset: 5, assoc: -1),
                head: EditorPosition(blockID: Self.firstID, offset: 6, assoc: 0)))
        XCTAssertTrue(harness.input.selection.isBackward)
        try assertConsistent(harness, localCommands: 0)
    }

    /// The sequence of ranges hardware Shift-arrows produce, one character at
    /// a time across a separator: forward from a caret, then backward from a
    /// caret, each typed over as one command.
    func testShiftArrowStepsAcrossASeparator() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let session = harness.session
        let end = try location(session, Self.firstID, 14)
        for length in 0...4 { setSelection(harness, NSRange(location: end, length: length)) }
        XCTAssertEqual(try selection(harness)?.anchor, EditorPosition(blockID: Self.firstID, offset: 14, assoc: 0))
        XCTAssertEqual(try selection(harness)?.head, EditorPosition(blockID: Self.secondID, offset: 1, assoc: -1))
        harness.view.insertText("Z")
        XCTAssertEqual(texts(session)[0], "First paragrapZecond paragraph has bold words inside it.")
        try assertConsistent(harness, localCommands: 1)

        let caret = try location(session, Self.thirdID, 2)
        for length in 0...4 { setSelection(harness, NSRange(location: caret - length, length: length)) }
        XCTAssertEqual(try selection(harness)?.anchor, EditorPosition(blockID: Self.thirdID, offset: 2, assoc: -1))
        XCTAssertEqual(try selection(harness)?.head.blockID, Self.firstID)
        XCTAssertTrue(harness.input.selection.isBackward)
        // Shift-Right shrinks the backward selection from its head.
        setSelection(harness, NSRange(location: caret - 3, length: 3))
        XCTAssertTrue(harness.input.selection.isBackward)
        harness.view.deleteBackward()
        XCTAssertEqual(texts(session), ["First paragrapZecond paragraph has bold words inside it.ird paragraph."])
        try assertConsistent(harness, localCommands: 2)
    }

    /// Text a peer inserts at either boundary stays outside a non-empty
    /// selection; text inside it moves with it. The view follows.
    func testSelectionSurvivesPeerEditsWithAffinity() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let session = harness.session
        try select(harness, from: (Self.firstID, 6), to: (Self.secondID, 6))
        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        let writer = BlockNoteWriter(doc: peer)
        try session.integrateServerState(try writer.replaceText(block: Self.firstID, range: 6..<6, with: "<"))
        try session.integrateServerState(try writer.replaceText(block: Self.secondID, range: 6..<6, with: ">"))
        try session.integrateServerState(try writer.replaceText(block: Self.firstID, range: 0..<0, with: "Peer "))
        XCTAssertEqual(
            texts(session)[0...1], ["Peer First <paragraph.", "Second> paragraph has bold words inside it."])
        let start = try location(session, Self.firstID, 12)
        XCTAssertEqual(
            harness.view.selectedRange,
            NSRange(location: start, length: try location(session, Self.secondID, 6) - start))
        harness.view.insertText("-")
        XCTAssertEqual(texts(session)[0], "Peer First <-> paragraph has bold words inside it.")
        try assertConsistent(harness, localCommands: 1)
    }

    /// A peer typing in a block after the selection never sets the view's
    /// selection (that would end a handle drag in progress). An edit before it
    /// moves its document offsets, which UIKit does not follow: the restore
    /// sets it once to keep it on the same text.
    func testAPeerEditAfterTheSelectionNeverSetsTheViewSelection() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let session = harness.session
        try select(harness, from: (Self.secondID, 2), to: (Self.secondID, 9))
        let selected = (harness.view.textStorage.string as NSString).substring(with: harness.view.selectedRange)
        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        let writer = BlockNoteWriter(doc: peer)
        try session.integrateServerState(try writer.replaceText(block: Self.thirdID, range: 0..<0, with: "after "))
        XCTAssertEqual(texts(session)[2], "after Third paragraph.")
        XCTAssertEqual(harness.input.selection.restoredSelections, 0, "an edit after the selection never sets it")
        try session.integrateServerState(try writer.replaceText(block: Self.firstID, range: 0..<0, with: "before "))
        XCTAssertEqual(harness.input.selection.restoredSelections, 1)
        XCTAssertEqual(
            (harness.view.textStorage.string as NSString).substring(with: harness.view.selectedRange), selected)
        XCTAssertEqual(harness.view.selectedRange.location, try location(session, Self.secondID, 2))
    }

    /// A peer splits the selected block: the end in the moved text resolves to
    /// the split point, so the selection stays in the kept block.
    func testSelectionAfterARemoteSplit() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let session = harness.session
        try select(harness, from: (Self.firstID, 2), to: (Self.firstID, 10))
        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        try session.integrateServerState(
            try BlockNoteWriter(doc: peer).splitBlock(block: Self.firstID, at: 5, newID: "peer-split"))
        XCTAssertEqual(texts(session)[0...1], ["First", " paragraph."])
        XCTAssertEqual(
            try selection(harness),
            EditorSelection(
                anchor: EditorPosition(blockID: Self.firstID, offset: 2, assoc: 0),
                head: EditorPosition(blockID: Self.firstID, offset: 5, assoc: -1)))
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: 2, length: 3))
        harness.view.insertText("x")
        XCTAssertEqual(texts(session)[0], "Fix")
        try assertConsistent(harness, localCommands: 1)
    }

    /// A peer removes the head's block: the selection collapses to the anchor
    /// that survived. When both endpoints' block goes, the caret moves to the
    /// start of the block after it.
    func testSelectionFallsBackToTheNearestSurvivorAfterARemoteDelete() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let session = harness.session
        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        let writer = BlockNoteWriter(doc: peer)

        try select(harness, from: (Self.firstID, 3), to: (Self.secondID, 4))
        try session.integrateServerState(
            try writer.replaceRange(
                from: try writer.find(Self.firstID), at: 16, to: try writer.find(Self.secondID), at: 42, lines: [""],
                newIDs: []))
        XCTAssertEqual(session.surface.blocks.map(\.id), [Self.firstID, Self.thirdID])
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: 3, length: 0))
        XCTAssertEqual(try selection(harness)?.head, EditorPosition(blockID: Self.firstID, offset: 3, assoc: -1))

        try select(harness, from: (Self.firstID, 2), to: (Self.firstID, 8))
        try session.integrateServerState(
            try writer.replaceRange(
                from: try writer.find(Self.firstID), at: 0, to: try writer.find(Self.thirdID), at: 0, lines: [""],
                newIDs: []))
        // The peer's range delete emptied the first block's text and moved the
        // third's into it: both endpoints collapse to where the text went.
        XCTAssertEqual(session.surface.blocks.map(\.id), [Self.firstID])
        XCTAssertEqual(harness.view.selectedRange.length, 0)
        harness.view.insertText("ok")
        XCTAssertEqual(texts(session).first?.hasPrefix("ok"), true)
        try assertConsistent(harness, localCommands: 1)
    }

    func testSelectionInADeletedBlockMovesToTheNextBlock() throws {
        let harness = try makeHarness()
        defer { harness.close() }
        let session = harness.session
        try select(harness, from: (Self.secondID, 2), to: (Self.secondID, 9))
        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        // A peer's join removes the second block's container; its text moves up.
        try session.integrateServerState(try BlockNoteWriter(doc: peer).joinBlocks(block: Self.secondID))
        XCTAssertNil(session.surface.rangeIndex.entry(for: Self.secondID))
        XCTAssertEqual(
            harness.view.selectedRange, NSRange(location: try location(session, Self.thirdID, 0), length: 0),
            "the caret moves visibly to the nearest surviving block")
        XCTAssertEqual(try selection(harness)?.head.blockID, Self.thirdID)
        harness.view.insertText("x")
        XCTAssertEqual(texts(session).last, "xThird paragraph.")
        try assertConsistent(harness, localCommands: 1)
    }

    /// An endpoint in a preserved placeholder is not tracked: the engine
    /// selection is cleared rather than left stale.
    func testASelectionEndingInAPlaceholderIsNotTracked() throws {
        let harness = try makeHarness([
            paragraph("text", "Text"), BlockNoteBlock(node: "table", props: [], runs: [], id: "table"),
        ])
        defer { harness.close() }
        try select(harness, from: ("text", 1), to: ("text", 3))
        XCTAssertNotNil(try selection(harness))
        try select(harness, from: ("text", 1), to: ("table", 1))
        XCTAssertNil(try selection(harness))
    }
}
