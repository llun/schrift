import XCTest

/// Exercises production screens with disposable local data and exports native screenshots.
@MainActor
final class ThemeFlowTests: XCTestCase {
    private func launch(theme: String, dark: Bool = false, accessibility: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            ["--offline-controls", "--theme-audit", "--theme-\(theme)"]
            + (dark ? ["--theme-dark"] : []) + (accessibility ? ["--theme-accessibility"] : [])
        app.launch()
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Offline fixture")).firstMatch
                .waitForExistence(timeout: 10))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func profile(_ app: XCUIApplication) {
        app.buttons["Profile"].firstMatch.tap()
        XCTAssertTrue(app.buttons["profile.theme"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["profile.account"].isEnabled)
    }

    private func openDocument(_ app: XCUIApplication) {
        app.buttons["Schrift"].firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Offline fixture")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Options"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Make room for the work."].waitForExistence(timeout: 5))
    }

    private func verifyNativeThemeCatalog(theme: String) {
        for dark in [false, true] {
            let name = "\(theme)-\(dark ? "dark" : "light")"
            let app = launch(theme: theme, dark: dark)
            capture(app, "theme-\(name)-home")
            profile(app)
            capture(app, "theme-\(name)-profile")
            app.buttons["profile.theme"].tap()
            XCTAssertTrue(app.buttons["theme.\(theme)"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["theme.\(theme)"].isSelected)
            capture(app, "theme-\(name)-picker")
            app.buttons["Close"].tap()
            app.buttons["profile.account"].tap()
            XCTAssertTrue(app.staticTexts["Full name"].waitForExistence(timeout: 5))
            capture(app, "theme-\(name)-account")
            app.navigationBars.buttons.firstMatch.tap()
            openDocument(app)
            capture(app, "theme-\(name)-reading")
            if theme == "paper" {
                app.buttons["Share"].tap()
                XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
                capture(app, "theme-\(name)-share")
                app.buttons["Close"].tap()
            }
            app.buttons["Edit"].tap()
            XCTAssertTrue(app.buttons["Add block"].waitForExistence(timeout: 5))
            capture(app, "theme-\(name)-editing")
            app.terminate()
        }
    }

    func testNativeWhiteScreensAcrossPairedAppearances() { verifyNativeThemeCatalog(theme: "white") }
    func testNativeMistScreensAcrossPairedAppearances() { verifyNativeThemeCatalog(theme: "mist") }
    func testNativePaperScreensAcrossPairedAppearances() { verifyNativeThemeCatalog(theme: "paper") }

    func testThemePickerRemainsOpenAndAppearanceStaysIndependent() {
        let app = launch(theme: "white", dark: true)
        profile(app)
        app.buttons["profile.theme"].tap()
        for theme in ["paper", "mist", "white"] {
            let row = app.buttons["theme.\(theme)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.tap()
            XCTAssertTrue(row.isSelected)
            XCTAssertTrue(app.buttons["Close"].exists)
        }
        app.buttons["Close"].tap()
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Appearance")).firstMatch.label.contains(
                "Dark"))
        capture(app, "theme-live-picker-retains-dark-appearance")
        app.terminate()
    }

    func testPaperAtAccessibilityTextSizeKeepsThemeAndAccountActionsReachable() {
        let app = launch(theme: "paper", accessibility: true)
        profile(app)
        capture(app, "theme-paper-accessibility-profile")
        app.buttons["profile.theme"].tap()
        let paper = app.buttons["theme.paper"]
        if !paper.isHittable { app.swipeUp() }
        XCTAssertTrue(paper.isHittable)
        paper.tap()
        capture(app, "theme-paper-accessibility-picker")
        app.buttons["Close"].tap()
        app.buttons["profile.account"].tap()
        XCTAssertTrue(app.staticTexts["Full name"].waitForExistence(timeout: 5))
        capture(app, "theme-paper-accessibility-account")
        app.terminate()
    }
}
