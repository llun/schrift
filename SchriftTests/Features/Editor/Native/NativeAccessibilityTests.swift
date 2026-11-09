import UIKit
import XCTest

@testable import Schrift

/// PR05b: the native editor's block controls are real, labelled UIKit
/// controls, headings carry their level, and the system Headings rotor walks
/// every heading in the document, not only the laid-out ones.
@MainActor
final class NativeAccessibilityTests: NativeEditingTestCase {
    private func headingBlock(_ id: String, _ text: String, level: Int) -> BlockNoteBlock {
        BlockNoteBlock(
            node: "heading", props: Self.paragraphProps + [("level", .int(level)), ("isToggleable", .bool(false))],
            runs: [InlineRun(text)], id: id)
    }

    private func check(_ id: String, _ text: String, checked: Bool = false) -> BlockNoteBlock {
        BlockNoteBlock(
            node: "checkListItem", props: Self.paragraphProps + [("checked", .bool(checked))],
            runs: [InlineRun(text)], id: id)
    }

    private func code(_ id: String, _ text: String, language: String) -> BlockNoteBlock {
        BlockNoteBlock(node: "codeBlock", props: [("language", .string(language))], runs: [InlineRun(text)], id: id)
    }

    private func host(_ view: NativeTextView, height: CGFloat = 800) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: height))
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        return window
    }

    // MARK: - Checkbox

    func testCheckboxIsALabelledButtonWithItsState() throws {
        let harness = try makeHarness([paragraph("p", "Intro"), check("task", "Buy milk")])
        defer { harness.close() }
        let window = host(harness.view)
        defer { window.isHidden = true }
        let button = try XCTUnwrap(harness.view.blockControls.checkboxes["task"])
        XCTAssertTrue(button.isAccessibilityElement)
        XCTAssertEqual(button.accessibilityIdentifier, "nativeEditor.checkbox.task")
        XCTAssertEqual(button.accessibilityLabel, "Mark as done")
        XCTAssertEqual(button.accessibilityValue, "Not done")
        XCTAssertTrue(button.accessibilityTraits.contains(.button))
        XCTAssertFalse(button.accessibilityTraits.contains(.notEnabled))
        XCTAssertGreaterThanOrEqual(button.bounds.width, DocsSpacing.rowMinHeight, "a 44pt hit target")
        XCTAssertGreaterThanOrEqual(button.bounds.height, DocsSpacing.rowMinHeight)
        XCTAssertTrue(harness.view.subviews.contains(button))

        button.sendActions(for: .primaryActionTriggered)
        harness.view.layoutIfNeeded()
        XCTAssertEqual(button.accessibilityLabel, "Mark as not done")
        XCTAssertEqual(button.accessibilityValue, "Done")
        try assertConsistent(harness, localCommands: 1)
    }

    /// The read-only reader shows the state but offers no action.
    func testReadOnlyCheckboxIsDisabled() throws {
        let session = try NativeEditorSession(
            state: BlockNoteYjs.encode([check("task", "Done", checked: true)], clientID: 1))
        defer { session.close() }
        let window = host(session.textView)
        defer { window.isHidden = true }
        let button = try XCTUnwrap(session.textView.blockControls.checkboxes["task"])
        XCTAssertFalse(button.isEnabled)
        XCTAssertTrue(button.accessibilityTraits.contains(.notEnabled))
        XCTAssertEqual(button.accessibilityValue, "Done")
    }

    func testControlsUseTheLocalizedLabels() throws {
        let harness = try makeHarness([check("task", "Tâche"), code("code", "x", language: "swift")])
        defer { harness.close() }
        let window = host(harness.view)
        defer { window.isHidden = true }
        let french = Strings_fr.table
        harness.view.blockControls.labels = NativeEditorLabels(
            preservedBlock: french[.native_editor_preserved_block]!,
            unknownBlock: french[.native_editor_unknown_block]!,
            pageBreak: french[.native_editor_page_break]!, codeLanguage: french[.native_editor_code_language]!,
            markDone: french[.editor_checklist_done_a11y]!, markNotDone: french[.editor_checklist_not_done_a11y]!,
            done: french[.editor_checklist_state_done_a11y]!, notDone: french[.editor_checklist_state_not_done_a11y]!)
        harness.view.layoutIfNeeded()
        XCTAssertEqual(
            harness.view.blockControls.checkboxes["task"]?.accessibilityLabel, french[.editor_checklist_done_a11y])
        XCTAssertEqual(
            harness.view.blockControls.languageButtons["code"]?.accessibilityLabel, french[.native_editor_code_language]
        )
    }

    // MARK: - Code language

    func testCodeLanguageMenuIsALabelledControlListingEveryLanguage() throws {
        let harness = try makeHarness([
            code("code", "fn main() {}", language: "rust"), code("odd", "x", language: "zig"),
        ])
        defer { harness.close() }
        let window = host(harness.view)
        defer { window.isHidden = true }
        let button = try XCTUnwrap(harness.view.blockControls.languageButtons["code"])
        XCTAssertEqual(button.accessibilityIdentifier, "nativeEditor.codeLanguage.code")
        XCTAssertEqual(button.accessibilityLabel, "Code language")
        XCTAssertEqual(button.accessibilityValue, "rust")
        XCTAssertTrue(button.isEnabled)
        XCTAssertTrue(button.showsMenuAsPrimaryAction)
        let actions = try XCTUnwrap(button.menu?.children as? [UIAction])
        XCTAssertEqual(actions.map(\.title), NativeBlockControls.codeLanguages)
        XCTAssertEqual(actions.filter { $0.state == .on }.map(\.title), ["rust"])
        // A stored language outside the list is still listed, never rewritten.
        let odd = try XCTUnwrap(harness.view.blockControls.languageButtons["odd"]?.menu?.children as? [UIAction])
        XCTAssertEqual(odd.first?.title, "zig")
        XCTAssertEqual(odd.first?.state, .on)
        // The language control sits above the code, not over it.
        let entry = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "code"))
        let start = try XCTUnwrap(
            harness.view.position(from: harness.view.beginningOfDocument, offset: entry.range.location))
        XCTAssertLessThanOrEqual(button.frame.maxY, harness.view.caretRect(for: start).minY + 1)

        XCTAssertTrue(harness.input.setCodeLanguage(blockID: "code", language: "swift"))
        harness.view.layoutIfNeeded()
        XCTAssertEqual(button.accessibilityValue, "swift")
        XCTAssertEqual(
            (button.menu?.children as? [UIAction])?.filter { $0.state == .on }.map(\.title), ["swift"])
        try assertConsistent(harness, localCommands: 1)
    }

    // MARK: - Headings

    func testHeadingsCarryTheirLevelForVoiceOver() throws {
        let harness = try makeHarness([
            headingBlock("h1", "Title", level: 1), paragraph("p", "Body"), headingBlock("h2", "Section", level: 2),
            headingBlock("h3", "Sub", level: 3),
        ])
        defer { harness.close() }
        let storage = harness.view.textStorage
        for (id, level) in [("h1", 1), ("h2", 2), ("h3", 3)] {
            let entry = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: id))
            var effective = NSRange()
            let value = storage.attribute(
                .accessibilityTextHeadingLevel, at: entry.range.location, longestEffectiveRange: &effective,
                in: entry.range)
            XCTAssertEqual(value as? Int, level, id)
            XCTAssertEqual(effective, entry.range, "\(id): the whole heading")
        }
        let body = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "p"))
        XCTAssertNil(storage.attribute(.accessibilityTextHeadingLevel, at: body.range.location, effectiveRange: nil))
    }

    /// The system Headings rotor visits each heading's text in order, both
    /// ways, including headings far outside the laid-out viewport.
    func testHeadingsRotorWalksEveryHeadingInOrder() throws {
        var blocks = [headingBlock("h1", "First", level: 1)]
        blocks += (0..<300).map { paragraph("a\($0)", "Paragraph \($0) of filler text.") }
        blocks.append(headingBlock("h2", "Second", level: 2))
        blocks += (0..<300).map { paragraph("b\($0)", "More filler \($0).") }
        blocks.append(headingBlock("h3", "Third", level: 3))
        let harness = try makeHarness(blocks)
        defer { harness.close() }
        let window = host(harness.view)
        defer { window.isHidden = true }
        let view = harness.view
        let rotor = try XCTUnwrap(view.accessibilityCustomRotors?.first)
        XCTAssertEqual(rotor.systemRotorType, .heading)

        func search(_ direction: UIAccessibilityCustomRotor.Direction, from item: UIAccessibilityCustomRotorItemResult?)
            -> UIAccessibilityCustomRotorItemResult?
        {
            let predicate = UIAccessibilityCustomRotorSearchPredicate()
            predicate.searchDirection = direction
            predicate.currentItem = item ?? UIAccessibilityCustomRotorItemResult(targetElement: view, targetRange: nil)
            return rotor.itemSearchBlock(predicate)
        }
        func text(_ item: UIAccessibilityCustomRotorItemResult?) -> String? {
            item?.targetRange.flatMap { view.text(in: $0) }
        }
        let first = search(.next, from: nil)
        XCTAssertTrue(first?.targetElement === view)
        XCTAssertEqual(text(first), "First")
        let second = search(.next, from: first)
        XCTAssertEqual(text(second), "Second")
        let third = search(.next, from: second)
        XCTAssertEqual(text(third), "Third")
        XCTAssertNil(search(.next, from: third), "the last heading ends the rotor")
        XCTAssertEqual(text(search(.previous, from: third)), "Second")
        XCTAssertEqual(text(search(.previous, from: nil)), "Third")
        XCTAssertEqual(view.blockControls.headingRanges().count, 3)
    }

    /// A heading made by the slash menu joins the rotor at once.
    func testSlashHeadingJoinsTheRotor() throws {
        let harness = try makeHarness([paragraph("p", "Body"), paragraph("s", "")])
        defer { harness.close() }
        XCTAssertTrue(harness.view.blockControls.headingRanges().isEmpty)
        setSelection(harness, NSRange(location: try location(harness.session, "s", 0), length: 0))
        harness.view.insertText("/")
        let item = try XCTUnwrap(NativeInputCoordinator.slashItems.first { $0.id == "heading2" })
        XCTAssertTrue(harness.input.applySlashItem(item))
        harness.view.insertText("Topic")
        let ranges = harness.view.blockControls.headingRanges()
        XCTAssertEqual(ranges.map { (harness.view.textStorage.string as NSString).substring(with: $0) }, ["Topic"])
        try assertConsistent(harness, localCommands: 3)
    }
}
