import XCTest

@testable import Schrift

/// A tick made while "Hide completed" is on keeps its row, checked, for a beat before it hides
/// (`ChecklistSettling`), so the row never collapses away still drawn unticked.
final class ChecklistSettlingTests: XCTestCase {
    private let first = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let second = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    func testFinishingWithTheTokenFromBeginEndsTheSettle() {
        var settling = ChecklistSettling()
        let token = settling.begin(first)
        XCTAssertEqual(settling.ids, [first])
        XCTAssertTrue(settling.finish(first, token: token))
        XCTAssertTrue(settling.isEmpty)
    }

    func testUntickingDuringTheSettleCancelsItAndTheLateFinishDoesNothing() {
        var settling = ChecklistSettling()
        let token = settling.begin(first)
        settling.cancel(first)
        XCTAssertTrue(settling.isEmpty)
        XCTAssertFalse(settling.finish(first, token: token))
        XCTAssertTrue(settling.isEmpty)
    }

    /// Tick, untick, tick again inside one beat: the first tick's pending finish must not cut
    /// the second tick's settle short.
    func testAnEarlierTicksFinishCannotEndARetickSettle() {
        var settling = ChecklistSettling()
        let stale = settling.begin(first)
        settling.cancel(first)
        let fresh = settling.begin(first)
        XCTAssertNotEqual(stale, fresh)
        XCTAssertFalse(settling.finish(first, token: stale))
        XCTAssertEqual(settling.ids, [first])
        XCTAssertTrue(settling.finish(first, token: fresh))
        XCTAssertTrue(settling.isEmpty)
    }

    func testItemsSettleIndependently() {
        var settling = ChecklistSettling()
        let firstToken = settling.begin(first)
        let secondToken = settling.begin(second)
        XCTAssertEqual(settling.ids, [first, second])
        XCTAssertFalse(settling.finish(first, token: secondToken))
        XCTAssertTrue(settling.finish(first, token: firstToken))
        XCTAssertEqual(settling.ids, [second])
    }

    func testPruningDropsItemsThatWentAwayOrAreNoLongerTicked() {
        var settling = ChecklistSettling()
        _ = settling.begin(first)
        _ = settling.begin(second)
        let kept = EditorBlock(id: second, kind: .checklistItem(checked: true), text: "Still done")
        settling.prune(keeping: [kept])
        XCTAssertEqual(settling.ids, [second])
        let reopened = EditorBlock(id: second, kind: .checklistItem(checked: false), text: "Reopened")
        settling.prune(keeping: [reopened])
        XCTAssertTrue(settling.isEmpty)
    }

    func testRemoveAllEndsEverySettle() {
        var settling = ChecklistSettling()
        let token = settling.begin(first)
        _ = settling.begin(second)
        settling.removeAll()
        XCTAssertTrue(settling.isEmpty)
        XCTAssertFalse(settling.finish(first, token: token))
    }

    // MARK: Reading presentation

    /// A settling item stays as a row, checked, together with what hides along with it, and is
    /// not counted as hidden until it settles.
    func testTheReadingPresentationKeepsASettlingItemAndWhatGoesWithIt() {
        let blocks = [
            EditorBlock(kind: .checklistItem(checked: true), text: "Just ticked"),
            EditorBlock(kind: .checklistItem(checked: false), text: "Nested under it", indent: 1),
            EditorBlock(kind: .checklistItem(checked: true), text: "Done earlier"),
            EditorBlock(kind: .checklistItem(checked: false), text: "Still to do"),
        ]
        let ticked = blocks[0].id
        let settling = ChecklistReadingPresentation(blocks: blocks, hidingCompleted: true, settling: [ticked])
        XCTAssertEqual(settling.rows.map(\.id), [blocks[0].id, blocks[1].id, blocks[3].id])
        XCTAssertEqual(settling.rows.first?.block.kind, .checklistItem(checked: true))
        XCTAssertEqual(settling.hiddenCount, 1)

        let settled = ChecklistReadingPresentation(blocks: blocks, hidingCompleted: true, settling: [])
        XCTAssertEqual(settled.rows.map(\.id), [blocks[3].id])
        XCTAssertEqual(settled.hiddenCount, 2)
    }

    /// Settling only delays hiding: with nothing hidden, or for an item that is not ticked, it
    /// changes nothing.
    func testSettlingChangesNothingWhenNothingIsHidden() {
        let blocks = parseEditorBlocks("- [x] Done\n- [ ] Open")
        let ids = Set(blocks.map(\.id))
        let showing = ChecklistReadingPresentation(blocks: blocks, hidingCompleted: false, settling: ids)
        XCTAssertEqual(showing.rows.map(\.id), blocks.map(\.id))
        let open = ChecklistReadingPresentation(blocks: blocks, hidingCompleted: true, settling: [blocks[1].id])
        XCTAssertEqual(open.rows.map(\.id), [blocks[1].id])
        XCTAssertEqual(open.hiddenCount, 1)
    }
}
