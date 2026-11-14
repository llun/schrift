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

    func testCheckboxIsALabelledButtonWithItsState() async throws {
        let harness = try await makeHarness([paragraph("p", "Intro"), check("task", "Buy milk")])
        addTeardownBlock { await harness.close() }
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
        await harness.settle()
        harness.view.layoutIfNeeded()
        XCTAssertEqual(button.accessibilityLabel, "Mark as not done")
        XCTAssertEqual(button.accessibilityValue, "Done")
        try await assertConsistent(harness, localCommands: 1)
    }

    /// The read-only reader shows the state but offers no action.
    func testReadOnlyCheckboxIsDisabled() async throws {
        let session = try await NativeEditorSession.seed(
            state: BlockNoteYjs.encode([check("task", "Done", checked: true)], clientID: 1))
        addTeardownBlock { await session.close().value }
        let window = host(session.textView)
        defer { window.isHidden = true }
        let button = try XCTUnwrap(session.textView.blockControls.checkboxes["task"])
        XCTAssertFalse(button.isEnabled)
        XCTAssertTrue(button.accessibilityTraits.contains(.notEnabled))
        XCTAssertEqual(button.accessibilityValue, "Done")
    }

    func testControlsUseTheLocalizedLabels() async throws {
        let harness = try await makeHarness([check("task", "Tâche"), code("code", "x", language: "swift")])
        addTeardownBlock { await harness.close() }
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

    func testCodeLanguageMenuIsALabelledControlListingEveryLanguage() async throws {
        let harness = try await makeHarness([
            code("code", "fn main() {}", language: "rust"), code("odd", "x", language: "zig"),
        ])
        addTeardownBlock { await harness.close() }
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

        let set = await harness.run { harness.input.setCodeLanguage(blockID: "code", language: "swift") }
        XCTAssertTrue(set)
        harness.view.layoutIfNeeded()
        XCTAssertEqual(button.accessibilityValue, "swift")
        XCTAssertEqual(
            (button.menu?.children as? [UIAction])?.filter { $0.state == .on }.map(\.title), ["swift"])
        try await assertConsistent(harness, localCommands: 1)
    }

    // MARK: - Headings

    func testHeadingsCarryTheirLevelForVoiceOver() async throws {
        let harness = try await makeHarness([
            headingBlock("h1", "Title", level: 1), paragraph("p", "Body"), headingBlock("h2", "Section", level: 2),
            headingBlock("h3", "Sub", level: 3),
        ])
        addTeardownBlock { await harness.close() }
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
    func testHeadingsRotorWalksEveryHeadingInOrder() async throws {
        var blocks = [headingBlock("h1", "First", level: 1)]
        blocks += (0..<300).map { paragraph("a\($0)", "Paragraph \($0) of filler text.") }
        blocks.append(headingBlock("h2", "Second", level: 2))
        blocks += (0..<300).map { paragraph("b\($0)", "More filler \($0).") }
        blocks.append(headingBlock("h3", "Third", level: 3))
        let harness = try await makeHarness(blocks)
        addTeardownBlock { await harness.close() }
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
    func testSlashHeadingJoinsTheRotor() async throws {
        let harness = try await makeHarness([paragraph("p", "Body"), paragraph("s", "")])
        addTeardownBlock { await harness.close() }
        XCTAssertTrue(harness.view.blockControls.headingRanges().isEmpty)
        setSelection(harness, NSRange(location: try location(harness.session, "s", 0), length: 0))
        harness.view.insertText("/")
        await harness.settle()
        let item = try XCTUnwrap(NativeInputCoordinator.slashItems.first { $0.id == "heading2" })
        let applied = await harness.run { harness.input.applySlashItem(item) }
        XCTAssertTrue(applied)
        harness.view.insertText("Topic")
        await harness.settle()
        let ranges = harness.view.blockControls.headingRanges()
        XCTAssertEqual(ranges.map { (harness.view.textStorage.string as NSString).substring(with: $0) }, ["Topic"])
        try await assertConsistent(harness, localCommands: 3)
    }

    // MARK: - Reading mode checkbox & accessibility order (G04, G05, G11)

    func testReadingModeCheckboxTogglesWithoutMakingSurfaceEditable() async throws {
        let harness = try await makeHarness([paragraph("p", "Intro"), check("task", "Buy milk")])
        addTeardownBlock { await harness.close() }
        let window = host(harness.view)
        defer { window.isHidden = true }

        harness.session.setEditing(false)
        harness.view.layoutIfNeeded()

        XCTAssertFalse(harness.view.isEditable)
        XCTAssertFalse(harness.input.canEditForTextDrop)
        XCTAssertTrue(harness.input.canToggleCheckbox)

        let button = try XCTUnwrap(harness.view.blockControls.checkboxes["task"])
        XCTAssertTrue(button.isEnabled)
        XCTAssertFalse(button.accessibilityTraits.contains(.notEnabled))

        button.sendActions(for: .primaryActionTriggered)
        await harness.settle()
        harness.view.layoutIfNeeded()

        XCTAssertFalse(harness.view.isEditable, "Reading-mode checkbox tap keeps textView non-editable")
        XCTAssertFalse(harness.view.isFirstResponder)
        XCTAssertEqual(button.accessibilityValue, "Done")
        try await assertConsistent(harness, localCommands: 1, expectedEditable: false)
    }

    func testCursorOverlayHidesFromAccessibilityWhenEmptyAndShowsForPeers() async throws {
        let harness = try await makeHarness([paragraph("p", "Hello world")])
        addTeardownBlock { await harness.close() }
        let window = host(harness.view)
        defer { window.isHidden = true }

        XCTAssertTrue(harness.view.cursorOverlay.accessibilityElementsHidden)

        let awareness = NativeAwarenessController(replica: try XCTUnwrap(harness.session.replica))
        harness.session.showAwareness(awareness)
        let position = try await unwrapped(
            harness.engine { $0.awarenessPosition(EditorPosition(blockID: "p", offset: 2, assoc: -1)) })
        let cursor = AwarenessCursor(anchor: position, head: position)
        let stateJSON = LocalAwarenessState(name: "Peer", color: "#000000", cursor: cursor)
            .json(wireProtocol: .yWebSocket)
        awareness.receive([AwarenessEntry(clientID: 7, clock: 1, stateJSON: stateJSON)])
        for _ in 0..<40 where awareness.places[7] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        harness.view.layoutIfNeeded()
        XCTAssertFalse(harness.view.cursorOverlay.accessibilityElementsHidden)

        awareness.receive([AwarenessEntry(clientID: 7, clock: 2, stateJSON: "null")])
        for _ in 0..<40 where !awareness.places.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        harness.view.layoutIfNeeded()
        XCTAssertTrue(harness.view.cursorOverlay.accessibilityElementsHidden)
    }

    func testAuxiliarySubviewOrderFollowsDocumentTopToBottomOrder() async throws {
        let harness = try await makeHarness([
            check("c1", "First task"),
            code("code", "let x = 1", language: "swift"),
            check("c2", "Second task"),
        ])
        addTeardownBlock { await harness.close() }
        let window = host(harness.view)
        defer { window.isHidden = true }

        let header = UIView(frame: CGRect(x: 0, y: -60, width: 390, height: 60))
        let footer = UIView(frame: CGRect(x: 0, y: 200, width: 390, height: 60))
        harness.view.addSubview(header)
        harness.view.addSubview(footer)
        harness.view.headerAccessoryView = header
        harness.view.footerAccessoryView = footer
        harness.view.setNeedsLayout()
        harness.view.layoutIfNeeded()

        let c1Button = try XCTUnwrap(harness.view.blockControls.checkboxes["c1"])
        let codeButton = try XCTUnwrap(harness.view.blockControls.languageButtons["code"])
        let c2Button = try XCTUnwrap(harness.view.blockControls.checkboxes["c2"])
        let expected: [UIView] = [header, c1Button, codeButton, c2Button, footer, harness.view.cursorOverlay]
        let indices = expected.compactMap { harness.view.subviews.firstIndex(of: $0) }
        XCTAssertEqual(indices.count, expected.count)
        XCTAssertEqual(indices, indices.sorted(), "auxiliary subviews must appear strictly top-to-bottom")
    }

    func testTapToEditExcludesHeaderFooterControlsAndLinks() async throws {
        let linked = BlockNoteBlock(
            node: "paragraph",
            props: Self.paragraphProps,
            runs: [
                InlineRun("Read docs", marks: [(key: "link", valueJSON: #"{"href":"https://example.org"}"#)])
            ],
            id: "link")
        let harness = try await makeHarness([linked, check("task", "Task item"), paragraph("prose", "Plain prose")])
        addTeardownBlock { await harness.close() }
        let window = host(harness.view)
        defer { window.isHidden = true }

        var editRequests = 0
        harness.view.onRequestEdit = { editRequests += 1 }
        harness.session.setEditing(false)

        let header = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 40))
        let footer = UIView(frame: CGRect(x: 0, y: 600, width: 390, height: 40))
        harness.view.addSubview(header)
        harness.view.addSubview(footer)
        harness.view.headerAccessoryView = header
        harness.view.footerAccessoryView = footer
        harness.view.setNeedsLayout()
        harness.view.layoutIfNeeded()

        XCTAssertFalse(harness.view.editTapShouldBegin(at: CGPoint(x: 20, y: 20)))
        XCTAssertFalse(harness.view.editTapShouldBegin(at: CGPoint(x: 20, y: 620)))

        let checkbox = try XCTUnwrap(harness.view.blockControls.checkboxes["task"])
        XCTAssertFalse(harness.view.editTapShouldBegin(at: checkbox.center))

        let linkLoc = try location(harness.session, "link", 2)
        let linkPos = try XCTUnwrap(harness.view.position(from: harness.view.beginningOfDocument, offset: linkLoc))
        let linkCaret = harness.view.caretRect(for: linkPos)
        XCTAssertFalse(harness.view.editTapShouldBegin(at: CGPoint(x: linkCaret.midX, y: linkCaret.midY)))

        let proseLoc = try location(harness.session, "prose", 2)
        let prosePos = try XCTUnwrap(harness.view.position(from: harness.view.beginningOfDocument, offset: proseLoc))
        let proseCaret = harness.view.caretRect(for: prosePos)
        XCTAssertTrue(harness.view.editTapShouldBegin(at: CGPoint(x: proseCaret.midX, y: proseCaret.midY)))
        XCTAssertTrue(harness.view.editDoubleTapShouldBegin(at: CGPoint(x: proseCaret.midX, y: proseCaret.midY)))
        XCTAssertEqual(editRequests, 0)
    }
}
