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
                XCTAssertTrue(app.staticTexts["Alex Martin"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.staticTexts["Camille Moreau"].exists)
                XCTAssertTrue(app.staticTexts["new.member@example.org"].exists)
                XCTAssertFalse(app.staticTexts["Couldn't load members. Pull to refresh to try again."].exists)
                capture(app, "theme-\(name)-share")
                app.buttons["Close"].tap()
            }
            app.buttons["Edit"].tap()
            XCTAssertTrue(app.buttons["Add block"].waitForExistence(timeout: 5))
            capture(app, "theme-\(name)-editing")
            app.terminate()
        }
    }

    /// Reads one pixel of a screenshot as 8-bit RGB, addressed in points.
    private func rgb(_ screenshot: XCUIScreenshot, x: CGFloat, y: CGFloat) throws -> [Int] {
        let image = screenshot.image
        let cgImage = try XCTUnwrap(image.cgImage)
        let scale = CGFloat(cgImage.width) / image.size.width
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(
            cgImage,
            in: CGRect(
                x: -x * scale, y: -(CGFloat(cgImage.height) - 1 - y * scale), width: CGFloat(cgImage.width),
                height: CGFloat(cgImage.height)))
        return pixel.prefix(3).map(Int.init)
    }

    /// The strip behind the status bar must be the detail canvas, not the system
    /// background. White's light page colour is white, which hid the split view's
    /// container showing the system colour there until the paired themes existed.
    /// The canvas is sampled low in the detail column, below any fixture content.
    private func assertTopSafeAreaMatchesDetailCanvas(_ app: XCUIApplication, _ name: String) throws {
        let screenshot = app.screenshot()
        let width = screenshot.image.size.width
        let strip = try rgb(screenshot, x: width * 0.75, y: 2)
        let canvas = try rgb(screenshot, x: width * 0.75, y: screenshot.image.size.height * 0.88)
        let delta = zip(strip, canvas).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThanOrEqual(delta, 3, "\(name): status strip \(strip) differs from the canvas \(canvas)")
    }

    func testRegularWidthStatusStripFollowsTheTheme() throws {
        // White's dark page (#16161C) differs from the system black too.
        for theme in ["white", "mist", "paper"] {
            for dark in [false, true] {
                let name = "\(theme)-\(dark ? "dark" : "light")"
                let app = launch(theme: theme, dark: dark)
                guard app.windows.firstMatch.frame.width >= 700 else {
                    app.terminate()
                    throw XCTSkip("The split view's container chrome only exists at regular width.")
                }
                try assertTopSafeAreaMatchesDetailCanvas(app, "\(name)-home")
                openDocument(app)
                try assertTopSafeAreaMatchesDetailCanvas(app, "\(name)-reading")
                app.terminate()
            }
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
