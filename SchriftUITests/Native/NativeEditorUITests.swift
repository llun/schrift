import UIKit
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
        focusFirstParagraph(of: editor, in: app)
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
        focusFirstParagraph(of: editor, in: app)
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
        XCTAssertTrue(editor.waitForStableFrame())
        let word = firstParagraphCoordinate(of: editor, in: app)
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

    /// PR11a: a web-shaped table in the production open route keeps the
    /// document typeable; its card opens the table editor, a tapped cell takes
    /// the keyboard, Tab moves to the next cell, and the typed cell text is
    /// durable. The active cell's label is hidden (its text view stands over
    /// it), so a label reappearing is the sign the editor moved on.
    ///
    /// Only an unmodified Tab is synthesized: on CI's iOS 26.5 simulator
    /// XCUITest's Shift-Tab never reached the cell (the editor, the active
    /// cell and the typed text were all there; run 43116995469), while Tab is
    /// delivered there (`testTabNestsTheSecondBulletAndSurvivesRelaunch`).
    /// Shift-Tab's move is covered by `TableEditorTests`.
    func testTypingInATableCellSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-open", "--reset", "--native-table"]
        app.launch()
        let card = app.descendants(matching: .any)["nativeEditor.attachment.owned-table"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["nativeEditor.preservedNotice"].exists, "the document types")
        card.tap()
        let ada = app.staticTexts["nativeEditor.table.text.1.0"]
        let empty = app.staticTexts["nativeEditor.table.text.1.1"]
        XCTAssertTrue(ada.waitForExistence(timeout: 5), "the table editor opened")
        ada.tap()
        XCTAssertTrue(ada.waitForNonExistence(timeout: 5), "the tapped cell is active")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.tab, modifierFlags: [])
        XCTAssertTrue(empty.waitForNonExistence(timeout: 5), "Tab moved to the next cell")
        XCTAssertTrue(ada.waitForExistence(timeout: 5))
        app.typeText("Engineer")
        // Tapping another cell moves the text view; the keyboard stays.
        app.staticTexts["nativeEditor.table.text.0.0"].tap()
        XCTAssertTrue(empty.waitForExistence(timeout: 5), "the typed cell is shown again")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "moving between cells keeps the keyboard")
        let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Engineer"), object: empty)
        XCTAssertEqual(XCTWaiter.wait(for: [typed], timeout: 5), .completed, "the cell holds the typed text")
        app.buttons["nativeEditor.table.done"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Saved on this device"].waitForExistence(timeout: 5))
        app.terminate()

        app.launchArguments = ["--native-open", "--native-table"]
        app.launch()
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        XCTAssertEqual(empty.value as? String, "Engineer", "the journal restores the cell")
        // The first cell is active: the cell's text view shows only its text.
        XCTAssertEqual(app.textViews["nativeEditor.table.cell"].value as? String, "Name\n")
    }

    /// PR12a: the group's card opens the column editor; typing in one column,
    /// switching to the other with the picker (the keyboard stays) and typing
    /// there are durable, and the document shows the group as one card.
    /// PR13a: a document holding a captioned image and a file types; the
    /// image's inspector edits its caption (one durable command, which
    /// survives a relaunch); offline it still offers an upload, which queues
    /// (PR13b).
    func testAMediaCaptionEditedInTheInspectorSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-open", "--reset", "--native-media-edit"]
        app.launch()
        let card = app.descendants(matching: .any)["nativeEditor.attachment.owned-image"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["nativeEditor.attachment.owned-file"].exists)
        XCTAssertFalse(app.staticTexts["nativeEditor.preservedNotice"].exists, "the document types")
        card.tap()
        let caption = app.textFields["nativeMedia.caption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5), "the inspector opened")
        XCTAssertEqual(caption.value as? String, "Old caption")
        XCTAssertTrue(app.buttons["nativeMedia.uploadFile"].isEnabled, "offline: an upload queues (PR13b)")
        // The inspector follows the document: hiding the preview flips the switch it reads back.
        let preview = app.switches["nativeMedia.preview"]
        XCTAssertEqual(preview.value as? String, "1")
        preview.switches.firstMatch.press(forDuration: 0.2)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: preview)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed, "the switch reads the written prop")
        caption.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // The tap leaves the caret at the end: delete "Old caption", then type.
        caption.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 11) + "Harbour at dawn")
        app.buttons["nativeMedia.done"].tap()
        // Shown by name while its preview is hidden; the caption is in the inspector.
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        XCTAssertEqual(caption.value as? String, "Harbour at dawn")
        preview.switches.firstMatch.press(forDuration: 0.2)
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: preview)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 5), .completed)
        app.buttons["nativeMedia.done"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let captioned = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "Harbour at dawn"), object: card)
        XCTAssertEqual(XCTWaiter.wait(for: [captioned], timeout: 5), .completed, "the card shows the caption")
        XCTAssertTrue(app.staticTexts["Saved on this device"].waitForExistence(timeout: 5))
        app.terminate()

        app.launchArguments = ["--native-open", "--native-media-edit"]
        app.launch()
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "Harbour at dawn"), object: card)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed, "the journal restores the caption")
    }

    func testTypingInBothColumnsSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-open", "--reset", "--native-columns"]
        app.launch()
        let card = app.descendants(matching: .any)["nativeEditor.attachment.owned-columns"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["nativeEditor.preservedNotice"].exists, "the document types")
        card.tap()
        let first = app.textViews["nativeEditor.column.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 5), "the column editor opened")
        first.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // Where the tap leaves the caret varies, so the checks look for the typed word. No space at
        // either end of a paragraph mid-typing: a save captured then has no shadow (a known limit).
        app.typeText("ward")
        let typedFirst = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "ward"), object: first)
        XCTAssertEqual(XCTWaiter.wait(for: [typedFirst], timeout: 5), .completed, "the first column holds the text")
        let picker = app.segmentedControls["nativeEditor.columns.picker"]
        XCTAssertTrue(picker.exists)
        picker.buttons.element(boundBy: 1).tap()
        let second = app.textViews["nativeEditor.column.1"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.exists, "switching columns keeps the keyboard")
        app.typeText("ful")
        let typed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "ful"), object: second)
        XCTAssertEqual(XCTWaiter.wait(for: [typed], timeout: 5), .completed, "the second column holds the text")
        app.buttons["nativeEditor.columns.done"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Saved on this device"].waitForExistence(timeout: 5))
        app.terminate()

        app.launchArguments = ["--native-open", "--native-columns"]
        app.launch()
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let restoredFirst = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "ward"), object: first)
        XCTAssertEqual(
            XCTWaiter.wait(for: [restoredFirst], timeout: 5), .completed,
            "the journal restores column one: \(first.value ?? "nil")")
        app.segmentedControls["nativeEditor.columns.picker"].buttons.element(boundBy: 1).tap()
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertEqual((second.value as? String)?.contains("ful"), true, "and column two")
    }

    /// PR12b: the column editor's Column menu inserts a column, which shows at
    /// once and survives a relaunch.
    func testTheColumnMenuInsertsAColumnThatSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-open", "--reset", "--native-columns"]
        app.launch()
        let card = app.descendants(matching: .any)["nativeEditor.attachment.owned-columns"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        let picker = app.segmentedControls["nativeEditor.columns.picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "the column editor opened")
        XCTAssertEqual(picker.buttons.count, 2)
        let menu = app.buttons["nativeEditor.columns.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let insert = app.buttons["nativeEditor.columns.addRight"]
        XCTAssertTrue(insert.waitForExistence(timeout: 5))
        insert.tap()
        let three = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 3"), object: picker.buttons)
        XCTAssertEqual(XCTWaiter.wait(for: [three], timeout: 5), .completed, "a third column shows")
        app.buttons["nativeEditor.columns.done"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Saved on this device"].waitForExistence(timeout: 5))
        app.terminate()

        app.launchArguments = ["--native-open", "--native-columns"]
        app.launch()
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(picker.buttons.count, 3, "the journal keeps the column")
    }

    /// PR12a review: returning from a column's table editor keeps one surface per
    /// column, and typing in the column afterwards is durable.
    func testTypingAfterAColumnsTableSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-open", "--reset", "--native-columns", "--native-column-table"]
        app.launch()
        let card = app.descendants(matching: .any)["nativeEditor.attachment.owned-columns"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["nativeEditor.preservedNotice"].exists, "the document types")
        card.tap()
        let first = app.textViews["nativeEditor.column.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 5), "the column editor opened")
        let tableCard = app.descendants(matching: .any)["nativeEditor.attachment.owned-column-table"]
        XCTAssertTrue(tableCard.waitForExistence(timeout: 5))
        tableCard.tap()
        let done = app.buttons["nativeEditor.table.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "the table editor opened over the column")
        done.tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        // Every column shows (PR12c: stacked here), one text view each.
        let picker = app.segmentedControls["nativeEditor.columns.picker"]
        XCTAssertEqual(
            app.textViews.matching(identifier: "nativeEditor.column.0").count, 1, "one surface per column")
        XCTAssertEqual(app.textViews.matching(identifier: "nativeEditor.column.1").count, 1)
        picker.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(app.textViews["nativeEditor.column.1"].waitForExistence(timeout: 5))
        picker.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        // On the paragraph: below the column's last block (the table) the caret is the table's,
        // which takes no text.
        first.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 30, dy: 22)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("ward")
        let typed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "ward"), object: first)
        XCTAssertEqual(XCTWaiter.wait(for: [typed], timeout: 5), .completed, "the column holds the text")
        app.buttons["nativeEditor.columns.done"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Saved on this device"].waitForExistence(timeout: 5))
        app.terminate()

        app.launchArguments = ["--native-open", "--native-columns", "--native-column-table"]
        app.launch()
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "ward"), object: first)
        XCTAssertEqual(
            XCTWaiter.wait(for: [restored], timeout: 5), .completed, "the journal keeps it: \(first.value ?? "nil")")
    }

    /// PR12c: typing a query whose match is inside a column keeps typing in
    /// the find field; Next then closes the outline and opens the column
    /// editor at that block without taking the keyboard (PR #285 F1).
    func testAFindMatchInAColumnOpensTheColumnEditorThere() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-open", "--reset", "--native-columns"]
        app.launch()
        let card = app.descendants(matching: .any)["nativeEditor.attachment.owned-columns"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let options = app.buttons["Options"]
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        options.tap()
        let outline = app.buttons["In this document"]
        XCTAssertTrue(outline.waitForExistence(timeout: 5))
        outline.tap()
        let field = app.textFields["Find in this document"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Right")
        // Typing the query only follows it in the document: the whole word is in the field.
        let second = app.textViews["nativeEditor.column.1"]
        XCTAssertFalse(second.waitForExistence(timeout: 2), "no column editor while the query is typed")
        XCTAssertEqual(field.value as? String, "Right")
        XCTAssertTrue(app.staticTexts["1 of 1"].exists)
        // A deliberate step opens it at the match, without the keyboard.
        app.buttons["Next match"].tap()
        XCTAssertTrue(second.waitForExistence(timeout: 10), "the column editor opened")
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "the outline closed")
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 2), "it did not take the keyboard")
        // The column's value ends with the text's closing separator.
        XCTAssertEqual(
            (second.value as? String)?.trimmingCharacters(in: .newlines), "Right", "nothing typed")
        app.buttons["nativeEditor.columns.done"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
    }

    /// PR12c on iPad (regular width): the columns sit side by side, both take
    /// typing, and rotating keeps the keyboard and the text; it survives a relaunch.
    func testColumnsSitSideBySideOnIPadAndKeepTypingThroughRotation() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "regular width")
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--native-open", "--reset", "--native-columns"]
        app.launch()
        let card = app.descendants(matching: .any)["nativeEditor.attachment.owned-columns"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        let first = app.textViews["nativeEditor.column.0"]
        let second = app.textViews["nativeEditor.column.1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertTrue(second.waitForStableFrame())
        XCTAssertEqual(first.frame.minY, second.frame.minY, accuracy: 1, "top-aligned")
        XCTAssertGreaterThan(second.frame.minX, first.frame.maxX, "side by side")
        XCTAssertEqual(first.frame.width, second.frame.width, accuracy: 2, "equal widths")
        second.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("ward")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(second.waitForStableFrame())
        XCTAssertTrue(app.keyboards.firstMatch.exists, "rotation keeps the keyboard")
        XCTAssertGreaterThan(second.frame.minX, first.frame.maxX, "still side by side")
        app.typeText("ly")
        let typed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "wardly"), object: second)
        XCTAssertEqual(
            XCTWaiter.wait(for: [typed], timeout: 5), .completed, "typing went on in place: \(second.value ?? "nil")")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(second.waitForStableFrame())
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        first.tap()
        app.typeText("ful")
        let typedFirst = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "ful"), object: first)
        XCTAssertEqual(XCTWaiter.wait(for: [typedFirst], timeout: 5), .completed)
        app.buttons["nativeEditor.columns.done"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Saved on this device"].waitForExistence(timeout: 5))
        app.terminate()

        app.launchArguments = ["--native-open", "--native-columns"]
        app.launch()
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "wardly"), object: second)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed, "the journal keeps it")
        XCTAssertEqual((first.value as? String)?.contains("ful"), true)
    }

    /// PR11c: a long press and drag selects two cells, and the Cell menu
    /// merges them: one durable command that survives a relaunch.
    func testDraggingAcrossCellsSelectsThemAndTheCellMenuMergesThem() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-open", "--reset", "--native-table"]
        app.launch()
        let card = app.descendants(matching: .any)["nativeEditor.attachment.owned-table"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        let ada = app.staticTexts["nativeEditor.table.text.1.0"]
        let empty = app.staticTexts["nativeEditor.table.text.1.1"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5), "the table editor opened")
        ada.press(forDuration: 0.8, thenDragTo: empty)
        let cellMenu = app.buttons["nativeEditor.table.menu.cell"]
        XCTAssertTrue(cellMenu.waitForExistence(timeout: 5))
        cellMenu.tap()
        let merge = app.buttons["Merge cells"]
        XCTAssertTrue(merge.waitForExistence(timeout: 5), "two selected cells merge")
        merge.tap()
        XCTAssertTrue(empty.waitForNonExistence(timeout: 5), "one cell spans both")
        XCTAssertFalse(app.staticTexts["nativeEditor.inputNotice"].exists)
        app.buttons["nativeEditor.table.done"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Saved on this device"].waitForExistence(timeout: 5))
        app.terminate()

        app.launchArguments = ["--native-open", "--native-table"]
        app.launch()
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        XCTAssertTrue(app.staticTexts["nativeEditor.table.text.0.1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["nativeEditor.table.text.1.1"].exists, "the merge was journaled")
    }

    /// PR11b: the table editor's Row menu inserts a row below the active cell's
    /// row, one durable structure command that survives a relaunch.
    func testTheRowMenuInsertsARowThatSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-open", "--reset", "--native-table"]
        app.launch()
        let card = app.descendants(matching: .any)["nativeEditor.attachment.owned-table"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        let ada = app.staticTexts["nativeEditor.table.text.1.0"]
        XCTAssertTrue(ada.waitForExistence(timeout: 5), "the table editor opened")
        let rowMenu = app.buttons["nativeEditor.table.menu.row"]
        XCTAssertTrue(rowMenu.waitForExistence(timeout: 5), "the Row menu shows while editing")
        rowMenu.tap()
        let insert = app.buttons["Insert row below"]
        XCTAssertTrue(insert.waitForExistence(timeout: 5))
        insert.tap()
        // The first row's cell is active: the new row goes between it and Ada's.
        let moved = app.staticTexts["nativeEditor.table.text.2.0"]
        XCTAssertTrue(moved.waitForExistence(timeout: 5), "a third row")
        XCTAssertEqual(moved.value as? String, "Ada")
        XCTAssertFalse(app.staticTexts["nativeEditor.inputNotice"].exists)
        app.buttons["nativeEditor.table.done"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Saved on this device"].waitForExistence(timeout: 5))
        app.terminate()

        app.launchArguments = ["--native-open", "--native-table"]
        app.launch()
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertEqual(card.label, "Table, 3 by 2", "the journal restores the row")
        card.tap()
        XCTAssertTrue(moved.waitForExistence(timeout: 5))
        XCTAssertEqual(moved.value as? String, "Ada")
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
        focusFirstParagraph(of: editor, in: app)
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
        focusFirstParagraph(of: editor, in: app)
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
        focusFirstParagraph(of: editor, in: app)
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

    /// PR10b: the native editor's "In this document" sheet finds a block and
    /// steps to it with the canvas behind it; nothing a jump does changes text.
    func testOutlineFindsInTheNativeEditorWithoutChangingText() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-typing"]
        app.launch()
        let editor = app.textViews["nativeEditor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let before = text(of: editor)
        let outline = app.buttons["nativeEditor.outline"]
        XCTAssertTrue(outline.waitForExistence(timeout: 5))
        outline.tap()
        let field = app.textFields["Find in this document"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Paragraph 25:")
        XCTAssertTrue(app.staticTexts["1 of 1"].waitForExistence(timeout: 5), "one match, stepped to")
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertEqual(text(of: editor), before, "a jump changes no text")
    }

    /// PR10b review: with a caret in an early paragraph, a jump made from the
    /// sheet is not undone when it closes (UIKit handing focus back would
    /// scroll to the caret).
    func testAJumpSurvivesClosingTheSheetWithACaretAbove() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-typing", "--native-readout"]
        app.launch()
        let editor = app.textViews["nativeEditor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(editor.waitForStableFrame())
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        app.buttons["nativeEditor.outline"].tap()
        let field = app.textFields["Find in this document"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Paragraph 12:")
        XCTAssertTrue(app.staticTexts["1 of 1"].waitForExistence(timeout: 5))
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        let top = app.staticTexts["nativeEditor.topBlock"]
        XCTAssertTrue(top.waitForExistence(timeout: 5))
        // Settled after the dismissal: it must still be the match, not the caret's block.
        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", "fixture-11"), object: top)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 3), .timedOut, "still at the match: \(top.label)")
    }

    /// PR10: a collaborator's cursor is painted where they are, a peer in a
    /// folded toggle badges the toggle until it opens, both show in the
    /// presence bar, and a cursor scrolled off screen is not painted.
    func testPeerCursorsPaintVisibleGeometryAndBadgeFoldedContent() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-typing", "--native-toggle", "--native-peer"]
        app.launch()
        let editor = app.textViews["nativeEditor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let cursor = app.descendants(matching: .any)["nativeEditor.peerCursor.7"]
        XCTAssertTrue(cursor.waitForExistence(timeout: 10))
        XCTAssertEqual(cursor.label, "Web Peer, cursor")
        let badge = app.descendants(matching: .any)["nativeEditor.peerBadge.8"]
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "a peer in folded content badges its toggle")
        XCTAssertTrue(app.descendants(matching: .any)["nativeEditor.presence"].waitForExistence(timeout: 5))
        XCTAssertTrue(editor.frame.intersects(cursor.frame))

        app.buttons["nativeEditor.toggle.fixture-toggle"].tap()
        let folded = app.descendants(matching: .any)["nativeEditor.peerCursor.8"]
        XCTAssertTrue(folded.waitForExistence(timeout: 5), "opened, the caret replaces the badge")
        XCTAssertFalse(badge.exists)

        for _ in 0..<4 { editor.swipeUp(velocity: .fast) }
        XCTAssertTrue(cursor.waitForNonExistence(timeout: 10), "scrolled away, it is not painted")
        XCTAssertTrue(text(of: editor).contains("Paragraph"), "nothing a peer did changed the text")
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
        focusFirstParagraph(of: editor, in: app)
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
        focusFirstParagraph(of: editor, in: app)
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
        XCTAssertTrue(editor.waitForStableFrame())
        firstParagraphCoordinate(of: editor, in: app).tap()
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
        XCTAssertTrue(editor.waitForStableFrame())
        firstParagraphCoordinate(of: editor, in: app).tap()
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

    /// PR13c2: typing `[[Road` opens the page-link picker, selecting a page inserts
    /// a resolved-title chip without `mentionSearchInline`, tapping outside dismisses
    /// the picker leaving `[[` prose untouched, and relaunch preserves the chip.
    func testDoubleBracketPageLinkInsertDismissAndRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-inline-objects", "--reset"]
        app.launch()
        let editor = app.textViews["nativeEditor.text"]
        focusTopParagraph(of: editor, in: app)

        editor.typeText("See [[Road")
        let roadmap = app.buttons["Product Roadmap"]
        XCTAssertTrue(roadmap.waitForExistence(timeout: 5), "page-link picker offers Product Roadmap")
        roadmap.tap()
        XCTAssertTrue(roadmap.waitForNonExistence(timeout: 5))
        XCTAssertTrue(
            waitForText(of: editor, containing: "See Page: Product Roadmap"),
            "interlink chip renders resolved title: \(text(of: editor))")
        XCTAssertFalse(text(of: editor).contains("[[Road"))

        // Typing `[[Ar` then tapping outside the picker dismisses it and leaves literal prose.
        editor.typeText(" [[Ar")
        let architecture = app.buttons["Architecture Notes"]
        XCTAssertTrue(architecture.waitForExistence(timeout: 5))
        editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 22, dy: topParagraphY(in: app))).tap()
        XCTAssertTrue(architecture.waitForNonExistence(timeout: 5), "Tapping outside dismisses page-link picker")
        XCTAssertTrue(waitForText(of: editor, containing: "[[Ar"))

        waitForDurableJournal(in: app)
        app.terminate()

        app.launchArguments = ["--native-inline-objects"]
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitForText(of: editor, containing: "See Page: Product Roadmap"),
            "relaunch keeps the interlink chip and resolved title: \(text(of: editor))")
        XCTAssertTrue(text(of: editor).contains("[[Ar"))
    }

    /// PR13c2: `/link` opens Slash "Link a page", picking inserts an interlink chip
    /// without `/link`, Backspace on an empty session cancels without zombie chips,
    /// and relaunch preserves the inserted chip.
    func testSlashLinkPageInsertDismissAndRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-inline-objects", "--reset"]
        app.launch()
        let editor = app.textViews["nativeEditor.text"]
        focusTopParagraph(of: editor, in: app)

        editor.typeText("/link")
        let slashLink = app.buttons["Link a page"]
        XCTAssertTrue(slashLink.waitForExistence(timeout: 5), "slash menu offers Link a page")
        slashLink.tap()

        let architecture = app.buttons["Architecture Notes"]
        XCTAssertTrue(architecture.waitForExistence(timeout: 5), "page-link picker opens after consuming /link")
        architecture.tap()
        XCTAssertTrue(architecture.waitForNonExistence(timeout: 5))
        XCTAssertTrue(
            waitForText(of: editor, containing: "Page: Architecture Notes"),
            "slash Link a page inserts chip: \(text(of: editor))")
        XCTAssertFalse(text(of: editor).contains("/link"))

        // Start a fresh paragraph, open slash "Link a page", then press Backspace: clean paragraph, zero zombies.
        editor.typeText("\n/link")
        XCTAssertTrue(slashLink.waitForExistence(timeout: 5))
        slashLink.tap()
        let roadmap = app.buttons["Product Roadmap"]
        XCTAssertTrue(roadmap.waitForExistence(timeout: 5))
        editor.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(roadmap.waitForNonExistence(timeout: 5), "Backspace cancels empty slash page-link session")
        let valueAfterDismiss = text(of: editor)
        XCTAssertFalse(valueAfterDismiss.contains("/link"), valueAfterDismiss)
        XCTAssertFalse(valueAfterDismiss.contains("Mention:"), "zero zombie mentionSearchInline: \(valueAfterDismiss)")
        XCTAssertFalse(valueAfterDismiss.contains("[["), valueAfterDismiss)
        XCTAssertEqual(
            valueAfterDismiss.components(separatedBy: "Page:").count - 1, 1,
            "expected exactly one Page: chip: \(valueAfterDismiss)")

        waitForDurableJournal(in: app)
        app.terminate()

        app.launchArguments = ["--native-inline-objects"]
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitForText(of: editor, containing: "Page: Architecture Notes"),
            "relaunch keeps slash-inserted interlink chip: \(text(of: editor))")
        XCTAssertFalse(text(of: editor).contains("Mention:"))
    }

    /// PR13c2: `@ada` fetches mocked accesses, omits `.reader` users, inserts `@Ada Lovelace`,
    /// ignores `user@example.com`, dismisses cleanly on tap outside, and survives relaunch.
    func testMentionInsertFiltersReadersIgnoresEmailsAndSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-inline-objects", "--reset"]
        app.launch()
        let editor = app.textViews["nativeEditor.text"]
        focusTopParagraph(of: editor, in: app)

        let mentionPicker = app.descendants(matching: .any)["editor.mentionPicker"]
        editor.typeText("user@example.com ")
        XCTAssertFalse(mentionPicker.waitForExistence(timeout: 1.5), "email mid-word must not open mention picker")

        editor.typeText("@ada")
        XCTAssertTrue(mentionPicker.waitForExistence(timeout: 5), "mention picker opens after whitespace")
        let adaRow = app.buttons["editor.mentionPicker.row.aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]
        XCTAssertTrue(adaRow.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.buttons["editor.mentionPicker.row.cccccccc-cccc-4ccc-8ccc-cccccccccccc"].exists,
            "reader access must be excluded")
        XCTAssertFalse(
            app.buttons["editor.mentionPicker.row.dddddddd-dddd-4ddd-8ddd-dddddddddddd"].exists,
            "max_role=reader access must be excluded")
        adaRow.tap()
        XCTAssertTrue(mentionPicker.waitForNonExistence(timeout: 5))
        XCTAssertTrue(
            waitForText(of: editor, containing: "user@example.com Mention: @Ada Lovelace"),
            "mention chip rendered: \(text(of: editor))")

        // Typing `@grace` then tapping outside the picker dismisses without writing a chip.
        editor.typeText(" @grace")
        let graceRow = app.buttons["editor.mentionPicker.row.bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"]
        XCTAssertTrue(graceRow.waitForExistence(timeout: 5))
        // Line 2 wraps `@grace` near `topParagraphY`; tap the start of line 1 (`user@example.com`).
        let firstLineY = app.buttons["Options"].exists ? 112 : topParagraphY(in: app)
        editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 22, dy: firstLineY)).tap()
        XCTAssertTrue(mentionPicker.waitForNonExistence(timeout: 5), "Tapping outside dismisses mention picker")
        XCTAssertTrue(waitForText(of: editor, containing: "@grace"))

        waitForDurableJournal(in: app)
        app.terminate()

        app.launchArguments = ["--native-inline-objects"]
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitForText(of: editor, containing: "user@example.com Mention: @Ada Lovelace"),
            "relaunch keeps mention chip: \(text(of: editor))")
        XCTAssertTrue(text(of: editor).contains("@grace"))
    }

    /// PR13c2: when `abilities.mention == false`, `@` stays plain text and never opens the mention picker.
    func testNoMentionAbilitySuppressesMentionPicker() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-inline-objects", "--native-inline-objects-no-mention", "--reset"]
        app.launch()
        let editor = app.textViews["nativeEditor.text"]
        focusTopParagraph(of: editor, in: app)

        editor.typeText("@ada")
        let mentionPicker = app.descendants(matching: .any)["editor.mentionPicker"]
        XCTAssertFalse(mentionPicker.waitForExistence(timeout: 1.5))
        XCTAssertTrue(waitForText(of: editor, containing: "@ada"))
    }

    /// PR13c2: `[[` and `@` pickers work in both columns and table cells,
    /// dismissing on tap outside without closing the sheet, and chips survive relaunch.
    func testColumnAndTableInlinePickersDismissAndRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-inline-objects", "--reset"]
        app.launch()
        let editor = app.textViews["nativeEditor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))

        // 1. Columns: insert interlink + mention, then tapping outside dismisses picker without closing column sheet.
        let columnCard = app.descendants(matching: .any)["nativeEditor.attachment.owned-columns"]
        XCTAssertTrue(columnCard.waitForExistence(timeout: 10))
        columnCard.tap()
        let firstColumn = app.textViews["nativeEditor.column.0"]
        XCTAssertTrue(firstColumn.waitForExistence(timeout: 5))
        firstColumn.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))

        firstColumn.typeText(" [[Road")
        let roadmap = app.buttons["Product Roadmap"]
        XCTAssertTrue(roadmap.waitForExistence(timeout: 5))
        roadmap.tap()
        XCTAssertTrue(roadmap.waitForNonExistence(timeout: 5))

        firstColumn.typeText(" @ada")
        let adaRow = app.buttons["editor.mentionPicker.row.aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]
        XCTAssertTrue(adaRow.waitForExistence(timeout: 5))
        adaRow.tap()
        XCTAssertTrue(adaRow.waitForNonExistence(timeout: 5))

        firstColumn.typeText(" [[Ar")
        let architecture = app.buttons["Architecture Notes"]
        XCTAssertTrue(architecture.waitForExistence(timeout: 5))
        let columnPicker = app.segmentedControls["nativeEditor.columns.picker"]
        columnPicker.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(architecture.waitForNonExistence(timeout: 5), "Switching column dismisses column picker")
        let columnsDone = app.buttons["nativeEditor.columns.done"]
        XCTAssertTrue(columnsDone.exists, "Dismissing picker must not close the column editor")
        columnPicker.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(firstColumn.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForText(of: firstColumn, containing: "Page: Product Roadmap"))
        XCTAssertTrue(waitForText(of: firstColumn, containing: "Mention: @Ada Lovelace"))
        columnsDone.tap()
        XCTAssertTrue(columnCard.waitForExistence(timeout: 5))

        // 2. Table: insert interlink + mention in empty cell (1, 1), then tap another cell to dismiss picker.
        let tableCard = app.descendants(matching: .any)["nativeEditor.attachment.owned-table"]
        XCTAssertTrue(tableCard.waitForExistence(timeout: 5))
        tableCard.tap()
        let emptyCell = app.staticTexts["nativeEditor.table.text.1.1"]
        XCTAssertTrue(emptyCell.waitForExistence(timeout: 5))
        emptyCell.tap()
        XCTAssertTrue(emptyCell.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))

        app.typeText("[[Road")
        XCTAssertTrue(roadmap.waitForExistence(timeout: 5))
        roadmap.tap()
        XCTAssertTrue(roadmap.waitForNonExistence(timeout: 5))

        app.typeText(" @ada")
        XCTAssertTrue(adaRow.waitForExistence(timeout: 5))
        adaRow.tap()
        XCTAssertTrue(adaRow.waitForNonExistence(timeout: 5))

        app.typeText(" [[Ar")
        XCTAssertTrue(architecture.waitForExistence(timeout: 5))
        app.staticTexts["nativeEditor.table.text.0.0"].tap()
        XCTAssertTrue(architecture.waitForNonExistence(timeout: 5), "Tapping another cell dismisses table cell picker")
        let tableDone = app.buttons["nativeEditor.table.done"]
        XCTAssertTrue(tableDone.exists, "Dismissing picker must not close the table editor")
        tableDone.tap()
        XCTAssertTrue(tableCard.waitForExistence(timeout: 5))

        waitForDurableJournal(in: app)
        app.terminate()

        app.launchArguments = ["--native-inline-objects"]
        app.launch()
        XCTAssertTrue(columnCard.waitForExistence(timeout: 10))
        columnCard.tap()
        XCTAssertTrue(firstColumn.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForText(of: firstColumn, containing: "Page: Product Roadmap"))
        XCTAssertTrue(waitForText(of: firstColumn, containing: "Mention: @Ada Lovelace"))
        columnsDone.tap()

        XCTAssertTrue(tableCard.waitForExistence(timeout: 5))
        tableCard.tap()
        XCTAssertTrue(emptyCell.waitForExistence(timeout: 5))
        let cellValue = emptyCell.value as? String ?? ""
        XCTAssertTrue(cellValue.contains("Product Roadmap"), "table cell kept interlink: \(cellValue)")
        XCTAssertTrue(cellValue.contains("@Ada Lovelace"), "table cell kept mention: \(cellValue)")
    }

    /// PR13c2: tapping an inserted interlink chip triggers document navigation (`onOpenDocument`).
    func testTappingInsertedInterlinkChipNavigatesToDocument() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-inline-objects", "--reset"]
        app.launch()
        let editor = app.textViews["nativeEditor.text"]
        focusTopParagraph(of: editor, in: app)

        editor.typeText("[[Road")
        let roadmap = app.buttons["Product Roadmap"]
        XCTAssertTrue(roadmap.waitForExistence(timeout: 5))
        roadmap.tap()
        XCTAssertTrue(roadmap.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitForText(of: editor, containing: "Page: Product Roadmap"))

        // Tap inside the chip laid out at offset 0 of the top paragraph (`textContainerInset` 16,16).
        editor.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 60, dy: topParagraphY(in: app) + 1))
            .tap()
        let opened = app.staticTexts["inlineObjects.openedDocument"]
        XCTAssertTrue(opened.waitForExistence(timeout: 5), "tapping interlink chip navigates to linked document")
        XCTAssertEqual(opened.label, "Product Roadmap")
    }

    /// G04: `--native-open` opens in Reading mode, toggles Editing mode via `Edit`/`Done`,
    /// and enters Editing mode when prose is tapped.
    func testModeHandoffBetweenReadingAndEditing() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-open", "--reset", "--native-blocks"]
        app.launch()

        let editor = app.textViews["nativeEditor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(editor.waitForStableFrame())

        let editButton = app.buttons["Edit"]
        let doneButton = app.buttons["Done"]
        let boldButton = app.buttons["nativeEditor.format.bold"]

        XCTAssertTrue(editButton.waitForExistence(timeout: 5), "document opens in Reading mode")
        XCTAssertFalse(boldButton.exists, "formatting bar is hidden in Reading mode")

        editButton.tap()
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5), "Edit button enters Editing mode")
        XCTAssertTrue(boldButton.waitForExistence(timeout: 5), "formatting bar shows in Editing mode")

        doneButton.tap()
        XCTAssertTrue(editButton.waitForExistence(timeout: 5), "Done button returns to Reading mode")
        XCTAssertFalse(boldButton.exists, "Done hides the formatting bar")
        XCTAssertTrue(editor.waitForStableFrame())

        firstParagraphCoordinate(of: editor, in: app).tap()
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5), "tapping prose enters Editing mode")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(boldButton.waitForExistence(timeout: 5))
    }

    /// G05: Ticking a checkbox in Reading mode works without leaving Reading mode,
    /// and `Hide completed` hides completed checklist items and reveals them again.
    func testHideCompletedChecklistsInReadingMode() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-open", "--reset", "--native-blocks"]
        app.launch()

        let editor = app.textViews["nativeEditor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(editor.waitForStableFrame())
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5))

        let checkbox = app.buttons["nativeEditor.checkbox.owned-check"]
        XCTAssertTrue(checkbox.waitForExistence(timeout: 5))
        checkbox.tap()
        XCTAssertTrue(waitForValue(of: checkbox, equalTo: "Done", timeout: 5))
        XCTAssertTrue(app.buttons["Edit"].exists, "toggling checkbox keeps Reading mode")
        XCTAssertFalse(app.buttons["nativeEditor.format.bold"].exists)

        let hideToggle = app.switches["checklist.hideCompleted"]
        XCTAssertTrue(hideToggle.waitForExistence(timeout: 5))
        let switchControl = hideToggle.switches.firstMatch.exists ? hideToggle.switches.firstMatch : hideToggle
        switchControl.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.2)

        XCTAssertTrue(checkbox.waitForNonExistence(timeout: 5), "completed item hides when Hide completed is on (switchHittable=\(switchControl.isHittable) hideHittable=\(hideToggle.isHittable))")
        XCTAssertFalse(text(of: editor).contains("Fixture task"))

        switchControl.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.2)
        XCTAssertTrue(checkbox.waitForExistence(timeout: 5), "turning off Hide completed restores the item")
        XCTAssertTrue(waitForText(of: editor, containing: "Fixture task"))
    }

    /// G09: Double-tapping a word in Reading mode enters Editing mode with selection,
    /// and Command+B toggles bold durably across relaunch.
    func testHardwareCommandBBoldSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-open", "--reset", "--native-slow-disk"]
        app.launch()

        let editor = app.textViews["nativeEditor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(editor.waitForStableFrame())

        firstParagraphCoordinate(of: editor, in: app).doubleTap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        let bold = app.buttons["nativeEditor.format.bold"]
        XCTAssertTrue(bold.waitForExistence(timeout: 5))
        XCTAssertFalse(bold.isSelected)

        editor.typeKey("b", modifierFlags: .command)
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isSelected == true"), object: bold)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed, "Command+B toggles bold")
        waitForDurableJournal(in: app)
        app.terminate()

        app.launchArguments = ["--native-open"]
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(editor.waitForStableFrame())
        firstParagraphCoordinate(of: editor, in: app).doubleTap()
        XCTAssertTrue(bold.waitForExistence(timeout: 5))
        let persisted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isSelected == true"), object: bold)
        XCTAssertEqual(XCTWaiter.wait(for: [persisted], timeout: 5), .completed, "bold survives relaunch")
    }

    /// G10: `/divider` converts the active paragraph to a divider with a trailing paragraph
    /// and survives relaunch without entering preserved mode.
    func testSlashDividerInsertsAndSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-open", "--reset", "--native-slow-disk"]
        app.launch()

        let editor = app.textViews["nativeEditor.text"]
        focusFirstParagraph(of: editor, in: app)
        editor.typeText("\n/divider")

        let dividerItem = app.buttons["Divider"]
        XCTAssertTrue(dividerItem.waitForExistence(timeout: 5), "slash menu offers Divider")
        dividerItem.tap()
        XCTAssertTrue(dividerItem.waitForNonExistence(timeout: 5))

        editor.typeText("After rule")
        XCTAssertTrue(waitForText(of: editor, containing: "\n\nAfter rule"))
        XCTAssertFalse(app.staticTexts["nativeEditor.preservedNotice"].exists)
        waitForDurableJournal(in: app)
        app.terminate()

        app.launchArguments = ["--native-open"]
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForText(of: editor, containing: "\n\nAfter rule"))
        XCTAssertFalse(app.staticTexts["nativeEditor.preservedNotice"].exists)
    }

    private func text(of element: XCUIElement) -> String { element.value as? String ?? "" }

    private func topParagraphY(in app: XCUIApplication) -> CGFloat {
        app.buttons["Options"].exists ? 140 : 26
    }

    private func firstParagraphCoordinate(of editor: XCUIElement, in app: XCUIApplication) -> XCUICoordinate {
        let hasShellHeader = app.buttons["Options"].exists
        let dy: CGFloat =
            if hasShellHeader {
                app.switches["checklist.hideCompleted"].exists ? 180 : 140
            } else {
                max(18, editor.frame.height * 0.025)
            }
        return editor.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: editor.frame.width * 0.15, dy: dy))
    }

    private func focusTopParagraph(of editor: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(editor.waitForStableFrame(), "The editor must stop moving before it is tapped")
        XCTAssertTrue(editor.isHittable)
        editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 32, dy: topParagraphY(in: app))).tap()
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 10), keyboard.waitForStableFrame() else {
            let screen = XCTAttachment(screenshot: app.screenshot())
            screen.name = "Editor tap did not raise a settled keyboard"
            screen.lifetime = .keepAlways
            add(screen)
            return XCTFail("The tap must focus the editor and raise a settled keyboard before typing")
        }
    }

    private func waitForDurableJournal(in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Saved on this device"].waitForExistence(timeout: 10))
        let idle = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "idle"), object: app.staticTexts["replica.inFlight"])
        XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 15), .completed)
    }

    /// Taps into the first paragraph only once the editor holds still, then waits for the keyboard to
    /// finish rising. A bare `waitForExistence` passes while the view is still laying out (the tap then
    /// lands where the paragraph no longer is and nothing is focused) and while the keyboard is still
    /// animating in (it is already "there", but not yet taking keys). On failure the screen is attached,
    /// so a hosted run shows whether the tap or the keyboard was the missing step.
    private func focusFirstParagraph(of editor: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(editor.waitForStableFrame(), "The editor must stop moving before it is tapped")
        XCTAssertTrue(editor.isHittable)
        firstParagraphCoordinate(of: editor, in: app).tap()
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
