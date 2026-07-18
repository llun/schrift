import XCTest

@testable import Schrift

final class LiveEditingTests: XCTestCase {
    // MARK: - transformedCaret

    func testInsertionBeforeCaretShiftsItRightByInsertedLength() {
        // "world" -> "Xworld": a one-unit prepend. A caret at 3 (inside "wor|ld") sits entirely
        // after the insertion point, so it shifts right by the inserted length (1).
        XCTAssertEqual(transformedCaret(old: "world", new: "Xworld", caret: 3), 4)
    }

    func testInsertionAfterCaretLeavesItUnchanged() {
        // "hello" -> "helloX": an append. A caret at 2 (inside "he|llo") sits entirely inside the
        // common prefix, so the trailing insertion never touches it.
        XCTAssertEqual(transformedCaret(old: "hello", new: "helloX", caret: 2), 2)
    }

    func testDeletionBeforeCaretShrinksIt() {
        // "Xworld" -> "world": a one-unit removal from the front. A caret at 4 (inside "Xwor|ld")
        // sits after the deletion, so it shrinks left by the removed length (1).
        XCTAssertEqual(transformedCaret(old: "Xworld", new: "world", caret: 4), 3)
    }

    func testCaretAtZeroWithPrependStaysZero() {
        XCTAssertEqual(transformedCaret(old: "world", new: "Xworld", caret: 0), 0)
    }

    func testCaretAtOldEndWithAppendStaysAtOldEndNotNewEnd() {
        // A caret sitting exactly at the end of the old text is the common-prefix boundary, so a
        // trailing append does not carry it forward into the appended text: it stays at the old
        // length (5), not the new one (6).
        XCTAssertEqual(transformedCaret(old: "hello", new: "helloX", caret: 5), 5)
    }

    func testCaretInsideReplacedMiddleClampsToPrefixEnd() {
        // "the cat sat" -> "the dog sat": common prefix "the " (4 units), common suffix " sat"
        // (4 units). A caret at 5 falls inside the replaced "cat"/"dog" middle, so it clamps to
        // the end of the common prefix (4).
        XCTAssertEqual(transformedCaret(old: "the cat sat", new: "the dog sat", caret: 5), 4)
    }

    func testEmptyOldTextClampsCaretIntoNewText() {
        XCTAssertEqual(transformedCaret(old: "", new: "hello", caret: 0), 0)
    }

    func testEmptyNewTextClampsCaretToZero() {
        XCTAssertEqual(transformedCaret(old: "hello", new: "", caret: 3), 0)
    }

    func testEmojiInsertionBeforeCaretShiftsByTwoUTF16Units() {
        // U+1F600 is a UTF-16 surrogate pair (2 code units). Prepending it before "hi" must shift
        // a caret inside "hi" by 2, not by 1 (a Character/grapheme count would get this wrong).
        XCTAssertEqual(transformedCaret(old: "hi", new: "\u{1F600}hi", caret: 1), 3)
    }

    func testCaretPastNewLengthClampsToNewLength() {
        XCTAssertEqual(transformedCaret(old: "hello", new: "hi", caret: 10), 2)
    }

    func testOldEqualsNewLeavesCaretUnchanged() {
        XCTAssertEqual(transformedCaret(old: "hello", new: "hello", caret: 3), 3)
    }

    func testNegativeCaretClampsToZero() {
        XCTAssertEqual(transformedCaret(old: "hello", new: "hi", caret: -5), 0)
    }

    // MARK: - liveChangeSet

    private let idA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let idB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let idC = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    /// A deterministic `mintID` so tests can assert on the exact minted UUID.
    private func counterMintID(startingAt start: Int = 1) -> () -> UUID {
        var counter = start
        return {
            defer { counter += 1 }
            return UUID(uuidString: String(format: "%08d-0000-0000-0000-000000000000", counter))!
        }
    }

    /// Mutates a working copy of `blocks` per `changes`, applied in order, so tests can assert on
    /// the load-bearing property: applying the change set reproduces the projected sequence.
    private func apply(_ changes: [LiveBlockChange], to blocks: [EditorBlock]) -> [EditorBlock] {
        var result = blocks
        func index(of id: UUID) -> Int? { result.firstIndex { $0.id == id } }
        for change in changes {
            switch change {
            case .update(let id, let kind, let text):
                guard let i = index(of: id) else { continue }
                result[i].kind = kind
                result[i].text = text
            case .insert(let id, let kind, let text, let afterID):
                let newBlock = EditorBlock(id: id, kind: kind, text: text)
                if let afterID, let i = index(of: afterID) {
                    result.insert(newBlock, at: i + 1)
                } else {
                    result.insert(newBlock, at: 0)
                }
            case .remove(let id):
                guard let i = index(of: id) else { continue }
                result.remove(at: i)
            case .move(let id, let afterID):
                guard let i = index(of: id) else { continue }
                let block = result.remove(at: i)
                if let afterID, let j = index(of: afterID) {
                    result.insert(block, at: j + 1)
                } else {
                    result.insert(block, at: 0)
                }
            }
        }
        return result
    }

    func testIdenticalProjectionProducesEmptyChangesAndUnchangedMap() {
        let current = [
            EditorBlock(id: idA, kind: .paragraph, text: "Alpha"),
            EditorBlock(id: idB, kind: .paragraph, text: "Beta"),
        ]
        let map = ["n1": idA, "n2": idB]
        let projected = [
            ProjectedEditorBlock(blockNoteID: "n1", kind: .paragraph, text: "Alpha"),
            ProjectedEditorBlock(blockNoteID: "n2", kind: .paragraph, text: "Beta"),
        ]

        let result = liveChangeSet(current: current, projected: projected, map: map)

        XCTAssertEqual(result.change.changes, [])
        XCTAssertEqual(result.map, map)
    }

    func testSingleBlockTextChangeProducesOneUpdateWithSameReusedID() {
        let current = [
            EditorBlock(id: idA, kind: .paragraph, text: "Alpha"),
            EditorBlock(id: idB, kind: .paragraph, text: "Beta"),
        ]
        let map = ["n1": idA, "n2": idB]
        let projected = [
            ProjectedEditorBlock(blockNoteID: "n1", kind: .paragraph, text: "Alpha"),
            ProjectedEditorBlock(blockNoteID: "n2", kind: .paragraph, text: "Beta changed"),
        ]

        let result = liveChangeSet(current: current, projected: projected, map: map)

        XCTAssertEqual(result.change.changes, [.update(id: idB, kind: .paragraph, text: "Beta changed")])
        XCTAssertEqual(result.map, map)
    }

    func testKindOnlyChangeAlsoProducesAnUpdate() {
        let current = [EditorBlock(id: idA, kind: .paragraph, text: "Alpha")]
        let map = ["n1": idA]
        let projected = [ProjectedEditorBlock(blockNoteID: "n1", kind: .heading(level: 2), text: "Alpha")]

        let result = liveChangeSet(current: current, projected: projected, map: map)

        XCTAssertEqual(result.change.changes, [.update(id: idA, kind: .heading(level: 2), text: "Alpha")])
    }

    func testNewTrailingBlockProducesOneInsertAfterLastCurrentIDAndMapGainsIt() {
        let current = [
            EditorBlock(id: idA, kind: .paragraph, text: "Alpha"),
            EditorBlock(id: idB, kind: .paragraph, text: "Beta"),
        ]
        let map = ["n1": idA, "n2": idB]
        let projected = [
            ProjectedEditorBlock(blockNoteID: "n1", kind: .paragraph, text: "Alpha"),
            ProjectedEditorBlock(blockNoteID: "n2", kind: .paragraph, text: "Beta"),
            ProjectedEditorBlock(blockNoteID: "n3", kind: .paragraph, text: "Gamma"),
        ]
        let mintedID = UUID(uuidString: "00000001-0000-0000-0000-000000000000")!

        let result = liveChangeSet(
            current: current, projected: projected, map: map, mintID: counterMintID(startingAt: 1))

        XCTAssertEqual(
            result.change.changes,
            [.insert(id: mintedID, kind: .paragraph, text: "Gamma", afterID: idB)])
        XCTAssertEqual(result.map, ["n1": idA, "n2": idB, "n3": mintedID])
    }

    func testRemovedMiddleBlockProducesOneRemoveAndMapLosesItSurroundingUntouched() {
        let current = [
            EditorBlock(id: idA, kind: .paragraph, text: "Alpha"),
            EditorBlock(id: idB, kind: .paragraph, text: "Beta"),
            EditorBlock(id: idC, kind: .paragraph, text: "Gamma"),
        ]
        let map = ["n1": idA, "n2": idB, "n3": idC]
        let projected = [
            ProjectedEditorBlock(blockNoteID: "n1", kind: .paragraph, text: "Alpha"),
            ProjectedEditorBlock(blockNoteID: "n3", kind: .paragraph, text: "Gamma"),
        ]

        let result = liveChangeSet(current: current, projected: projected, map: map)

        XCTAssertEqual(result.change.changes, [.remove(id: idB)])
        XCTAssertEqual(result.map, ["n1": idA, "n3": idC])
    }

    func testBrandNewDocumentWithEmptyMapProducesAllInsertsInOrder() {
        let projected = [
            ProjectedEditorBlock(blockNoteID: "n1", kind: .heading(level: 1), text: "Title"),
            ProjectedEditorBlock(blockNoteID: "n2", kind: .paragraph, text: "Alpha"),
            ProjectedEditorBlock(blockNoteID: "n3", kind: .paragraph, text: "Beta"),
        ]
        let id1 = UUID(uuidString: "00000001-0000-0000-0000-000000000000")!
        let id2 = UUID(uuidString: "00000002-0000-0000-0000-000000000000")!
        let id3 = UUID(uuidString: "00000003-0000-0000-0000-000000000000")!

        let result = liveChangeSet(current: [], projected: projected, map: [:], mintID: counterMintID(startingAt: 1))

        XCTAssertEqual(
            result.change.changes,
            [
                .insert(id: id1, kind: .heading(level: 1), text: "Title", afterID: nil),
                .insert(id: id2, kind: .paragraph, text: "Alpha", afterID: id1),
                .insert(id: id3, kind: .paragraph, text: "Beta", afterID: id2),
            ])
        XCTAssertEqual(result.map, ["n1": id1, "n2": id2, "n3": id3])
    }

    func testReorderOfTwoSurvivingBlocksProducesMovesThatReproduceProjectedOrder() {
        let current = [
            EditorBlock(id: idA, kind: .paragraph, text: "Alpha"),
            EditorBlock(id: idB, kind: .paragraph, text: "Beta"),
        ]
        let map = ["n1": idA, "n2": idB]
        // Swapped: Beta now comes first.
        let projected = [
            ProjectedEditorBlock(blockNoteID: "n2", kind: .paragraph, text: "Beta"),
            ProjectedEditorBlock(blockNoteID: "n1", kind: .paragraph, text: "Alpha"),
        ]

        let result = liveChangeSet(current: current, projected: projected, map: map)

        XCTAssertFalse(result.change.changes.isEmpty, "a reorder must produce at least one move")
        let applied = apply(result.change.changes, to: current)
        XCTAssertEqual(applied.map(\.id), [idB, idA])
        XCTAssertEqual(applied.map(\.kind), [.paragraph, .paragraph])
        XCTAssertEqual(applied.map(\.text), ["Beta", "Alpha"])
        XCTAssertEqual(result.map, map)
    }

    func testReorderOfThreeSurvivingBlocksWithATextChangeReproducesProjectedOrderAndContent() {
        // A broader property test: three surviving blocks reordered to C, A, B, with B's text also
        // changed. Applying the emitted changes in order must reproduce the projected sequence
        // exactly (id order, kind, text) with the original ids preserved.
        let current = [
            EditorBlock(id: idA, kind: .paragraph, text: "Alpha"),
            EditorBlock(id: idB, kind: .paragraph, text: "Beta"),
            EditorBlock(id: idC, kind: .paragraph, text: "Gamma"),
        ]
        let map = ["n1": idA, "n2": idB, "n3": idC]
        let projected = [
            ProjectedEditorBlock(blockNoteID: "n3", kind: .paragraph, text: "Gamma"),
            ProjectedEditorBlock(blockNoteID: "n1", kind: .paragraph, text: "Alpha"),
            ProjectedEditorBlock(blockNoteID: "n2", kind: .paragraph, text: "Beta changed"),
        ]

        let result = liveChangeSet(current: current, projected: projected, map: map)

        let applied = apply(result.change.changes, to: current)
        XCTAssertEqual(applied.map(\.id), [idC, idA, idB])
        XCTAssertEqual(applied.map(\.text), ["Gamma", "Alpha", "Beta changed"])
        XCTAssertEqual(result.map, map)
    }

    func testInsertBetweenTwoSurvivingBlocks() {
        // A new block inserted between two surviving blocks. The insert should land after the first
        // block, and applying the change set should reproduce the projected sequence with the minted
        // id.
        let current = [
            EditorBlock(id: idA, kind: .paragraph, text: "Alpha"),
            EditorBlock(id: idC, kind: .paragraph, text: "Gamma"),
        ]
        let map = ["n1": idA, "n3": idC]
        let mintedID = UUID(uuidString: "00000001-0000-0000-0000-000000000000")!
        let projected = [
            ProjectedEditorBlock(blockNoteID: "n1", kind: .paragraph, text: "Alpha"),
            ProjectedEditorBlock(blockNoteID: "n2", kind: .paragraph, text: "Beta"),
            ProjectedEditorBlock(blockNoteID: "n3", kind: .paragraph, text: "Gamma"),
        ]

        let result = liveChangeSet(
            current: current, projected: projected, map: map, mintID: counterMintID(startingAt: 1))

        XCTAssertEqual(
            result.change.changes,
            [.insert(id: mintedID, kind: .paragraph, text: "Beta", afterID: idA)])
        XCTAssertEqual(result.map, ["n1": idA, "n2": mintedID, "n3": idC])

        let applied = apply(result.change.changes, to: current)
        XCTAssertEqual(applied.map(\.id), [idA, mintedID, idC])
        XCTAssertEqual(applied.map(\.kind), [.paragraph, .paragraph, .paragraph])
        XCTAssertEqual(applied.map(\.text), ["Alpha", "Beta", "Gamma"])
    }
}
