import XCTest

@MainActor
final class ChecklistHitTests: XCTestCase {
    func testDenseChecklistTargetsAtDefaultSize() { verifyTargets(accessibility: false) }
    func testDenseChecklistTargetsAtAccessibilitySize() { verifyTargets(accessibility: true) }

    private func verifyTargets(accessibility: Bool) {
        let app = XCUIApplication()
        if accessibility { app.launchArguments = ["--accessibility"] }
        app.launch()
        let buttons = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Mark as"))
        XCTAssertTrue(buttons.element(boundBy: 0).waitForExistence(timeout: 10))
        XCTAssertEqual(buttons.count, 6)
        // The taps are aimed at offsets from frames read once, so the rows must
        // have stopped moving first or a near-edge tap lands on a neighbour.
        XCTAssertTrue(buttons.element(boundBy: 5).waitForStableFrame(), "The checklist must settle before tapping")
        let first = buttons.element(boundBy: 0).frame
        let second = buttons.element(boundBy: 1).frame
        let pitch = second.midY - first.midY
        // Inside the grown horizontal target but outside the visible checkbox;
        // also exercise both sides of the gap between adjacent row centers.
        let taps: [(Int, CGFloat, CGFloat)] = [
            (0, -first.width / 2 + 4, 0),
            (1, first.width / 2 - 8, 0),
            (2, 0, -pitch / 2 + 3),
            (3, 0, pitch / 2 - 3),
            (4, 0, 0),
            (5, 0, 0),
        ]
        for (index, dx, dy) in taps {
            let button = buttons.element(boundBy: index)
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .withOffset(CGVector(dx: dx, dy: dy)).tap()
            for row in 0..<6 {
                XCTAssertEqual(
                    buttons.element(boundBy: row).label,
                    row <= index ? "Mark as not done" : "Mark as done", "tap \(index) changed the wrong row \(row)")
            }
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = accessibility ? "dense-accessibility-taps" : "dense-default-taps"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }
}
