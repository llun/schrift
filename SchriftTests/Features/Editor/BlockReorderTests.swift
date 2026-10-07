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
        drag.translation = 55
        XCTAssertEqual(drag.centerY, 75)
    }

    // MARK: - Gesture

    @MainActor
    func testTheRecognizerIsAOneFingerLongPress() {
        let recognizer = BlockReorderGesture.makeRecognizer()
        XCTAssertEqual(recognizer.minimumPressDuration, BlockReorderGesture.minimumPressDuration)
        XCTAssertEqual(recognizer.numberOfTouchesRequired, 1)
    }
}
