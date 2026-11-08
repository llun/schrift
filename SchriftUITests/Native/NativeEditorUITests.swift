import XCTest

final class NativeEditorUITests: XCTestCase {
    func testProductionReaderScrollsWithoutOfferingEditingControls() {
        let app = XCUIApplication()
        app.launch()
        let reader = app.textViews["nativeEditor.text"]
        XCTAssertTrue(reader.waitForExistence(timeout: 10))
        XCTAssertTrue(reader.isHittable)
        reader.tap()
        XCTAssertEqual(app.keyboards.count, 0)
        reader.swipeUp()
        XCTAssertTrue(reader.isHittable)
    }

    func testDisposableNativeTypingFixtureAcceptsTextAndRefusesReturn() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-typing"]
        app.launch()
        let editor = app.textViews["nativeEditor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.025)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        editor.typeText("xyzproof")
        XCTAssertTrue((editor.value as? String)?.lowercased().contains("xyzproof") == true)
        let beforeReturn = editor.value as? String
        editor.typeText("\n")
        XCTAssertTrue(app.staticTexts["nativeEditor.inputNotice"].waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, beforeReturn)
    }
}
