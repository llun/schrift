import UIKit
import XCTest

@testable import Schrift

/// PR06b: toggle list items and toggle headings are native blocks with local
/// folding. Folding is view state on the surface: storage, the range index and
/// the replica stay the full projection, and TextKit 2 leaves a folded
/// toggle's children out of layout. Real `NativeTextView` input over a
/// restored durable replica (`NativeEditingTestCase`); no sleeps. The command
/// bytes are pinned against BlockNote's captures in `BlockNoteToggleOracleTests`.
@MainActor
final class NativeToggleTests: NativeEditingTestCase {
    private func toggle(_ id: String, _ text: String, _ children: [BlockNoteBlock] = []) -> BlockNoteBlock {
        BlockNoteBlock(
            node: "toggleListItem", props: Self.paragraphProps, runs: text.isEmpty ? [] : [InlineRun(text)], id: id,
            children: children)
    }

    private func toggleHeading(_ id: String, _ text: String, _ children: [BlockNoteBlock] = []) -> BlockNoteBlock {
        var block = heading(id, text, toggle: true)
        block.children = children
        return block
    }

    private func check(_ id: String, _ text: String) -> BlockNoteBlock {
        BlockNoteBlock(
            node: "checkListItem", props: Self.paragraphProps + [("checked", .bool(false))], runs: [InlineRun(text)],
            id: id)
    }

    /// Intro, a toggle with a paragraph, a checklist item and a heading
    /// inside, then a closing paragraph.
    private func seed() -> [BlockNoteBlock] {
        [
            paragraph("intro", "Intro"),
            toggle("t", "Title", [paragraph("c1", "Hidden one"), check("c2", "Hidden task"), heading("c3", "Inner")]),
            paragraph("after", "After"),
        ]
    }

    private func host(_ harness: Harness) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 2_000))
        harness.view.frame = window.bounds
        window.addSubview(harness.view)
        window.isHidden = false
        harness.view.layoutIfNeeded()
        return window
    }

    /// The blocks TextKit laid out, by id, over the whole document.
    private func laidOut(_ harness: Harness) throws -> [String] {
        let layout = try XCTUnwrap(harness.view.textLayoutManager)
        layout.ensureLayout(for: layout.documentRange)
        var ids: [String] = []
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) {
            if let id = ($0 as? NativeBlockFragment)?.blockID { ids.append(id) }
            return true
        }
        return ids
    }

    private func caret(_ harness: Harness, _ id: String, _ offset: Int) throws {
        setSelection(harness, NSRange(location: try location(harness.session, id, offset), length: 0))
    }

    private func button(_ harness: Harness, _ id: String) throws -> UIButton {
        harness.view.layoutIfNeeded()
        return try XCTUnwrap(harness.view.blockControls.toggleButtons[id])
    }

    private func tap(_ harness: Harness, _ id: String) throws {
        try button(harness, id).sendActions(for: .primaryActionTriggered)
        harness.view.layoutIfNeeded()
    }

    // MARK: - Render, fold and unfold

    func testTogglesRenderCollapsedAndFoldWithoutWritingYjs() throws {
        let harness = try makeHarness(seed() + [toggleHeading("h", "Section", [paragraph("h1", "Under")])])
        defer { harness.close() }
        let session = harness.session
        let window = host(harness)
        defer { window.isHidden = true }
        XCTAssertEqual(session.surface.blocks.map(\.node).prefix(2), ["paragraph", "toggleListItem"])
        XCTAssertTrue(session.surface.blocks.allSatisfy { !$0.isOpaque }, "toggles are native blocks")
        // BlockNote's default: a toggle starts collapsed. Its children stay in
        // storage (surface = projection) but are not laid out.
        XCTAssertEqual(session.surface.hidden, [false, false, true, true, true, false, false, true])
        XCTAssertTrue(harness.view.textStorage.string.contains("Hidden one"))
        XCTAssertEqual(try laidOut(harness), ["intro", "t", "after", "h"])
        try assertConsistent(harness, localCommands: 0)

        let triangle = try button(harness, "t")
        XCTAssertTrue(triangle.isAccessibilityElement)
        XCTAssertTrue(triangle.accessibilityTraits.contains(.button))
        XCTAssertEqual(triangle.accessibilityIdentifier, "nativeEditor.toggle.t")
        XCTAssertEqual(triangle.accessibilityLabel, "Expand or collapse")
        XCTAssertEqual(triangle.accessibilityValue, "Collapsed")
        XCTAssertEqual(triangle.accessibilityExpandedStatus, .collapsed)
        XCTAssertGreaterThanOrEqual(triangle.bounds.width, DocsSpacing.rowMinHeight, "a 44pt hit target")
        XCTAssertNotNil(harness.view.blockControls.toggleButtons["h"], "a toggle heading has one too")
        // The gutter: the title starts after the triangle.
        let start = try location(session, "t", 0)
        let style = try XCTUnwrap(
            harness.view.textStorage.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertGreaterThan(style.headIndent, 0)

        // VoiceOver reaches nothing folded: the text value, the controls and
        // the Headings rotor leave the children out.
        XCTAssertFalse(harness.view.accessibilityValue?.contains("Hidden one") ?? true)
        XCTAssertNil(harness.view.blockControls.checkboxes["c2"])
        XCTAssertEqual(harness.view.blockControls.headingRanges().count, 1, "Section only, not the folded Inner")

        let revision = session.engine.revision
        let visited = session.engine.visitedTypeCount
        try tap(harness, "t")
        XCTAssertEqual(triangle.accessibilityValue, "Expanded")
        XCTAssertEqual(triangle.accessibilityExpandedStatus, .expanded)
        XCTAssertEqual(try laidOut(harness), ["intro", "t", "c1", "c2", "c3", "after", "h"])
        XCTAssertTrue(harness.view.accessibilityValue?.contains("Hidden one") ?? false)
        XCTAssertNotNil(harness.view.blockControls.checkboxes["c2"])
        XCTAssertEqual(harness.view.blockControls.headingRanges().count, 2, "Inner and Section")
        try tap(harness, "t")
        XCTAssertEqual(try laidOut(harness), ["intro", "t", "after", "h"])
        XCTAssertNil(harness.view.blockControls.checkboxes["c2"], "a folded checkbox is removed")
        XCTAssertEqual(harness.view.blockControls.headingRanges().count, 1)
        // No Yjs transaction, no command, no journal entry: view state only.
        XCTAssertEqual(session.engine.revision, revision)
        XCTAssertEqual(session.engine.visitedTypeCount, visited)
        try assertConsistent(harness, localCommands: 0)
    }

    /// The reader (no input coordinator) folds too: folding is not an edit.
    func testTheReadOnlyReaderFolds() throws {
        let session = try NativeEditorSession(state: BlockNoteYjs.encode(seed(), clientID: 1))
        defer { session.close() }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 2_000))
        session.textView.frame = window.bounds
        window.addSubview(session.textView)
        window.isHidden = false
        defer { window.isHidden = true }
        session.textView.layoutIfNeeded()
        let triangle = try XCTUnwrap(session.textView.blockControls.toggleButtons["t"])
        XCTAssertTrue(triangle.isEnabled)
        triangle.sendActions(for: .primaryActionTriggered)
        XCTAssertTrue(session.surface.isExpanded("t"))
        XCTAssertEqual(session.engine.revision, 0)
    }

    // MARK: - Fold, remote change, unfold

    func testARemoteChangeToFoldedChildrenShowsOnUnfold() throws {
        let harness = try makeHarness(seed())
        defer { harness.close() }
        let session = harness.session
        let window = host(harness)
        defer { window.isHidden = true }
        XCTAssertTrue(session.surface.isHidden(blockID: "c1"))

        let peer = try makeDoc(seed(), clientID: 2)
        defer { peer.destroy() }
        let writer = BlockNoteWriter(doc: peer, schemas: BlockNoteWriter.nativePropSchemas)
        try session.integrateServerState(try writer.replaceText(block: "c1", range: 10..<10, with: " edited"))
        // The hidden block's storage took the patch; it is still folded.
        XCTAssertEqual(text(of: try block(session, "c1")), "Hidden one edited")
        XCTAssertTrue(session.surface.isHidden(blockID: "c1"))
        XCTAssertFalse(try laidOut(harness).contains("c1"))
        XCTAssertFalse(harness.view.accessibilityValue?.contains("edited") ?? true)
        try assertConsistent(harness, localCommands: 0)

        try tap(harness, "t")
        XCTAssertTrue(try laidOut(harness).contains("c1"))
        XCTAssertTrue(harness.view.accessibilityValue?.contains("Hidden one edited") ?? false)
        try assertConsistent(harness, localCommands: 0)

        // A toggle that gains a child opens (BlockNote's toggle frame), even
        // when the child came from a peer.
        try tap(harness, "t")
        XCTAssertFalse(session.surface.isExpanded("t"))
        let split = try writer.splitBlock(block: "c2", at: 11, newID: "c9")
        try session.integrateServerState(split)
        XCTAssertTrue(session.surface.isExpanded("t"))
        XCTAssertEqual(try block(session, "c9").parentID, "t")
        XCTAssertTrue(try laidOut(harness).contains("c9"))
        try assertConsistent(harness, localCommands: 0)
    }

    // MARK: - The folded-range rule

    /// A range or mark command over a folded toggle's hidden children is
    /// refused before it is armed; unfolded, a mark command applies to them.
    /// A caret never rests in folded content.
    func testARangeAcrossAFoldedToggleIsRefused() throws {
        let harness = try makeHarness(seed())
        defer { harness.close() }
        let session = harness.session
        let original = harness.view.textStorage.string
        harness.pasteboard.string = "kept"
        try select(harness, from: ("intro", 2), to: ("after", 2))
        harness.view.insertText("x")
        XCTAssertEqual(harness.input.noticeKey, .native_editor_range_unavailable)
        harness.view.deleteBackward()
        harness.view.cut(nil)
        XCTAssertEqual(harness.pasteboard.string, "kept", "a refused cut leaves the pasteboard")
        XCTAssertFalse(harness.input.toggleMark("bold"))
        XCTAssertEqual(harness.view.textStorage.string, original)
        try assertConsistent(harness, localCommands: 0)

        // Expanded, the same bold reaches every block in the range.
        session.surface.setExpanded("t", true)
        try select(harness, from: ("intro", 2), to: ("after", 2))
        XCTAssertTrue(harness.input.toggleMark("bold"))
        XCTAssertTrue(try block(session, "c1").runs.allSatisfy { $0.marks.contains { $0.key == "bold" } })
        try assertConsistent(harness, localCommands: 1)

        // A caret placed inside folded content moves past it, keeping its direction.
        session.surface.setExpanded("t", false)
        try caret(harness, "intro", 0)
        try caret(harness, "c1", 3)
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(session, "after", 0), length: 0))
        try caret(harness, "c2", 1)
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(session, "t", 5), length: 0))
        harness.view.insertText("!")
        XCTAssertEqual(text(of: try block(session, "t")), "Title!", "typing lands in the visible title")
        try assertConsistent(harness, localCommands: 2)
    }

    // MARK: - Editing the title

    func testTitleTypingMarksAndJoins() throws {
        let harness = try makeHarness(
            seed() + [toggle("bare", "Bare"), paragraph("tail", "Tail"), paragraph("last", "Last")])
        defer { harness.close() }
        let session = harness.session
        try caret(harness, "t", 5)
        harness.view.insertText(" here")
        XCTAssertEqual(text(of: try block(session, "t")), "Title here")
        try select(harness, from: ("t", 0), to: ("t", 5))
        XCTAssertTrue(harness.input.toggleMark("italic"))
        XCTAssertEqual(try block(session, "t").runs.first?.marks.map(\.key), ["italic"])
        XCTAssertEqual(try block(session, "t").node, "toggleListItem")
        try assertConsistent(harness, localCommands: 2)

        // Backspace after a childless toggle joins into its title.
        try caret(harness, "tail", 0)
        harness.view.deleteBackward()
        XCTAssertEqual(text(of: try block(session, "bare")), "BareTail")
        XCTAssertEqual(harness.view.selectedRange.location, try location(session, "bare", 4))
        try assertConsistent(harness, localCommands: 3)

        // Backspace after a folded toggle with children: the merge target is
        // its hidden last descendant, so the toggle unfolds first.
        try caret(harness, "after", 0)
        XCTAssertTrue(session.surface.isHidden(blockID: "c3"))
        harness.view.deleteBackward()
        XCTAssertTrue(session.surface.isExpanded("t"))
        XCTAssertEqual(text(of: try block(session, "c3")), "InnerAfter")
        XCTAssertFalse(session.surface.isHidden(blockID: "c3"))
        try assertConsistent(harness, localCommands: 4)
    }

    // MARK: - Return

    func testReturnFollowsTheToggleOpenState() throws {
        let harness = try makeHarness(seed())
        defer { harness.close() }
        let session = harness.session
        // Collapsed: a sibling toggle takes the tail; the hidden children stay.
        try caret(harness, "t", 3)
        harness.view.insertText("\n")
        guard case .split(3, let sibling, let open)? = harness.log.commands.last?.kind else {
            return XCTFail("not a split")
        }
        XCTAssertEqual(open, [])
        XCTAssertEqual(session.surface.blocks.map(\.id), ["intro", "t", "c1", "c2", "c3", sibling, "after"])
        XCTAssertEqual(texts(session)[1], "Tit")
        XCTAssertEqual(try block(session, sibling).node, "toggleListItem")
        XCTAssertEqual(try block(session, sibling).depth, 0)
        XCTAssertEqual(harness.view.selectedRange.location, try location(session, sibling, 0))
        try assertConsistent(harness, localCommands: 1)

        // Expanded: Return at the end of the title inserts a first child.
        session.surface.setExpanded("t", true)
        try caret(harness, "t", 3)
        harness.view.insertText("\n")
        guard case .split(3, let child, ["t"])? = harness.log.commands.last?.kind else {
            return XCTFail("not an open split")
        }
        XCTAssertEqual(session.surface.blocks.map(\.id), ["intro", "t", child, "c1", "c2", "c3", sibling, "after"])
        XCTAssertEqual(try block(session, child).parentID, "t")
        XCTAssertEqual(try block(session, child).node, "paragraph")
        XCTAssertEqual(harness.view.selectedRange.location, try location(session, child, 0))
        try assertConsistent(harness, localCommands: 2)

        // Return in that empty child of an open toggle adds another child.
        harness.view.insertText("\n")
        guard case .split(0, let next, ["t"])? = harness.log.commands.last?.kind else {
            return XCTFail("not a split")
        }
        XCTAssertEqual(try block(session, next).parentID, "t")
        XCTAssertEqual(try block(session, child).parentID, "t", "an open toggle keeps empty children")
        try assertConsistent(harness, localCommands: 3)

        // Return in an empty toggle resets it to a paragraph; its children stay.
        try caret(harness, sibling, 0)
        harness.view.insertText("\n")
        XCTAssertEqual(try block(session, sibling).node, "toggleListItem", "not empty yet: an empty toggle above")
        try assertConsistent(harness, localCommands: 4)
        let empty = session.surface.blocks[try XCTUnwrap(session.surface.rangeIndex.position(for: sibling)) - 1]
        XCTAssertEqual(empty.node, "toggleListItem")
        try caret(harness, empty.id, 0)
        harness.view.insertText("\n")
        XCTAssertEqual(try block(session, empty.id).node, "paragraph")
        try assertConsistent(harness, localCommands: 5)
    }

    func testReturnInAToggleHeading() throws {
        let harness = try makeHarness([toggleHeading("h", "HeadTail", [paragraph("k", "Kid")]), paragraph("z", "Z")])
        defer { harness.close() }
        let session = harness.session
        try caret(harness, "h", 4)
        harness.view.insertText("\n")
        guard case .split(_, let id, _)? = harness.log.commands.last?.kind else { return XCTFail("not a split") }
        XCTAssertEqual(session.surface.blocks.map(\.id), ["h", "k", id, "z"])
        XCTAssertEqual(try block(session, id).node, "paragraph", "a toggle heading splits into a paragraph")
        XCTAssertEqual(try block(session, "k").parentID, "h")
        try assertConsistent(harness, localCommands: 1)
    }

    // MARK: - Backspace

    /// BlockNote's order: a toggle heading resets to a heading, then to a
    /// paragraph, then merges; a toggle list item resets to a paragraph. The
    /// children stay and, no longer under a toggle, show.
    func testBackspaceResetsAToggleFirst() throws {
        let harness = try makeHarness([
            paragraph("a", "A"), toggleHeading("h", "Head", [paragraph("k", "Kid")]),
            toggle("t", "T", [paragraph("j", "J")]),
        ])
        defer { harness.close() }
        let session = harness.session
        XCTAssertTrue(session.surface.isHidden(blockID: "k"))
        try caret(harness, "h", 0)
        harness.view.deleteBackward()
        XCTAssertEqual(try block(session, "h").node, "heading")
        XCTAssertFalse(AttributedDocumentProjection.isToggle(try block(session, "h")))
        XCTAssertFalse(session.surface.isHidden(blockID: "k"))
        try assertConsistent(harness, localCommands: 1)
        harness.view.deleteBackward()
        XCTAssertEqual(try block(session, "h").node, "paragraph")
        harness.view.deleteBackward()
        XCTAssertEqual(text(of: try block(session, "a")), "AHead")
        XCTAssertEqual(try block(session, "k").depth, 0, "the merged block's children take its place")
        try assertConsistent(harness, localCommands: 3)

        try caret(harness, "t", 0)
        harness.view.deleteBackward()
        XCTAssertEqual(try block(session, "t").node, "paragraph")
        XCTAssertEqual(try block(session, "j").parentID, "t")
        XCTAssertFalse(session.surface.isHidden(blockID: "j"))
        try assertConsistent(harness, localCommands: 4)
    }

    // MARK: - Slash menu

    func testSlashConvertsToTogglesDurably() throws {
        let harness = try makeHarness([paragraph("p", "/toggle"), paragraph("q", "/toggle")])
        defer { harness.close() }
        let session = harness.session
        try caret(harness, "p", 7)
        XCTAssertEqual(harness.input.slashMenuQuery, "toggle")
        let offered = filteredSlashItems(query: "toggle", items: NativeInputCoordinator.slashItems)
        XCTAssertEqual(offered.map(\.id), ["toggleHeading", "toggleList"])
        XCTAssertFalse(allSlashMenuItems.contains { $0.id.hasPrefix("toggle") }, "never in the classic menu")
        XCTAssertTrue(harness.input.applySlashItem(toggleListSlashItem))
        XCTAssertEqual(try block(session, "p").node, "toggleListItem")
        XCTAssertEqual(text(of: try block(session, "p")), "")
        guard case .blockType("toggleListItem", [], 0..<7)? = harness.log.commands.last?.kind else {
            return XCTFail("not one type change")
        }
        try assertConsistent(harness, localCommands: 1)

        try caret(harness, "q", 7)
        XCTAssertTrue(harness.input.applySlashItem(toggleHeadingSlashItem))
        let heading = try block(session, "q")
        XCTAssertEqual(heading.node, "heading")
        XCTAssertTrue(heading.props.contains(ProjectedProp(key: "level", value: .int(1))))
        XCTAssertTrue(AttributedDocumentProjection.isToggle(heading))
        try assertConsistent(harness, localCommands: 2)
        XCTAssertNotNil(Strings_en.table[.editor_slash_toggle_list])
    }

    // MARK: - Indent and outdent

    func testIndentAndOutdentWithToggleChildren() throws {
        let harness = try makeHarness(seed() + [paragraph("more", "More")])
        defer { harness.close() }
        let session = harness.session
        session.surface.setExpanded("t", true)
        try caret(harness, "c2", 2)
        XCTAssertTrue(harness.input.indent())
        XCTAssertEqual(try block(session, "c2").parentID, "c1")
        XCTAssertEqual(try block(session, "c2").depth, 2)
        XCTAssertEqual(harness.view.selectedRange.location, try location(session, "c2", 2))
        XCTAssertTrue(harness.input.outdent())
        XCTAssertEqual(try block(session, "c2").parentID, "t")
        try assertConsistent(harness, localCommands: 2)

        // Tab under a folded toggle: it gains a child, so it opens, and the
        // moved block (and the caret in it) stays visible.
        session.surface.setExpanded("t", false)
        try caret(harness, "after", 1)
        harness.view.insertText("\t")
        XCTAssertEqual(try block(session, "after").parentID, "t")
        XCTAssertTrue(session.surface.isExpanded("t"))
        XCTAssertFalse(session.surface.isHidden(blockID: "after"))
        XCTAssertEqual(harness.view.selectedRange.location, try location(session, "after", 1))
        try assertConsistent(harness, localCommands: 3)

        // Moving the toggle itself carries its children and its fold state.
        session.surface.setExpanded("t", false)
        try caret(harness, "t", 0)
        XCTAssertTrue(harness.input.indent())
        XCTAssertEqual(try block(session, "t").parentID, "intro")
        XCTAssertEqual(try block(session, "c1").depth, 2)
        XCTAssertFalse(session.surface.isExpanded("t"))
        XCTAssertTrue(session.surface.isHidden(blockID: "c1"))
        try assertConsistent(harness, localCommands: 4)
    }

    // MARK: - Relaunch

    func testRelaunchReplaysTogglesAndFoldsThemAgain() throws {
        let harness = try makeHarness([paragraph("p", "/toggle"), paragraph("z", "Zed")])
        let session = harness.session
        try caret(harness, "p", 7)
        XCTAssertTrue(harness.input.applySlashItem(toggleListSlashItem))
        session.textView.insertText("Notes")
        session.surface.setExpanded("p", true)
        session.textView.insertText("\n")
        session.textView.insertText("First child")
        session.surface.setExpanded("p", false)
        try assertConsistent(harness, localCommands: 4)
        let expected = session.surface.blocks
        XCTAssertEqual(expected.map(\.depth), [0, 1, 0])
        let expectedText = session.textView.textStorage.string
        session.close()

        let restored = try XCTUnwrap(NativeEditorSession.restore(store: harness.store, scope: harness.scope))
        defer {
            restored.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }
        XCTAssertEqual(restored.surface.blocks, expected)
        XCTAssertEqual(restored.textView.textStorage.string, expectedText)
        XCTAssertEqual(restored.engine.revision, 4)
        // Fold state is this open document's memory only: a reopened toggle is collapsed.
        XCTAssertEqual(restored.surface.hidden, [false, true, false])
    }
}
