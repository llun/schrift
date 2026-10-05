import XCTest

@MainActor
final class OfflineControlsTests: XCTestCase {
    private func launch(uncached: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--offline-controls"] + (uncached ? ["--uncached"] : [])
        app.launch()
        XCTAssertTrue(app.staticTexts["Search is available when online."].firstMatch.waitForExistence(timeout: 10))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openDocument(_ app: XCUIApplication) {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Offline fixture")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.buttons["Options"].waitForExistence(timeout: 5))
    }

    func testCircularIconControlsAndFormattingActionsRemainReachable() {
        let app = launch()
        openDocument(app)
        XCTAssertTrue(app.staticTexts["Cached readable body"].waitForExistence(timeout: 5))
        for label in ["Show pages", "Edit", "Options"] {
            let button = app.buttons[label]
            XCTAssertTrue(button.exists)
            XCTAssertTrue(button.isHittable, label)
            // UIKit accessibility bounds describe the label, not the glass outline.
            // The screenshot verifies the separate circular system surfaces.
        }
        capture(app, "circular-editor-toolbar")
        app.buttons["Options"].tap()
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        // Sheet presentation can scale the whole surface slightly. Logical 44pt
        // geometry is covered by ControlGeometryTests; its screen bounds stay square.
        XCTAssertEqual(close.frame.width, close.frame.height, accuracy: 1)
        XCTAssertGreaterThan(close.frame.width, 40)
        capture(app, "circular-sheet-close")
        close.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        let edit = app.buttons["Edit"]
        let editable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: edit)
        XCTAssertEqual(XCTWaiter.wait(for: [editable], timeout: 5), .completed)
        edit.tap()
        let add = app.buttons["Add block"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertEqual(add.frame.width, 44, accuracy: 1)
        XCTAssertEqual(add.frame.height, 44, accuracy: 1)
        let photo = app.buttons["Insert photo"]
        if !photo.isHittable {
            add.swipeLeft()
        }
        XCTAssertTrue(photo.isHittable)
        XCTAssertEqual(photo.frame.width, 44, accuracy: 1)
        XCTAssertEqual(photo.frame.height, 44, accuracy: 1)
        capture(app, "circular-formatting-actions")
        app.terminate()
    }

    func testHomeAndPushedSearchAvailabilityTransitions() {
        let app = launch()
        let shortcut = app.buttons["Search docs.example.org"]
        if shortcut.exists {
            XCTAssertEqual(app.buttons.matching(identifier: "Search docs.example.org").count, 1)
            XCTAssertFalse(shortcut.isEnabled)
            capture(app, "iphone-home-search-offline")
            app.buttons["fixture.online"].tap()
            XCTAssertTrue(shortcut.waitForExistence(timeout: 5))
            XCTAssertTrue(shortcut.isEnabled)
            shortcut.tap()
            XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
            app.searchFields.firstMatch.tap()
            app.searchFields.firstMatch.typeText("Roadmap")
            app.buttons["fixture.offline"].tap()
            XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5))
            XCTAssertFalse(app.textFields.firstMatch.isEnabled)
            XCTAssertTrue(app.navigationBars.buttons.firstMatch.isEnabled, "Back remains available")
            capture(app, "iphone-pushed-search-offline")
            app.buttons["fixture.online"].tap()
            XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(app.searchFields.firstMatch.value as? String, "Roadmap")
            capture(app, "iphone-search-reconnected")
        } else {
            XCTAssertTrue(app.textFields.firstMatch.exists)
            XCTAssertFalse(app.textFields.firstMatch.isEnabled)
            capture(app, "ipad-inline-search-offline")
            app.buttons["fixture.online"].tap()
            XCTAssertTrue(app.textFields.firstMatch.isEnabled)
            app.textFields.firstMatch.tap()
            app.textFields.firstMatch.typeText("Roadmap")
            app.buttons["fixture.workOffline"].tap()
            XCTAssertFalse(app.textFields.firstMatch.isEnabled)
            capture(app, "ipad-inline-work-offline")
            app.buttons["fixture.workOffline"].tap()
            XCTAssertTrue(app.textFields.firstMatch.isEnabled)
            XCTAssertEqual(app.textFields.firstMatch.value as? String, "Roadmap")
            capture(app, "ipad-inline-search-reconnected")
        }
        app.terminate()
    }

    func testCachedEditorAndOptionsWithholdShareAndExplainDisabledVersions() {
        let app = launch()
        openDocument(app)
        XCTAssertTrue(app.staticTexts["Cached readable body"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Edit"].isEnabled)
        XCTAssertFalse(app.buttons["Share"].exists)
        XCTAssertFalse(app.staticTexts["Couldn't load this document. Pull to refresh to try again."].exists)
        capture(app, "cached-editor-offline")
        app.buttons["Options"].tap()
        let version = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Version history")).firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 5))
        XCTAssertFalse(version.isEnabled)
        XCTAssertFalse(app.buttons["Share"].exists)
        XCTAssertTrue(app.staticTexts["Version history is available when online."].exists)
        capture(app, "options-offline")
        app.buttons["Close"].tap()
        app.buttons["fixture.online"].tap()
        XCTAssertTrue(app.buttons["Share"].waitForExistence(timeout: 5))
        app.buttons["Options"].tap()
        XCTAssertTrue(version.waitForExistence(timeout: 5))
        XCTAssertTrue(version.isEnabled)
        XCTAssertTrue(app.buttons["Share"].exists)
        version.tap()
        XCTAssertTrue(app.staticTexts["Current version"].waitForExistence(timeout: 5))
        capture(app, "versions-reconnected")
        app.terminate()
    }

    func testMountedOptionsSurfaceRestoresAndWithholdsControlsLive() {
        let app = XCUIApplication()
        app.launchArguments = ["--offline-controls", "--options-transitions"]
        app.launch()
        let version = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Version history")).firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 5))
        XCTAssertFalse(version.isEnabled)
        XCTAssertFalse(app.buttons["Share"].exists)
        app.buttons["fixture.online"].tap()
        XCTAssertTrue(version.isEnabled)
        XCTAssertTrue(app.buttons["Share"].exists)
        capture(app, "mounted-options-reconnected")
        app.buttons["fixture.workOffline"].tap()
        XCTAssertFalse(version.isEnabled)
        XCTAssertFalse(app.buttons["Share"].exists)
        XCTAssertTrue(app.staticTexts["Version history is available when online."].exists)
        capture(app, "mounted-options-work-offline")
        app.buttons["fixture.workOffline"].tap()
        XCTAssertTrue(version.isEnabled)
        XCTAssertTrue(app.buttons["Share"].exists)
        app.terminate()
    }

    func testUncachedTransportFailureOffersRetryWithoutAPathChange() {
        let app = XCUIApplication()
        app.launchArguments = ["--offline-controls", "--uncached", "--transport-failure"]
        app.launch()
        openDocument(app)
        XCTAssertTrue(app.staticTexts["Not available offline"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Retry"].isEnabled)
        XCTAssertFalse(app.buttons["Edit"].isEnabled)
        capture(app, "uncached-transport-failure-retry")
        app.buttons["Retry"].tap()
        XCTAssertTrue(app.staticTexts["Cached readable body"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Edit"].isEnabled)
        app.terminate()
    }

    func testUncachedEditorExplainsOnlineRequirementAndRecovers() {
        let app = launch(uncached: true)
        openDocument(app)
        XCTAssertTrue(app.staticTexts["Not available offline"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Open this document online first to save a copy on this device."].exists)
        XCTAssertFalse(app.buttons["Edit"].isEnabled)
        XCTAssertFalse(app.buttons["Start writing"].exists)
        XCTAssertFalse(app.staticTexts["Empty document"].exists)
        capture(app, "uncached-editor-offline")
        app.buttons["fixture.online"].tap()
        XCTAssertTrue(app.staticTexts["Cached readable body"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Edit"].isEnabled)
        XCTAssertTrue(app.buttons["Share"].exists)
        capture(app, "uncached-editor-reconnected")
        app.terminate()
    }
}
