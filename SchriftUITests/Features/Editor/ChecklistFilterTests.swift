import XCTest

@MainActor
final class ChecklistFilterTests: XCTestCase {
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--checklist-filter"] + arguments
        if arguments.contains("--accessibility") {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        }
        app.launch()
        XCTAssertTrue(app.switches["checklist.hideCompleted"].waitForExistence(timeout: 10))
        XCTAssertEqual(
            app.switches["checklist.hideCompleted"].value as? String,
            arguments.contains("--initially-hide-completed") ? "1" : "0")
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func enableCompletedFilter(in app: XCUIApplication) -> Bool {
        let toggle = app.switches["checklist.hideCompleted"]
        XCTAssertEqual(toggle.value as? String, "0")
        let nativeSwitch = toggle.switches.firstMatch
        guard nativeSwitch.waitForExistence(timeout: 5), nativeSwitch.isHittable else {
            XCTFail("The native Hide completed switch must be available for interaction")
            return false
        }
        // CI captured a correctly targeted 50ms tap that left the switch off.
        // Exercise one physical off-to-on gesture, without retrying or supplying
        // configured state, and verify it before testing projection/mode changes.
        nativeSwitch.swipeRight(velocity: .slow)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: toggle)
        guard XCTWaiter.wait(for: [enabled], timeout: 5) == .completed else {
            XCTFail("The Hide completed gesture must enable filtering before the flow continues")
            return false
        }
        return true
    }

    func testMixedDocumentFilterRevealAndEditingRetainEveryItem() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Finished one"].exists)
        guard enableCompletedFilter(in: app) else { return }
        XCTAssertTrue(app.buttons["checklist.showCompleted"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Finished one"].exists)
        XCTAssertFalse(app.staticTexts["Finished two"].exists)
        XCTAssertTrue(app.staticTexts["Next task"].exists)
        XCTAssertTrue(app.staticTexts["Introduction"].exists)
        XCTAssertTrue(app.staticTexts["First numbered"].exists)
        XCTAssertTrue(app.staticTexts["Second numbered"].exists)
        XCTAssertTrue(app.staticTexts["Tail paragraph"].exists)
        XCTAssertTrue(app.staticTexts["Completed items hidden: 2"].exists)
        capture(app, "mixed-filtered")
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["checklist.hideCompleted"].exists)
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == %@", "Finished one")).firstMatch.exists)
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == %@", "Finished two")).firstMatch.exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["checklist.showCompleted"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Finished one"].exists)
        app.buttons["checklist.showCompleted"].tap()
        XCTAssertTrue(app.staticTexts["Finished one"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Finished two"].exists)
        XCTAssertFalse(app.buttons["checklist.showCompleted"].exists)
        capture(app, "mixed-revealed")
        app.terminate()
    }

    func testAllCompletedHasAccessibleRevealAtDefaultSize() throws {
        try verifyAllCompleted([])
    }

    func testAllCompletedHasAccessibleRevealAtAccessibilitySize() throws {
        try verifyAllCompleted(["--accessibility"])
    }

    private func verifyAllCompleted(_ arguments: [String]) throws {
        let app = launch(["--all-completed"] + arguments)
        guard enableCompletedFilter(in: app) else { return }
        let reveal = app.buttons["checklist.showCompleted"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 5))
        XCTAssertTrue(reveal.isHittable)
        XCTAssertEqual(reveal.label, "Completed items hidden: 2. Show completed")
        XCTAssertGreaterThanOrEqual(reveal.frame.height, 44)
        XCTAssertFalse(app.staticTexts["Empty document"].exists)
        XCTAssertFalse(app.buttons["Start writing"].exists)
        XCTAssertFalse(app.staticTexts["Finished one"].exists)
        capture(app, arguments.isEmpty ? "all-completed-default" : "all-completed-accessibility")
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == %@", "Finished one")).firstMatch.exists)
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == %@", "Finished two")).firstMatch.exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(reveal.waitForExistence(timeout: 5))
        reveal.tap()
        XCTAssertTrue(app.staticTexts["Finished one"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Finished two"].exists)
        app.terminate()
    }

    func testRemoteReopeningImmediatelyRestoresTheHiddenRow() {
        // Establish the filtered state independently of a synthesized switch
        // tap, so this test isolates remote projection. The mixed/all-completed
        // flows above retain actual toggle and reveal interactions.
        let app = launch(["--initially-hide-completed"])
        XCTAssertTrue(app.buttons["checklist.showCompleted"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Completed items hidden: 2"].exists)
        XCTAssertFalse(app.staticTexts["Finished one"].exists)
        XCTAssertFalse(app.staticTexts["Finished two"].exists)
        app.buttons["fixture.remoteChange"].tap()
        XCTAssertTrue(app.staticTexts["Reopened remotely"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Completed items hidden: 1"].exists)
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == %@", "Reopened remotely")).firstMatch.exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Reopened remotely"].waitForExistence(timeout: 5))
        app.buttons["checklist.showCompleted"].tap()
        XCTAssertTrue(app.staticTexts["Finished two"].waitForExistence(timeout: 5))
        app.terminate()
    }

    func testReadingControlsAccessibilityAuditAtDefaultSize() throws {
        try auditReadingControls(accessibility: false)
    }

    func testReadingControlsAccessibilityAuditAtAccessibilitySize() throws {
        try auditReadingControls(accessibility: true)
    }

    private func auditReadingControls(accessibility: Bool) throws {
        // Audit the real production controls without excluding any findings. The
        // complete-editor tests separately check discovery/reveal, all-hidden mode
        // swaps and scrolling; existing toolbar/offline chrome is outside this audit.
        for filtered in [false, true] {
            // Audit each configured state independently. The complete-editor tests
            // above exercise the actual toggle/reveal interactions; this fixture
            // checks their semantics/layout without coupling to synthesized taps.
            let app = XCUIApplication()
            app.launchArguments = ["--reading-controls-audit"]
            if filtered { app.launchArguments += ["--audit-hidden-completed"] }
            if accessibility {
                app.launchArguments += [
                    "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL",
                ]
            }
            app.launch()
            let toggle = app.switches["checklist.hideCompleted"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 10))
            XCTAssertEqual(toggle.value as? String, filtered ? "1" : "0")
            if filtered {
                XCTAssertTrue(app.buttons["checklist.showCompleted"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.staticTexts["Completed items hidden: 2"].exists)
            } else {
                XCTAssertFalse(app.buttons["checklist.showCompleted"].exists)
            }
            try app.performAccessibilityAudit(for: [
                .elementDetection, .sufficientElementDescription, .dynamicType, .textClipped,
            ])
            XCTAssertEqual(toggle.value as? String, filtered ? "1" : "0")
            if filtered {
                XCTAssertTrue(app.buttons["checklist.showCompleted"].isHittable)
                capture(app, accessibility ? "controls-accessibility-audit" : "controls-default-audit")
            }
            app.terminate()
        }
    }

    func testFilteredScrollHandoffKeepsADeepVisibleTaskAcrossBothModes() {
        // Isolate scroll restoration from synthesized switch activation. The
        // mixed/all-completed flows exercise the actual toggle and reveal;
        // this fixture must be filtered before any viewport anchor is measured.
        let app = launch(["--long-checklist", "--initially-hide-completed"])
        XCTAssertTrue(app.buttons["checklist.showCompleted"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Completed items hidden: 40"].exists)
        XCTAssertFalse(app.staticTexts["Task 2"].exists)
        let target = app.staticTexts["Task 39"]
        for _ in 0..<12 {
            if target.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(target.isHittable)
        let firstVisible = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Task "))
            .allElementsBoundByIndex.filter { $0.isHittable }.min { $0.frame.minY < $1.frame.minY }
        XCTAssertNotNil(firstVisible)
        let anchorLabel = firstVisible?.label ?? "Missing visible task"
        capture(app, "filtered-deep-reading")
        // Toolbar Edit carries the measured viewport anchor; it cannot rely on
        // focusedBlockID scrolling, since this action requests no caret.
        app.buttons["Edit"].tap()
        let editor = app.textViews.matching(NSPredicate(format: "value == %@", anchorLabel)).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(editor.isHittable)
        capture(app, "full-deep-editing")
        app.buttons["Done"].tap()
        let restored = app.staticTexts[anchorLabel]
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        XCTAssertTrue(restored.isHittable)
        XCTAssertFalse(app.staticTexts["Task 38"].exists)
        capture(app, "filtered-deep-return")
        app.terminate()
    }
}
