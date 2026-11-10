import XCTest

final class NativeEditorUITests: XCTestCase {
    /// A failed step must stop the test there: carrying on cascades through every later wait (a hosted run
    /// of one failure took twice as long as a pass) and buries the step that actually broke.
    override func setUp() {
        continueAfterFailure = false
    }

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

    func testDisposableNativeTypingFixtureAcceptsTextAndSplitsOnReturn() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-typing"]
        app.launch()
        let editor = app.textViews["nativeEditor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.025)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        editor.typeText("xyzproof")
        XCTAssertTrue(text(of: editor).lowercased().contains("xyzproof"))
        let blocks = text(of: editor).components(separatedBy: "\n").count
        editor.typeText("\n")
        XCTAssertEqual(text(of: editor).components(separatedBy: "\n").count, blocks + 1, "Return splits once")
        XCTAssertFalse(app.staticTexts["nativeEditor.inputNotice"].exists)
    }

    /// Return and Backspace on the real keyboard in the production open route:
    /// a split, a second Return's empty block joined away again, and the
    /// structure restored from the journal after a relaunch.
    func testReturnAndBackspaceAreDurableStructureAfterRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-open", "--reset"]
        app.launch()
        let editor = app.textViews["nativeEditor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.025)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let before = text(of: editor).components(separatedBy: "\n")
        editor.typeText("alpha")
        editor.typeText("\n")
        editor.typeText("\n")
        XCTAssertEqual(text(of: editor).components(separatedBy: "\n").count, before.count + 2)
        editor.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertFalse(app.staticTexts["nativeEditor.inputNotice"].exists, "Backspace is never refused here")
        XCTAssertEqual(text(of: editor).components(separatedBy: "\n").count, before.count + 1)
        editor.typeText("beta")
        let after = text(of: editor).components(separatedBy: "\n")
        XCTAssertEqual(after.count, before.count + 1, after.prefix(4).joined(separator: "|"))
        let split = after.firstIndex { $0.hasSuffix("alpha") }
        XCTAssertNotNil(split, after.prefix(4).joined(separator: "|"))
        if let split { XCTAssertTrue(after[split + 1].hasPrefix("beta"), after[split + 1]) }
        XCTAssertFalse(app.staticTexts["nativeEditor.inputNotice"].exists)
        XCTAssertTrue(app.staticTexts["Saved on this device"].waitForExistence(timeout: 5))
        app.terminate()

        app.launchArguments = ["--native-open"]
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(text(of: editor).components(separatedBy: "\n"), after, "the journal restores the structure")
    }

    /// Shift-Right on the hardware keyboard selects from inside the first
    /// paragraph into the second; typing replaces the selection as one durable
    /// range command (the paragraphs join) that a relaunch restores.
    func testShiftArrowSelectionAcrossParagraphsIsReplacedDurably() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-open", "--reset"]
        app.launch()
        let editor = app.textViews["nativeEditor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.025)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        editor.typeText("alpha")
        let lines = text(of: editor).components(separatedBy: "\n")
        guard lines.count > 2, let caret = lines[0].range(of: "alpha")?.upperBound else {
            return XCTFail(lines.prefix(3).joined(separator: "|"))
        }
        // The rest of the first paragraph, its separator and three characters.
        for _ in 0..<(lines[0][caret...].count + 4) {
            editor.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: .shift)
        }
        editor.typeText("omega")
        let after = text(of: editor).components(separatedBy: "\n")
        // iOS's smart insert may separate a word that arrives whole (iOS 26.5 delivers
        // `typeText` as one insertion), as it does in any text view.
        let head = String(lines[0][..<caret])
        let rest = String(lines[1].dropFirst(3))
        XCTAssertTrue(
            [head + "omega" + rest, head + " omega" + rest].contains(after.first ?? ""),
            "\(after.first ?? "") replaces the selection with omega")
        XCTAssertEqual(after.count, lines.count - 1, "the two paragraphs joined")
        XCTAssertFalse(app.staticTexts["nativeEditor.inputNotice"].exists)

        // The keyboard's delete key over a selection reaching the next
        // paragraph's start. (`typeKey` delivers no event at all for the
        // delete and forward-delete keys here.)
        guard let omega = after[0].range(of: "omega")?.upperBound else { return XCTFail(after[0]) }
        let tail = after[0][omega...].count
        for _ in 0..<(tail + 1) { editor.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: .shift) }
        editor.typeText(XCUIKeyboardKey.delete.rawValue)
        let joined = text(of: editor).components(separatedBy: "\n")
        XCTAssertEqual(joined.first, String(after[0].prefix(after[0].count - tail)) + after[1])
        XCTAssertEqual(joined.count, after.count - 1)
        XCTAssertFalse(
            app.staticTexts["nativeEditor.inputNotice"].exists, "Backspace over a selection is never refused")
        XCTAssertTrue(app.staticTexts["Saved on this device"].waitForExistence(timeout: 5))
        app.terminate()

        app.launchArguments = ["--native-open"]
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(text(of: editor).components(separatedBy: "\n"), joined, "the journal restores both commands")
    }

    /// A double tap selects a word; Bold is one durable mark command, so the
    /// word is still bold (the button reads as selected) after a relaunch.
    func testBoldOnASelectedWordSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-open", "--reset"]
        app.launch()
        let editor = app.textViews["nativeEditor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let word = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.025))
        word.doubleTap()
        let bold = app.buttons["nativeEditor.format.bold"]
        XCTAssertTrue(bold.waitForExistence(timeout: 5))
        XCTAssertFalse(bold.isSelected)
        bold.tap()
        XCTAssertTrue(bold.isSelected, "the selection is bold")
        XCTAssertFalse(app.staticTexts["nativeEditor.inputNotice"].exists)
        XCTAssertTrue(app.staticTexts["Saved on this device"].waitForExistence(timeout: 5))
        let before = text(of: editor)
        app.terminate()

        app.launchArguments = ["--native-open"]
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(text(of: editor), before, "a mark never changes the text")
        word.doubleTap()
        XCTAssertTrue(bold.waitForExistence(timeout: 5))
        XCTAssertTrue(bold.isSelected, "the journal restores the mark")
    }

    /// The checklist checkbox is a real button in the production open route:
    /// a tap is one durable prop command the journal restores after a relaunch.
    func testCheckboxTapSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-open", "--reset", "--native-blocks"]
        app.launch()
        let checkbox = app.buttons["nativeEditor.checkbox.owned-check"]
        XCTAssertTrue(checkbox.waitForExistence(timeout: 10))
        XCTAssertEqual(checkbox.value as? String, "Not done")
        XCTAssertTrue(checkbox.isEnabled)
        checkbox.tap()
        let checked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Done"), object: checkbox)
        XCTAssertEqual(XCTWaiter.wait(for: [checked], timeout: 5), .completed, "the tick is applied")
        XCTAssertFalse(app.staticTexts["nativeEditor.inputNotice"].exists)
        XCTAssertTrue(app.buttons["nativeEditor.codeLanguage.owned-code"].exists, "the code block's language menu")
        XCTAssertTrue(app.staticTexts["Saved on this device"].waitForExistence(timeout: 5))
        app.terminate()

        app.launchArguments = ["--native-open", "--native-blocks"]
        app.launch()
        XCTAssertTrue(checkbox.waitForExistence(timeout: 10))
        XCTAssertEqual(checkbox.value as? String, "Done", "the journal restores the tick")
    }

    /// Tab on the second bullet nests it under the first: one durable tree
    /// move in the production open route, still nested after a relaunch (the
    /// nested list keeps a Markdown shadow, so it reopens typeable).
    func testTabNestsTheSecondBulletAndSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-open", "--reset", "--native-tree"]
        app.launch()
        let editor = app.textViews["nativeEditor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.025)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let depths = app.staticTexts["tree.depths"]
        app.buttons["tree.read"].tap()
        XCTAssertEqual(depths.label, "0,0,0")
        app.buttons["tree.caret"].tap()
        app.typeKey(XCUIKeyboardKey.tab, modifierFlags: [])
        app.buttons["tree.read"].tap()
        XCTAssertEqual(depths.label, "0,1,0", "Tab nested the second bullet")
        XCTAssertFalse(app.staticTexts["nativeEditor.inputNotice"].exists)
        XCTAssertTrue(app.staticTexts["Saved on this device"].waitForExistence(timeout: 5))
        let before = text(of: editor)
        app.terminate()

        app.launchArguments = ["--native-open", "--native-tree"]
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(text(of: editor), before, "a move never changes the text")
        app.buttons["tree.read"].tap()
        XCTAssertEqual(depths.label, "0,1,0", "the journal restores the nesting")
        XCTAssertTrue(app.buttons["nativeEditor.format.indent"].waitForExistence(timeout: 5), "still typeable")
    }

    /// PR06d: the formatting bar's block menu duplicates the caret's block, one
    /// durable command in the production open route; the duplicate is still
    /// there after a relaunch.
    func testDuplicateFromTheBlockMenuSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-open", "--reset", "--native-tree"]
        app.launch()
        let editor = app.textViews["nativeEditor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.025)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let texts = app.staticTexts["tree.texts"]
        app.buttons["tree.read"].tap()
        XCTAssertEqual(texts.label, "Tree first|Tree second|Owned paragraph 1.")
        app.buttons["tree.caret"].tap()
        app.buttons["nativeEditor.format.block"].tap()
        let duplicate = app.buttons["nativeEditor.block.duplicate"]
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5))
        duplicate.tap()
        app.buttons["tree.read"].tap()
        XCTAssertEqual(texts.label, "Tree first|Tree second|Tree second", "the second bullet was duplicated")
        XCTAssertFalse(app.staticTexts["nativeEditor.inputNotice"].exists)
        XCTAssertTrue(app.staticTexts["Saved on this device"].waitForExistence(timeout: 5))
        app.terminate()

        app.launchArguments = ["--native-open", "--native-tree"]
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        app.buttons["tree.read"].tap()
        XCTAssertEqual(texts.label, "Tree first|Tree second|Tree second", "the journal restores the duplicate")
    }

    /// PR06b: the disclosure button folds and unfolds a toggle in the native
    /// host. Folded, the children leave the text VoiceOver reads; typing
    /// elsewhere leaves them alone, and unfolding shows them intact.
    func testFoldedToggleKeepsItsChildrenWhileTypingElsewhere() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-typing", "--native-toggle"]
        app.launch()
        let editor = app.textViews["nativeEditor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(editor.waitForStableFrame())
        let triangle = app.buttons["nativeEditor.toggle.fixture-toggle"]
        XCTAssertTrue(triangle.waitForExistence(timeout: 5))
        XCTAssertEqual(triangle.label, "Expand or collapse")
        XCTAssertEqual(triangle.value as? String, "Collapsed", "a toggle opens collapsed, as in BlockNote")
        XCTAssertFalse(text(of: editor).contains("Folded child"))
        triangle.tap()
        XCTAssertEqual(triangle.value as? String, "Expanded")
        XCTAssertTrue(text(of: editor).contains("Folded child one\nFolded child two"), text(of: editor))
        triangle.tap()
        XCTAssertEqual(triangle.value as? String, "Collapsed")
        XCTAssertFalse(text(of: editor).contains("Folded child"))

        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
        XCTAssertTrue(keyboard.waitForStableFrame())
        editor.typeText("elsewhere")
        XCTAssertTrue(waitForText(of: editor, containing: "elsewhere"), text(of: editor))
        XCTAssertFalse(app.staticTexts["nativeEditor.inputNotice"].exists)
        XCTAssertFalse(text(of: editor).contains("Folded child"))

        triangle.tap()
        XCTAssertEqual(triangle.value as? String, "Expanded")
        let unfolded = text(of: editor)
        XCTAssertTrue(unfolded.hasPrefix("Toggle title\nFolded child one\nFolded child two\n"), unfolded)
        XCTAssertEqual(unfolded.components(separatedBy: "Folded child").count, 3, "both children, once each")
        XCTAssertTrue(unfolded.contains("elsewhere"))
    }

    /// The production open route (`EditorView` → `NativeEditorOpen`) over an
    /// owned replica, offline: real keyboard input is journaled durably,
    /// reported as saved on this device and restored after a relaunch.
    func testProductionOpenRouteTypesDurablyAndRestoresAfterRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-open", "--reset"]
        app.launch()
        let editor = app.textViews["nativeEditor.text"]
        focusFirstParagraph(of: editor, in: app)
        editor.typeText("durableproof")
        XCTAssertTrue(waitForText(of: editor, containing: "durableproof"), text(of: editor))
        XCTAssertTrue(app.staticTexts["Saved on this device"].waitForExistence(timeout: 10))
        app.terminate()

        app.launchArguments = ["--native-open"]
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForText(of: editor, containing: "durableproof"), text(of: editor))
    }

    /// PR08b option A under `--native-slow-disk` (every journal append 60 ms
    /// slower): keys typed faster than the disk are shown at once and
    /// journaled in order behind it, Return is a barrier the keys after it wait
    /// for, and a relaunch restores every key in order.
    func testRapidTypingUnderSlowDiskSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-open", "--reset", "--native-slow-disk"]
        app.launch()
        let editor = app.textViews["nativeEditor.text"]
        focusFirstParagraph(of: editor, in: app)
        let before = text(of: editor).components(separatedBy: "\n")
        editor.typeText("rapidkeys")
        editor.typeText("\n")
        editor.typeText("afterbarrier")
        XCTAssertTrue(waitForText(of: editor, containing: "afterbarrier"), text(of: editor))
        XCTAssertFalse(app.staticTexts["nativeEditor.inputNotice"].exists, "no key was refused or dropped")
        let after = text(of: editor).components(separatedBy: "\n")
        XCTAssertEqual(after.count, before.count + 1, after.prefix(3).joined(separator: "|"))
        let split = after.firstIndex { $0.hasSuffix("rapidkeys") }
        XCTAssertNotNil(split, after.prefix(3).joined(separator: "|"))
        if let split { XCTAssertTrue(after[split + 1].hasPrefix("afterbarrier"), after[split + 1]) }
        XCTAssertTrue(app.staticTexts["Saved on this device"].waitForExistence(timeout: 10))
        // Shown is not yet journaled: terminate only once the slow appends drained.
        let idle = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "idle"), object: app.staticTexts["replica.inFlight"])
        XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 15), .completed)
        app.terminate()

        app.launchArguments = ["--native-open"]
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(text(of: editor).components(separatedBy: "\n"), after, "the journal holds every key in order")
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

    /// Hardware ⌘Z and ⇧⌘Z drive the collaborative history (PR07b): undo
    /// takes the typed word back out step by step (typing may span more than
    /// one 500 ms step), redo puts it back, and the undone state is journaled,
    /// so a relaunch restores it.
    func testHardwareUndoAndRedoAreDurableAfterRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-open", "--reset"]
        app.launch()
        let editor = app.textViews["nativeEditor.text"]
        focusFirstParagraph(of: editor, in: app)
        let before = text(of: editor)
        editor.typeText("undoproof")
        XCTAssertTrue(waitForText(of: editor, containing: "undoproof"), text(of: editor))
        var presses = 0
        while !waitForValue(of: editor, equalTo: before, timeout: 2), presses < 9 {
            editor.typeKey("z", modifierFlags: .command)
            presses += 1
        }
        XCTAssertEqual(text(of: editor), before, "⌘Z undoes the typing and nothing older")
        presses = 0
        while !waitForText(of: editor, containing: "undoproof", timeout: 2), presses < 9 {
            editor.typeKey("z", modifierFlags: [.command, .shift])
            presses += 1
        }
        XCTAssertTrue(text(of: editor).contains("undoproof"), "⇧⌘Z redoes it: \(text(of: editor))")
        while !waitForValue(of: editor, equalTo: before, timeout: 2), presses > 0 {
            editor.typeKey("z", modifierFlags: .command)
            presses -= 1
        }
        XCTAssertEqual(text(of: editor), before)
        XCTAssertFalse(app.staticTexts["nativeEditor.inputNotice"].exists)
        XCTAssertTrue(app.staticTexts["Saved on this device"].waitForExistence(timeout: 10))
        app.terminate()

        app.launchArguments = ["--native-open"]
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(text(of: editor), before, "the undo is journaled like any edit")
    }

    /// PR06e: images and tables scroll without jumping. Each drag must move
    /// every preview on screen together, until the
    /// document ends, and an image download (the fixture answers after 1.2 s)
    /// must move nothing. Visible positions are compared, not `contentOffset`,
    /// which TextKit's own re-anchoring changes invisibly. The S2 line heights
    /// show in the document's height: TextKit 2 sizes a paragraph it has not
    /// laid out from an estimate, and pinned, an attachment paragraph's
    /// estimate is its final height, so revealing the cards grows the document
    /// only by the text paragraphs' estimates (2,319 to 2,463 pt on the iOS 27
    /// simulator; without the pin 1,602 to 2,405 pt). The drags' own distance
    /// is not compared between drags: a loaded simulator's touch sampling
    /// shifts where the pan starts by ~12 pt (CI).
    func testImagesAndTablesScrollWithoutJumping() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-media"]
        app.launch()
        let reader = app.textViews["nativeEditor.text"]
        XCTAssertTrue(reader.waitForExistence(timeout: 10))
        let previews = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "nativeEditor.attachment."))
        XCTAssertTrue(previews.firstMatch.waitForExistence(timeout: 10))
        let readout = app.staticTexts["media.contentHeight"]
        XCTAssertTrue(readout.waitForExistence(timeout: 5))
        let viewport = reader.frame
        func positions() -> [String: CGFloat] {
            var result: [String: CGFloat] = [:]
            for element in previews.allElementsBoundByIndex where element.exists {
                let frame = element.frame
                guard frame.height > 0, frame.intersects(viewport) else { continue }
                result[element.identifier] = frame.minY
            }
            return result
        }
        func assertStill(_ before: [String: CGFloat], _ step: String) {
            let after = positions()
            for (id, y) in before {
                guard let now = after[id] else { continue }
                XCTAssertEqual(now, y, accuracy: 0.5, "\(id) moved while idle (\(step))")
            }
        }
        // The first images download while we watch.
        let start = positions()
        XCTAssertFalse(start.isEmpty)
        sleep(2)
        assertStill(start, "first download")
        let startHeight = Double(readout.label) ?? 0
        XCTAssertGreaterThan(startHeight, 0)
        var images = Set(start.keys.filter { $0.contains("media-img") })
        var tables = Set(start.keys.filter { $0.contains("media-tbl") })
        // The fixture's last block: once its card shows, a drag may stop at the end.
        let last = "nativeEditor.attachment.media-math-11"
        var reachedEnd = false
        for drag in 1...12 where !reachedEnd {
            let before = positions()
            let from = reader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            from.press(
                forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -300)),
                withVelocity: XCUIGestureVelocity(400), thenHoldForDuration: 0.4)
            let after = positions()
            let deltas = before.compactMap { id, y in after[id].map { $0 - y } }
            XCTAssertFalse(deltas.isEmpty, "some preview stays on screen across drag \(drag)")
            if let first = deltas.first {
                for delta in deltas {
                    XCTAssertEqual(delta, first, accuracy: 1, "previews moved apart in drag \(drag): \(deltas)")
                }
                // How far a drag carries depends on the runner's touch sampling and momentum
                // (CI: -242 to -432 pt for a 300 pt drag); jumps show as cards moving apart,
                // movement while idle, or the height check below.
                if before[last] == nil, after[last] == nil {
                    XCTAssertLessThan(first, -100, "drag \(drag) moved the content")
                }
                reachedEnd = abs(first) < 0.5
            }
            images.formUnion(after.keys.filter { $0.contains("media-img") })
            tables.formUnion(after.keys.filter { $0.contains("media-tbl") })
            // Newly revealed images download now; nothing may move.
            sleep(2)
            assertStill(after, "after drag \(drag)")
        }
        XCTAssertTrue(reachedEnd, "the drags reached the end of the document")
        XCTAssertGreaterThanOrEqual(images.count, 2, "the drags passed several images")
        XCTAssertGreaterThanOrEqual(tables.count, 2, "and several tables")
        let endHeight = Double(readout.label) ?? 0
        XCTAssertGreaterThan(endHeight, 0, "the content height readout is readable at the end")
        XCTAssertLessThan(
            endHeight - startHeight, 0.15 * endHeight,
            "revealed cards were estimated at their final height: \(startHeight) -> \(endHeight)")
    }

    private func text(of element: XCUIElement) -> String { element.value as? String ?? "" }

    /// Taps into the first paragraph only once the editor holds still, then waits for the keyboard to
    /// finish rising. A bare `waitForExistence` passes while the view is still laying out (the tap then
    /// lands where the paragraph no longer is and nothing is focused) and while the keyboard is still
    /// animating in (it is already "there", but not yet taking keys). On failure the screen is attached,
    /// so a hosted run shows whether the tap or the keyboard was the missing step.
    private func focusFirstParagraph(of editor: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(editor.waitForStableFrame(), "The editor must stop moving before it is tapped")
        XCTAssertTrue(editor.isHittable)
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.025)).tap()
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 10), keyboard.waitForStableFrame() else {
            let screen = XCTAttachment(screenshot: app.screenshot())
            screen.name = "Editor tap did not raise a settled keyboard"
            screen.lifetime = .keepAlways
            add(screen)
            return XCTFail("The tap must focus the editor and raise a settled keyboard before typing")
        }
    }

    /// Typed text is read back through the accessibility tree, which can trail the keystrokes; wait for the
    /// value instead of reading it once.
    private func waitForText(of element: XCUIElement, containing needle: String, timeout: TimeInterval = 10) -> Bool {
        let present = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS[c] %@", needle), object: element)
        return XCTWaiter.wait(for: [present], timeout: timeout) == .completed
    }

    private func waitForValue(of element: XCUIElement, equalTo expected: String, timeout: TimeInterval) -> Bool {
        let equal = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expected), object: element)
        return XCTWaiter.wait(for: [equal], timeout: timeout) == .completed
    }
}
