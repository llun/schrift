import XCTest

@MainActor
final class OfflineControlsTests: XCTestCase {
    private func launch(uncached: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--offline-controls"] + (uncached ? ["--uncached"] : [])
        app.launch()
        // Home's offline banner: on every size class, and it shows only once the fixture's path
        // is down. (The compact Search shortcut no longer carries an offline footnote: offline it
        // opens Search over this device's documents.)
        let banner = offlineBanner(app, note: "All documents saved on this device")
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        app.absorbFirstTouch(on: banner)
        return app
    }

    /// `OfflineBanner` combines its status and note into one element labelled "Offline. <note>".
    private func offlineBanner(_ app: XCUIApplication, note: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Offline. \(note)")).firstMatch
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
        let attach = app.buttons["Attach"]
        if !attach.isHittable {
            // A swipe constrained to the leftmost 44pt button can leave the
            // toolbar unmoved. Drag across its visible interior instead.
            let end = add.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let start = end.withOffset(CGVector(dx: app.frame.width / 2, dy: 0))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        let revealed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: attach)
        XCTAssertEqual(XCTWaiter.wait(for: [revealed], timeout: 5), .completed)
        XCTAssertEqual(attach.frame.width, 44, accuracy: 1)
        XCTAssertEqual(attach.frame.height, 44, accuracy: 1)
        capture(app, "circular-formatting-actions")
        app.terminate()
    }

    /// The banner sits under the navigation bar rather than costing it its title: stacked above
    /// Home's scroll view, it left the large title and subtitle undrawn, a blank band under "+".
    func testHomeKeepsLargeTitleAndSubtitleWhileOffline() throws {
        let app = launch()
        guard app.buttons["Search docs.example.org"].exists else {
            app.terminate()
            throw XCTSkip("Home's large title belongs to the compact navigation stack.")
        }
        let banner = offlineBanner(app, note: "All documents saved on this device")
        let bar = app.navigationBars.firstMatch
        let title = bar.staticTexts["Schrift"]
        let subtitle = bar.staticTexts["docs.example.org"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "The large title is drawn while offline")
        XCTAssertTrue(subtitle.exists, "The server subtitle is drawn while offline")
        XCTAssertLessThanOrEqual(title.frame.maxY, banner.frame.minY + 1, "The title sits above the banner")
        XCTAssertLessThanOrEqual(subtitle.frame.maxY, banner.frame.minY + 1, "The subtitle sits above the banner")
        capture(app, "iphone-home-offline-large-title")
        app.terminate()
    }

    func testHomeAndPushedSearchAvailabilityTransitions() {
        let app = launch()
        let shortcut = app.buttons["Search docs.example.org"]
        if shortcut.exists {
            XCTAssertEqual(app.buttons.matching(identifier: "Search docs.example.org").count, 1)
            // Offline the shortcut still opens Search, which looks through this device's documents.
            XCTAssertTrue(shortcut.isEnabled)
            XCTAssertFalse(app.staticTexts["Search is available when online."].exists)
            capture(app, "iphone-home-search-offline")
            shortcut.tap()
            let field = app.searchFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            XCTAssertTrue(field.isEnabled)
            let localOnly = offlineBanner(app, note: "Results from this device only")
            XCTAssertTrue(localOnly.waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["Search is available when online."].exists)
            let title = app.navigationBars.firstMatch.staticTexts["Search"]
            XCTAssertTrue(title.exists, "The large title is drawn while offline")
            XCTAssertLessThanOrEqual(title.frame.maxY, localOnly.frame.minY + 1, "The title sits above the banner")
            field.tap()
            field.typeText("Roadmap")
            XCTAssertTrue(app.navigationBars.buttons.firstMatch.isEnabled, "Back remains available")
            capture(app, "iphone-pushed-search-offline")
            app.buttons["fixture.online"].tap()
            let noteGone = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: localOnly)
            XCTAssertEqual(XCTWaiter.wait(for: [noteGone], timeout: 5), .completed)
            XCTAssertTrue(field.isEnabled)
            XCTAssertEqual(field.value as? String, "Roadmap")
            capture(app, "iphone-search-reconnected")
            app.buttons["fixture.offline"].tap()
            XCTAssertTrue(localOnly.waitForExistence(timeout: 5))
            XCTAssertTrue(field.isEnabled, "Search keeps working offline, on this device's documents")
            XCTAssertEqual(field.value as? String, "Roadmap")
            XCTAssertTrue(app.navigationBars.buttons.firstMatch.isEnabled, "Back remains available")
            capture(app, "iphone-pushed-search-offline-again")
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
