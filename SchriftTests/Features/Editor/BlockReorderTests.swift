import XCTest

@testable import Schrift

final class BlockReorderTests: XCTestCase {
    private let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let b = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let c = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let d = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    /// Four 40pt rows with a 10pt gap: centres at 20, 70, 120, 170.
    private var frames: [UUID: CGRect] {
        [
            a: CGRect(x: 0, y: 0, width: 300, height: 40),
            b: CGRect(x: 0, y: 50, width: 300, height: 40),
            c: CGRect(x: 0, y: 100, width: 300, height: 40),
            d: CGRect(x: 0, y: 150, width: 300, height: 40),
        ]
    }

    // MARK: - Reorderable kinds

    func testOnlyLeavesAreReorderable() {
        XCTAssertTrue(blockIsReorderable(.divider))
        XCTAssertTrue(blockIsReorderable(.image(alt: "", url: "https://docs.example.org/a.jpg")))
        XCTAssertTrue(blockIsReorderable(.attachment(name: "a.pdf", url: "https://docs.example.org/a.pdf")))
        XCTAssertFalse(blockIsReorderable(.paragraph))
        XCTAssertFalse(blockIsReorderable(.checklistItem(checked: false)))
        XCTAssertFalse(blockIsReorderable(.heading(level: 1)))
        XCTAssertFalse(blockIsReorderable(.codeBlock(language: "")))
    }

    // MARK: - Destination

    func testDraggingPastTheNextRowsCentreMovesBelowIt() {
        // `a` (centre 20) dragged down to 75: past `b`'s centre, short of `c`'s.
        XCTAssertEqual(
            blockReorderDestination(draggedID: a, dragCenterY: 75, order: [a, b, c, d], frames: frames), 1)
    }

    func testDraggingToTheBottomLandsLast() {
        XCTAssertEqual(
            blockReorderDestination(draggedID: a, dragCenterY: 400, order: [a, b, c, d], frames: frames), 3)
    }

    func testDraggingUpwardLandsAboveTheRowItPassed() {
        // `d` (centre 170) dragged up to 60: above `b`'s centre, below `a`'s.
        XCTAssertEqual(
            blockReorderDestination(draggedID: d, dragCenterY: 60, order: [a, b, c, d], frames: frames), 1)
    }

    func testAShortDragIsANoOp() {
        // `b` (centre 70) nudged to 90: still between `a` and `c`.
        XCTAssertNil(blockReorderDestination(draggedID: b, dragCenterY: 90, order: [a, b, c, d], frames: frames))
    }

    func testAnUnrealizedRowKeepsItsOriginalSide() {
        // `a` sits above the viewport and has no frame. Dragging `c` to the top of
        // what is visible must still leave it below `a`.
        var visible = frames
        visible[a] = nil
        XCTAssertEqual(
            blockReorderDestination(draggedID: c, dragCenterY: -500, order: [a, b, c, d], frames: visible), 1)
    }

    func testAnUnknownDraggedBlockHasNoDestination() {
        XCTAssertNil(blockReorderDestination(draggedID: UUID(), dragCenterY: 0, order: [a, b], frames: frames))
    }

    func testDragCentreFollowsTheTranslation() {
        var drag = BlockReorderDrag(blockID: a, startMidY: 20)
        drag.translation = CGSize(width: 90, height: 55)
        XCTAssertEqual(drag.centerY, 75, "only the vertical component moves the centre")
    }

    // MARK: - Horizontal steps

    func testHorizontalDragRoundsToTheNearestLevel() {
        let step: CGFloat = 16
        func steps(_ dx: CGFloat) -> Int {
            leafDragIndentSteps(translationX: dx, step: step, layoutDirection: .leftToRight)
        }
        XCTAssertEqual(steps(0), 0)
        XCTAssertEqual(steps(7), 0)
        XCTAssertEqual(steps(9), 1)
        XCTAssertEqual(steps(25), 2)
        XCTAssertEqual(steps(-9), -1)
        XCTAssertEqual(steps(-25), -2)
    }

    func testRightToLeftFlipsTheSlideDirection() {
        for dx: CGFloat in [-40, -9, 0, 7, 9, 40] {
            XCTAssertEqual(
                leafDragIndentSteps(translationX: dx, step: 16, layoutDirection: .rightToLeft),
                -leafDragIndentSteps(translationX: dx, step: 16, layoutDirection: .leftToRight))
        }
        XCTAssertEqual(leafDragIndentSteps(translationX: 20, step: 16, layoutDirection: .rightToLeft), -1)
    }

    func testDegenerateHorizontalInputNeverTraps() {
        XCTAssertEqual(leafDragIndentSteps(translationX: 50, step: 0, layoutDirection: .leftToRight), 0)
        XCTAssertEqual(leafDragIndentSteps(translationX: .nan, step: 16, layoutDirection: .leftToRight), 0)
        XCTAssertEqual(leafDragIndentSteps(translationX: .infinity, step: 16, layoutDirection: .leftToRight), 0)
        XCTAssertLessThanOrEqual(
            leafDragIndentSteps(translationX: 1e30, step: 16, layoutDirection: .leftToRight), 1_000)
    }

    // MARK: - Indent preview and range at a destination

    private func item(_ indent: Int = 0) -> EditorBlock { EditorBlock(kind: .bulletItem, text: "i", indent: indent) }
    private func photo(_ indent: Int = 0) -> EditorBlock {
        EditorBlock(kind: .image(alt: "", url: "https://docs.example.org/a.jpg"), indent: indent)
    }

    func testRangeIsEvaluatedAtTheDestinationNotWhereTheLeafStands() {
        let blocks = [item(), photo(), item()]
        let id = blocks[1].id
        XCTAssertEqual(leafDragIndentRange(blocks: blocks, blockID: id, destination: nil), 0...1)
        // Moved to the end it sits under the second item; to the top, under nothing.
        XCTAssertEqual(leafDragIndentRange(blocks: blocks, blockID: id, destination: 2), 0...1)
        XCTAssertEqual(leafDragIndentRange(blocks: blocks, blockID: id, destination: 0), 0...0)
        XCTAssertEqual(leafDragIndentRange(blocks: blocks, blockID: id, destination: 99), 0...1)
    }

    func testRangeBehindAParagraphAllowsNoNesting() {
        let blocks = [EditorBlock(kind: .paragraph, text: "p"), photo()]
        XCTAssertEqual(leafDragIndentRange(blocks: blocks, blockID: blocks[1].id, destination: nil), 0...0)
    }

    func testSlidingDeeperNestsUnderTheItemAboveAndClampsThere() {
        let blocks = [item(), photo(), item()]
        let id = blocks[1].id
        XCTAssertEqual(leafDragPreviewIndent(blocks: blocks, blockID: id, destination: nil, steps: 0), 0)
        XCTAssertEqual(leafDragPreviewIndent(blocks: blocks, blockID: id, destination: nil, steps: 1), 1)
        XCTAssertEqual(leafDragPreviewIndent(blocks: blocks, blockID: id, destination: nil, steps: 5), 1)
        XCTAssertEqual(leafDragPreviewIndent(blocks: blocks, blockID: id, destination: nil, steps: -3), 0)
    }

    func testPreviewFollowsTheLiveDestination() {
        let blocks = [item(), photo(), item()]
        let id = blocks[1].id
        // Dragged to the very top there is no item to nest under, however far it slides.
        XCTAssertEqual(leafDragPreviewIndent(blocks: blocks, blockID: id, destination: 0, steps: 3), 0)
        // Dragged below the last item it can nest under that one.
        XCTAssertEqual(leafDragPreviewIndent(blocks: blocks, blockID: id, destination: 2, steps: 1), 1)
        XCTAssertEqual(leafDragPreviewIndent(blocks: blocks, blockID: id, destination: 2, steps: 0), 0)
    }

    func testSlidingOutCannotOrphanTheSiblingsAfterIt() {
        // The nested item after the photo pins the photo to its level.
        let blocks = [item(), photo(1), item(1)]
        let id = blocks[1].id
        XCTAssertEqual(leafDragIndentRange(blocks: blocks, blockID: id, destination: nil), 1...1)
        XCTAssertEqual(leafDragPreviewIndent(blocks: blocks, blockID: id, destination: nil, steps: -1), 1)
    }

    func testANestedLeafKeepsItsLevelWhereTheItemAboveAllowsIt() {
        let blocks = [item(), photo(1), item(), item()]
        let id = blocks[1].id
        // Moved under the second item it keeps the level it had, now as that item's child.
        XCTAssertEqual(leafDragPreviewIndent(blocks: blocks, blockID: id, destination: 2, steps: 0), 1)
    }

    func testADividerNeverGetsAnIndent() {
        let blocks = [item(), EditorBlock(kind: .divider)]
        XCTAssertNil(leafDragIndentRange(blocks: blocks, blockID: blocks[1].id, destination: nil))
        XCTAssertNil(leafDragPreviewIndent(blocks: blocks, blockID: blocks[1].id, destination: nil, steps: 1))
    }

    func testAnUnknownDraggedBlockHasNoPreview() {
        XCTAssertNil(leafDragPreviewIndent(blocks: [item()], blockID: UUID(), destination: nil, steps: 1))
        XCTAssertNil(leafDragIndentRange(blocks: [item()], blockID: UUID(), destination: nil))
    }
}
