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
        XCTAssertEqual(app.switches["checklist.hideCompleted"].value as? String, "0")
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMixedDocumentFilterRevealAndEditingRetainEveryItem() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Finished one"].exists)
        app.switches["checklist.hideCompleted"].tap()
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
        app.switches["checklist.hideCompleted"].tap()
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
        let app = launch()
        app.switches["checklist.hideCompleted"].tap()
        XCTAssertFalse(app.staticTexts["Finished one"].exists)
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
            // Accessibility audits exercise font-size changes. Relaunch each state
            // so the next interaction cannot use geometry left over from an audit.
            let app = XCUIApplication()
            app.launchArguments = ["--reading-controls-audit"]
            if accessibility {
                app.launchArguments += [
                    "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL",
                ]
            }
            app.launch()
            let toggle = app.switches["checklist.hideCompleted"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 10))
            XCTAssertEqual(toggle.value as? String, "0")
            if filtered {
                // SwiftUI's labeled AX switch wraps the actual UISwitch. Target
                // that native control rather than guessing a point in the label.
                let nativeSwitch = toggle.switches.firstMatch
                XCTAssertTrue(nativeSwitch.waitForExistence(timeout: 5))
                nativeSwitch.tap()
                let isOn = NSPredicate(format: "value == %@", "1")
                let enabled = XCTNSPredicateExpectation(predicate: isOn, object: toggle)
                XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
                XCTAssertTrue(app.buttons["checklist.showCompleted"].waitForExistence(timeout: 5))
            }
            try app.performAccessibilityAudit(for: [
                .elementDetection, .sufficientElementDescription, .dynamicType, .textClipped,
            ])
            if filtered {
                XCTAssertTrue(app.buttons["checklist.showCompleted"].isHittable)
                capture(app, accessibility ? "controls-accessibility-audit" : "controls-default-audit")
            }
            app.terminate()
        }
    }

    func testFilteredScrollHandoffKeepsADeepVisibleTaskAcrossBothModes() {
        let app = launch(["--long-checklist"])
        app.switches["checklist.hideCompleted"].tap()
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
