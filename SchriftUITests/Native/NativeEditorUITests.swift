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

    /// The production open route (`EditorView` → `NativeEditorOpen`) over an
    /// owned replica, offline: real keyboard input is journaled durably,
    /// reported as saved on this device and restored after a relaunch.
    func testProductionOpenRouteTypesDurablyAndRestoresAfterRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-open", "--reset"]
        app.launch()
        let editor = app.textViews["nativeEditor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.025)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        editor.typeText("durableproof")
        XCTAssertTrue((editor.value as? String)?.lowercased().contains("durableproof") == true)
        XCTAssertTrue(app.staticTexts["Saved on this device"].waitForExistence(timeout: 5))
        app.terminate()

        app.launchArguments = ["--native-open"]
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue((editor.value as? String)?.lowercased().contains("durableproof") == true)
    }

    /// Synthetic marked text (the host's `--native-ime` buttons) in the real
    /// running route with the keyboard up: one durable commit, then a process
    /// kill mid-composition. The relaunch shows the recovery banner, never
    /// inserts the text by itself, and Insert writes it at the caret.
    func testSyntheticCompositionCommitsOnceAndRecoversAfterAKill() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-open", "--reset", "--native-ime"]
        app.launch()
        let editor = app.textViews["nativeEditor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.025)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["ime.compose"].tap()
        XCTAssertTrue(text(of: editor).contains("にほん"), "UIKit shows the marked text")
        app.buttons["ime.convert"].tap()
        app.buttons["ime.commit"].tap()
        XCTAssertEqual(text(of: editor).components(separatedBy: "日本").count, 2, "committed exactly once")
        XCTAssertTrue(app.staticTexts["Saved on this device"].waitForExistence(timeout: 5))

        app.buttons["ime.composeKana"].tap()
        XCTAssertTrue(text(of: editor).contains("かな"))
        app.terminate()

        app.launchArguments = ["--native-open", "--native-ime"]
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let recovered = app.staticTexts["nativeEditor.recovery.text"]
        XCTAssertTrue(recovered.waitForExistence(timeout: 5))
        XCTAssertEqual(recovered.label, "かな")
        XCTAssertFalse(text(of: editor).contains("かな"), "never inserted silently")
        XCTAssertTrue(text(of: editor).contains("日本"), "the commit was durable")
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.025)).tap()
        app.buttons["nativeEditor.recovery.insert"].tap()
        XCTAssertTrue(text(of: editor).contains("かな"))
        XCTAssertFalse(recovered.exists)
    }

    /// A real Japanese software keyboard, when this simulator has one enabled
    /// (`AppleKeyboards` is a device setting a UI test cannot change; enable it
    /// with `xcrun simctl spawn <udid> defaults write -g AppleKeyboards -array
    /// "ja_JP-Romaji@sw=QWERTY-Japanese;hw=Automatic" "en_US@sw=QWERTY;hw=Automatic"`).
    /// Romaji input is marked text until Return confirms it: one durable write.
    func testJapaneseKeyboardComposesAndConfirmsOnce() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--native-open", "--reset"]
        app.launch()
        let editor = app.textViews["nativeEditor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.025)).tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        // The Japanese Romaji keyboard labels its return key 改行.
        let japanese = keyboard.buttons["改行"]
        for _ in 0..<3 where !japanese.exists {
            guard keyboard.buttons["Next keyboard"].exists else { break }
            keyboard.buttons["Next keyboard"].tap()
        }
        guard japanese.exists else {
            throw XCTSkip(
                "No Japanese keyboard on this simulator; the synthetic host path covers composition. Keys: "
                    + keyboard.buttons.allElementsBoundByIndex.map { $0.label }.joined(separator: ","))
        }
        let before = text(of: editor)
        for key in ["n", "i", "h", "o", "n", "n"] { keyboard.keys[key].tap() }
        XCTAssertTrue(text(of: editor).contains("にほん"), "the IME shows marked text: \(text(of: editor).prefix(40))")
        XCTAssertFalse(app.staticTexts["Saved on this device"].exists, "provisional text is not a write")
        // With marked text the return key (identified as 改行) confirms instead.
        japanese.tap()
        XCTAssertTrue(app.staticTexts["Saved on this device"].waitForExistence(timeout: 5))
        XCTAssertEqual(text(of: editor).components(separatedBy: "にほん").count, 2, "committed exactly once")
        XCTAssertEqual(text(of: editor).count, before.count + 3)

        // Killed mid-composition: the relaunch offers the kana, never inserts it.
        for key in ["k", "a", "n", "a"] { keyboard.keys[key].tap() }
        XCTAssertTrue(text(of: editor).contains("かな"))
        app.terminate()
        app.launchArguments = ["--native-open"]
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let recovered = app.staticTexts["nativeEditor.recovery.text"]
        XCTAssertTrue(recovered.waitForExistence(timeout: 5))
        XCTAssertEqual(recovered.label, "かな")
        XCTAssertFalse(text(of: editor).contains("かな"))
        XCTAssertTrue(text(of: editor).contains("にほん"))
        app.buttons["nativeEditor.recovery.discard"].tap()
        XCTAssertFalse(recovered.exists)
        XCTAssertFalse(text(of: editor).contains("かな"))
    }

    /// Space, a digit and "。" on the Japanese keyboard: the space is written
    /// directly (no marked text) and must become one durable command, never
    /// reverted as unsupported input; the digit and "。" are marked and
    /// confirmed. Everything survives a relaunch.
    func testJapaneseKeyboardDirectCharactersAreJournaled() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--native-open", "--reset"]
        app.launch()
        let editor = app.textViews["nativeEditor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.025)).tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let japanese = keyboard.buttons["改行"]
        for _ in 0..<3 where !japanese.exists {
            guard keyboard.buttons["Next keyboard"].exists else { break }
            keyboard.buttons["Next keyboard"].tap()
        }
        guard japanese.exists else {
            throw XCTSkip("No Japanese keyboard on this simulator; the delegate seam covers direct characters")
        }
        let before = text(of: editor)
        keyboard.keys["space"].tap()
        keyboard.keys["more"].tap()
        keyboard.keys["1"].tap()
        let stop = keyboard.keys["。"]
        XCTAssertTrue(
            stop.exists,
            keyboard.keys.allElementsBoundByIndex.map { "\($0.identifier)|\($0.label)" }.joined(separator: ","))
        stop.tap()
        // The IME marks digits and punctuation (it offers full-width forms);
        // only the space went straight in. Return confirms the rest.
        XCTAssertTrue(keyboard.buttons["Return"].exists)
        keyboard.buttons["Return"].tap()

        XCTAssertFalse(app.staticTexts["nativeEditor.inputNotice"].exists, "direct input is never reverted")
        XCTAssertTrue(app.staticTexts["Saved on this device"].waitForExistence(timeout: 5))
        let after = text(of: editor)
        XCTAssertEqual(after.count, before.count + 3, after)
        XCTAssertTrue(after.contains("1。") || after.contains("１。"), after)

        app.terminate()
        app.launchArguments = ["--native-open"]
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(text(of: editor), after, "journaled, so it survives a relaunch")
    }

    private func text(of element: XCUIElement) -> String { element.value as? String ?? "" }
}
