import UIKit
import XCTest

@testable import Schrift

/// PR12c: the column editor's presentation. Regular width puts the columns
/// side by side at their relative widths, compact width stacks them, both in
/// one scroll; a change between them keeps focus, the selection, marked text
/// and a pending prediction; a 2,000-block group realises only the screen;
/// VoiceOver reads each column as "Column 2 of 3" with a Columns rotor; find
/// and the outline reach into columns; the caret follows a block moved to
/// another column.
@MainActor
final class ColumnLayoutTests: NativeEditingTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows {
            window.endEditing(true)
            window.isHidden = true
        }
        windows = []
        try await super.tearDown()
    }

    private func fixture(_ name: String) throws -> Data {
        let base64 = BlockNoteColumnCaptures.fixtures.first { $0.name == name }?.update
        return try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(base64, name)))
    }

    /// The editor's model over `state`, loaded.
    private func editor(_ state: Data, target: (column: String, block: String)? = nil) async throws -> (
        Harness, ColumnEditorModel
    ) {
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }
        let model = ColumnEditorModel(document: harness.session, groupID: "cl", target: target)
        addTeardownBlock { model.close() }
        await model.load()
        XCTAssertEqual(model.columns.count, model.group?.columns.count)
        return (harness, model)
    }

    /// A container in a key window of `size`, regular or compact, showing the model's columns.
    private func container(
        _ model: ColumnEditorModel, size: CGSize, regular: Bool, contentSize: UIContentSizeCategory = .large
    ) -> ColumnTextContainer {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(origin: .zero, size: size)
        window.traitOverrides.horizontalSizeClass = regular ? .regular : .compact
        let container = ColumnTextContainer(frame: window.bounds)
        container.contentSizeCategory = contentSize
        container.onActivate = { [model] in model.active = $0 }
        window.addSubview(container)
        window.makeKeyAndVisible()
        windows.append(window)
        show(model, in: container)
        return container
    }

    private func show(_ model: ColumnEditorModel, in container: ColumnTextContainer) {
        container.show(
            model.columns.map(\.textView), widths: model.group?.columns.map { $0.width ?? 1 } ?? [],
            active: model.active)
        for _ in 0..<3 { container.layoutIfNeeded() }
    }

    private func resize(_ container: ColumnTextContainer, to size: CGSize, regular: Bool) {
        container.window?.frame = CGRect(origin: .zero, size: size)
        container.window?.traitOverrides.horizontalSizeClass = regular ? .regular : .compact
        container.frame = CGRect(origin: .zero, size: size)
        for _ in 0..<3 { container.layoutIfNeeded() }
    }

    private func setSelection(_ session: NativeEditorSession, _ range: NSRange) {
        session.textView.selectedRange = range
        session.input?.textViewDidChangeSelection(session.textView)
    }

    // MARK: - Layout

    /// Regular width: the three columns of "widths" (1.5, 0.75, 0.75) sit side
    /// by side at those proportions, top-aligned in one scroll.
    func testRegularWidthPutsColumnsSideBySideAtTheirWidths() async throws {
        let (_, model) = try await editor(try fixture("widths"))
        let container = container(model, size: CGSize(width: 1024, height: 700), regular: true)
        XCTAssertEqual(container.layout, .sideBySide)
        let frames = container.frames.map(\.frame)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames.map(\.minY), [0, 0, 0], "top-aligned")
        XCTAssertEqual(frames[0].width, 500, accuracy: 1)
        XCTAssertEqual(frames[1].width, 250, accuracy: 1)
        XCTAssertEqual(frames[2].width, 250, accuracy: 1)
        XCTAssertLessThan(frames[0].maxX, frames[1].minX)
        XCTAssertLessThan(frames[1].maxX, frames[2].minX)
        XCTAssertTrue(container.frames.allSatisfy { !$0.isHidden && $0.textView.window != nil })
        XCTAssertEqual(model.columns[0].textView.frame.size, frames[0].size, "each text view fills its column")
    }

    /// Compact width (and regular width too narrow for the narrowest column)
    /// stacks the columns, one after the other, in one scroll.
    func testCompactWidthStacksTheColumns() async throws {
        let (_, model) = try await editor(try fixture("widths"))
        let container = container(model, size: CGSize(width: 390, height: 2_000), regular: false)
        XCTAssertEqual(container.layout, .stacked)
        let frames = container.frames.map(\.frame)
        XCTAssertTrue(frames.allSatisfy { $0.minX == 0 && $0.width == 390 }, "\(frames)")
        XCTAssertLessThan(frames[0].maxY, frames[1].minY)
        XCTAssertLessThan(frames[1].maxY, frames[2].minY)
        XCTAssertGreaterThanOrEqual(container.contentSize.height, frames[2].maxY)
        // A regular-width window too narrow for a 0.75 column at 220 pt stacks too.
        resize(container, to: CGSize(width: 700, height: 2_000), regular: true)
        XCTAssertEqual(container.layout, .stacked)
    }

    /// A change between side by side and stacked (rotation, split view,
    /// Stage Manager) moves frames only: the column keeps first responder,
    /// its selection and its marked text, and a key typed just before the
    /// change is journaled once.
    func testChangingLayoutKeepsFocusSelectionMarkedTextAndAPendingKey() async throws {
        let (harness, model) = try await editor(try fixture("two"))
        let container = container(model, size: CGSize(width: 1024, height: 700), regular: true)
        XCTAssertEqual(container.layout, .sideBySide)
        let column = model.columns[1]
        XCTAssertTrue(column.textView.becomeFirstResponder())
        XCTAssertEqual(model.active, 1, "focus makes the column active")
        setSelection(column, NSRange(location: try location(column, "c", 5), length: 0))
        // A pending prediction: typed, not yet confirmed by the replica.
        column.textView.insertText("!")
        resize(container, to: CGSize(width: 390, height: 700), regular: false)
        XCTAssertEqual(container.layout, .stacked)
        XCTAssertTrue(column.textView.isFirstResponder, "focus stays")
        XCTAssertEqual(column.textView.selectedRange, NSRange(location: try location(column, "c", 6), length: 0))
        // Marked text across the change back.
        column.textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNotNil(column.textView.markedTextRange)
        resize(container, to: CGSize(width: 1024, height: 700), regular: true)
        XCTAssertEqual(container.layout, .sideBySide)
        XCTAssertTrue(column.textView.isFirstResponder)
        XCTAssertNotNil(column.textView.markedTextRange, "marked text stays")
        column.textView.unmarkText()
        await column.settle()
        await harness.settle()
        XCTAssertEqual(text(of: try block(column, "c")), "Right!か")
        XCTAssertEqual(harness.log.commands.count, 2, "the key and the composition, once each")
    }

    /// Dynamic Type: a larger size lays the columns out again at their new
    /// heights (nothing clipped), and side by side gives way to stacked when
    /// the narrowest column would be too narrow for the text.
    func testDynamicTypeRelaysOutWithoutClipping() async throws {
        let (_, model) = try await editor(try fixture("widths"))
        let container = container(model, size: CGSize(width: 1024, height: 700), regular: true)
        XCTAssertEqual(container.layout, .sideBySide)
        let before = model.columns[0].textView.contentSize.height
        let large = UIContentSizeCategory.accessibilityExtraExtraExtraLarge
        for session in model.columns {
            session.surface.updatePresentation(
                traits: UITraitCollection(preferredContentSizeCategory: large), labels: session.surface.labels)
        }
        container.contentSizeCategory = large
        for _ in 0..<5 { container.layoutIfNeeded() }
        XCTAssertEqual(container.layout, .stacked)
        XCTAssertGreaterThan(model.columns[0].textView.contentSize.height, before)
        var y: CGFloat = 0
        for frame in container.frames {
            let height = frame.textView.contentSize.height
            container.contentOffset.y = y
            container.layoutIfNeeded()
            XCTAssertEqual(frame.frame.minY, y, accuracy: 0.5, "the column starts where the last one ended")
            XCTAssertGreaterThanOrEqual(container.contentSize.height, y + height, "nothing clipped")
            y += height + ColumnTextContainer.spacing
        }
    }

    // MARK: - Scale

    /// A document with one column group of `columns` columns of `perColumn`
    /// paragraphs each ("c<column>p<index>"), between two paragraphs.
    /// `toggle` puts a collapsed toggle heading "c0t" first in column 0, holding paragraph "c0inside".
    nonisolated static func groupState(columns: Int, perColumn: Int, toggle: Bool = false) throws -> Data {
        let doc = YDoc(clientID: 1, gc: true)
        defer { doc.destroy() }
        let root = doc.get(BlockNoteYjs.fragmentField)
        try doc.transact { tx in
            func element(_ name: String, into parent: YType, after: YItem?, id: String? = nil) throws -> (YItem?, YType)
            {
                let type = YType(typeRef: .xmlElement(nodeName: name))
                let item = try YWrite.insertAfter(tx, into: parent, after: after, [.type(type)])
                if let id { try YWrite.mapSet(tx, on: type, key: "id", .any([.string(id)])) }
                return (item, type)
            }
            func paragraph(_ id: String, _ text: String, into parent: YType, after: YItem?) throws -> YItem? {
                let (item, container) = try element("blockContainer", into: parent, after: after, id: id)
                let (_, paragraph) = try element("paragraph", into: container, after: nil)
                for (key, value) in [
                    ("backgroundColor", "default"), ("textColor", "default"), ("textAlignment", "left"),
                ] {
                    try YWrite.mapSet(tx, on: paragraph, key: key, .any([.string(value)]))
                }
                let xmlText = YType(typeRef: .xmlText)
                try YWrite.insertAfter(tx, into: paragraph, after: nil, [.type(xmlText)])
                try xmlText.insert(0, text, YTextAttributes())
                return item
            }
            let (_, group) = try element("blockGroup", into: root, after: nil)
            let lead = try paragraph("lead", "Before", into: group, after: nil)
            let (listItem, list) = try element("columnList", into: group, after: lead, id: "cl")
            var lastColumn: YItem?
            for column in 0..<columns {
                let (item, columnType) = try element("column", into: list, after: lastColumn, id: "c\(column)")
                try YWrite.mapSet(tx, on: columnType, key: "width", .any([.int(1)]))
                lastColumn = item
                var last: YItem?
                if toggle, column == 0 {
                    let (item, container) = try element("blockContainer", into: columnType, after: nil, id: "c0t")
                    let (headingItem, heading) = try element("heading", into: container, after: nil)
                    for (key, value): (String, YAnyValue) in [
                        ("backgroundColor", .string("default")), ("textColor", .string("default")),
                        ("textAlignment", .string("left")), ("level", .int(2)), ("isToggleable", .bool(true)),
                    ] {
                        try YWrite.mapSet(tx, on: heading, key: key, .any([value]))
                    }
                    let xmlText = YType(typeRef: .xmlText)
                    try YWrite.insertAfter(tx, into: heading, after: nil, [.type(xmlText)])
                    try xmlText.insert(0, "Toggle", YTextAttributes())
                    let (_, nested) = try element("blockGroup", into: container, after: headingItem)
                    _ = try paragraph("c0inside", "Hidden words", into: nested, after: nil)
                    last = item
                }
                for index in 0..<perColumn {
                    last = try paragraph(
                        "c\(column)p\(index)", "Column \(column) paragraph \(index) with words enough to wrap.",
                        into: columnType, after: last)
                }
            }
            _ = try paragraph("tail", "After", into: group, after: listItem)
        }
        return try YStateEncoder.encodeStateAsUpdate(doc)
    }

    private static func percentile(_ times: [Duration], _ fraction: Double) -> Duration {
        let sorted = times.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
    }

    /// The blocks a column's text view has laid out: its viewport's.
    private func realised(_ view: NativeTextView, _ session: NativeEditorSession) -> Int {
        guard let layout = view.textLayoutManager, let content = layout.textContentManager,
            let range = layout.textViewportLayoutController.viewportRange
        else { return 0 }
        let start = content.offset(from: content.documentRange.location, to: range.location)
        let end = content.offset(from: content.documentRange.location, to: range.endLocation)
        return session.surface.rangeIndex.entries.filter {
            $0.range.location < end && NSMaxRange($0.range) > start
        }.count
    }

    /// The fixture gate: a 2,000-block group (two columns of 1,000) opens,
    /// realises only a screen of each column, scrolls, and types far down
    /// within the provisional budget. Debug-simulator numbers are printed.
    func testA2000BlockGroupRealisesOnlyTheScreenAndTypesWithinBudget() async throws {
        let clock = ContinuousClock()
        let state = try Self.groupState(columns: 2, perColumn: 1_000)
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }
        XCTAssertTrue(harness.session.canType, "a group at the bound is familiar")
        var start = clock.now
        let model = ColumnEditorModel(document: harness.session, groupID: "cl")
        addTeardownBlock { model.close() }
        await model.load()
        let load = clock.now - start
        XCTAssertEqual(model.columns.count, 2)
        start = clock.now
        let container = container(model, size: CGSize(width: 390, height: 844), regular: false)
        let firstFrame = clock.now - start
        for (session, frame) in zip(model.columns, container.frames) {
            XCTAssertLessThan(realised(frame.textView, session), 60, "a screen of the column, not 1,000 blocks")
        }
        var steps: [Duration] = []
        for step in 1...100 {
            start = clock.now
            container.contentOffset.y = CGFloat(step) * 120
            container.layoutIfNeeded()
            steps.append(clock.now - start)
        }
        // Into the second column, far down: it types there.
        container.contentOffset.y = container.contentSize.height - 2_000
        container.layoutIfNeeded()
        let second = model.columns[1]
        let target = "c1p900"
        XCTAssertTrue(second.textView.becomeFirstResponder())
        setSelection(second, NSRange(location: try location(second, target, 0), length: 0))
        var keys: [Duration] = []
        for _ in 0..<50 {
            start = clock.now
            second.textView.insertText("x")
            container.layoutIfNeeded()
            keys.append(clock.now - start)
        }
        await second.settle()
        await harness.settle()
        XCTAssertTrue(text(of: try block(second, target)).hasPrefix(String(repeating: "x", count: 50)))
        XCTAssertEqual(harness.log.commands.count, 50)
        for (session, frame) in zip(model.columns, container.frames) {
            XCTAssertLessThan(realised(frame.textView, session), 60, "still a screen")
        }
        print(
            "SCALE columns 2x1000 load \(load), first frame \(firstFrame), scroll p50 \(Self.percentile(steps, 0.5)) p99 \(Self.percentile(steps, 0.99)), key p50 \(Self.percentile(keys, 0.5)) p95 \(Self.percentile(keys, 0.95))"
        )
        // Generous for a debug build on the simulator; the provisional device
        // budget (first frame < 500 ms, typing p95 < 8.3 ms) is TestFlight's.
        XCTAssertLessThan(load + firstFrame, .seconds(3))
        XCTAssertLessThan(Self.percentile(keys, 0.95), .milliseconds(100))
        XCTAssertLessThan(Self.percentile(steps, 0.99), .milliseconds(100))
    }

    /// Typing with the caret below the screen scrolls the container to it.
    func testTypingScrollsTheContainerToTheCaret() async throws {
        let (harness, model) = try await editor(try Self.groupState(columns: 2, perColumn: 40))
        let container = container(model, size: CGSize(width: 390, height: 400), regular: false)
        let second = model.columns[1]
        XCTAssertTrue(second.textView.becomeFirstResponder())
        container.contentOffset.y = 0
        container.layoutIfNeeded()
        setSelection(second, NSRange(location: try location(second, "c1p30", 0), length: 0))
        second.textView.insertText("x")
        for _ in 0..<3 { container.layoutIfNeeded() }
        await harness.settle()
        let caret = second.textView.caretRect(for: try XCTUnwrap(second.textView.selectedTextRange).end)
        let shown = second.textView.convert(caret, to: container)
        XCTAssertTrue(container.bounds.intersects(shown), "the caret is on screen: \(shown) in \(container.bounds)")
    }

    // MARK: - VoiceOver

    /// Each column is a container "Column 2 of 3" in column order, and the
    /// Columns rotor moves between the columns' text.
    func testEachColumnIsALabelledContainerWithAColumnsRotor() async throws {
        let (_, model) = try await editor(try fixture("widths"))
        let container = container(model, size: CGSize(width: 1024, height: 700), regular: true)
        XCTAssertEqual(container.accessibilityElements?.count, 3)
        XCTAssertTrue(container.accessibilityElements?.first as AnyObject === container.frames[0])
        XCTAssertEqual(
            container.frames.map { $0.accessibilityLabel }, ["Column 1 of 3", "Column 2 of 3", "Column 3 of 3"])
        XCTAssertTrue(container.frames.allSatisfy { $0.accessibilityContainerType == .semanticGroup })
        let rotor = try XCTUnwrap(container.accessibilityCustomRotors?.first)
        XCTAssertEqual(rotor.name, "Columns")
        func step(from view: UIView, _ direction: UIAccessibilityCustomRotor.Direction) -> UIView? {
            let predicate = UIAccessibilityCustomRotorSearchPredicate()
            predicate.currentItem = UIAccessibilityCustomRotorItemResult(targetElement: view, targetRange: nil)
            predicate.searchDirection = direction
            return rotor.itemSearchBlock(predicate)?.targetElement as? UIView
        }
        let views = model.columns.map(\.textView)
        XCTAssertTrue(step(from: views[0], .next) === views[1])
        XCTAssertTrue(step(from: views[2], .previous) === views[1])
        XCTAssertNil(step(from: views[2], .next))
        XCTAssertTrue(step(from: container, .next) === views[0], "from outside a column: the first")
        // Localised from the host's labels.
        var labels = NativeEditorLabels()
        labels.column = "Spalte %d von %d"
        labels.columnsRotor = "Spalten"
        container.labels = labels
        XCTAssertEqual(container.frames[1].accessibilityLabel, "Spalte 2 von 3")
        XCTAssertEqual(rotor.name, "Spalten")
    }

    /// The group's card in the document is a VoiceOver button that names the
    /// group and reads each column's first lines.
    func testTheGroupCardAnnouncesItsColumns() async throws {
        let harness = try await makeHarness(state: try fixture("two"))
        addTeardownBlock { await harness.close() }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        harness.view.frame = window.bounds
        window.addSubview(harness.view)
        window.isHidden = false
        windows.append(window)
        harness.view.layoutIfNeeded()
        func find(_ view: UIView) -> UIView? {
            if view.accessibilityIdentifier == "nativeEditor.attachment.cl" { return view }
            return view.subviews.lazy.compactMap(find).first
        }
        var card = find(harness.view)
        for _ in 0..<20 where card == nil {
            try await Task.sleep(for: .milliseconds(50))
            harness.view.layoutIfNeeded()
            card = find(harness.view)
        }
        let found = try XCTUnwrap(card, "the card is realised")
        XCTAssertTrue(found.isAccessibilityElement)
        XCTAssertTrue(found.accessibilityTraits.contains(.button))
        XCTAssertEqual(found.accessibilityLabel, "Columns, 2")
        let value = try XCTUnwrap(found.accessibilityValue)
        XCTAssertTrue(value.hasPrefix("Column 1 of 2, Left text"), value)
        XCTAssertTrue(value.contains("Column 2 of 2, Right"), value)
    }

    // MARK: - Find and the outline

    /// Find and the outline read a column's blocks after the group's card; a
    /// result in a column opens the editor there through a generation-safe
    /// handle, changing nothing in the document.
    func testFindAndOutlineReachIntoColumnsAndOpenTheEditorThere() async throws {
        let harness = try await makeHarness(state: try fixture("widths"))
        addTeardownBlock { await harness.close() }
        let navigation = harness.session.navigation
        await navigation.refresh()
        let texts = navigation.blocks.map(\.text)
        XCTAssertTrue(texts.contains("done"), "a column's text is found: \(texts)")
        let heading = try XCTUnwrap(navigation.blocks.first { $0.kind == .heading(level: 2) }, "outlined")
        XCTAssertEqual(heading.text, "Wide")
        var opened: [String] = []
        navigation.onOpenColumn = { opened = [$0, $1, $2] }
        let before = try await unwrapped(
            harness.session.replicaDoc { YStateEncoder.encodeStateVector($0).base64EncodedString() })
        let selection = harness.view.selectedRange
        let done = try XCTUnwrap(navigation.entries.first { $0.value.blockID == "k" }?.key)
        let jumped = await navigation.jump(to: .block(done))
        XCTAssertTrue(jumped)
        XCTAssertEqual(opened, ["cl", "c2", "k"])
        let after = try await unwrapped(
            harness.session.replicaDoc { YStateEncoder.encodeStateVector($0).base64EncodedString() })
        XCTAssertEqual(after, before, "nothing written")
        XCTAssertEqual(harness.view.selectedRange, selection, "the document's selection stays")
        XCTAssertTrue(harness.log.commands.isEmpty)
        // The editor opens with that column active and the caret at the block's start.
        let model = ColumnEditorModel(document: harness.session, groupID: "cl", target: ("c2", "k"))
        addTeardownBlock { model.close() }
        await model.load()
        XCTAssertEqual(model.active, 1)
        let column = try XCTUnwrap(model.activeSession)
        XCTAssertEqual(column.textView.selectedRange, NSRange(location: try location(column, "k", 0), length: 0))
        await column.settle()
        XCTAssertTrue(harness.log.commands.isEmpty, "the jump writes nothing")
    }

    /// A handle read before its block moved to another column does not jump
    /// (the move re-created it); a fresh read does, to the new column.
    func testAStaleColumnHandleDoesNotJump() async throws {
        let (harness, model) = try await editor(try fixture("two"))
        let navigation = harness.session.navigation
        await navigation.refresh()
        let stale = try XCTUnwrap(navigation.entries.first { $0.value.blockID == "c" }?.key)
        let second = model.columns[1]
        setSelection(second, NSRange(location: try location(second, "c", 0), length: 0))
        // Backspace at the second column's first block moves it to the end of the first.
        second.textView.deleteBackward()
        await second.settle()
        await harness.settle()
        var opened: [String] = []
        navigation.onOpenColumn = { opened = [$0, $1, $2] }
        let jumpedStale = await navigation.jump(to: .block(stale))
        XCTAssertFalse(jumpedStale, "the moved block is another item now")
        XCTAssertTrue(opened.isEmpty)
        await navigation.refresh()
        let fresh = try XCTUnwrap(navigation.entries.first { $0.value.blockID == "c" }?.key)
        let jumped = await navigation.jump(to: .block(fresh))
        XCTAssertTrue(jumped)
        XCTAssertEqual(opened, ["cl", "c1", "c"])
    }

    // MARK: - Moves

    /// The 12b limit: Move down of a column's last block takes it to the next
    /// column's top, and the caret goes with it (that column is active).
    func testTheCaretFollowsABlockMovedToTheNextColumn() async throws {
        let seed = try XCTUnwrap(
            BlockNoteColumnStructureCaptures.edits.first { $0.name == "moveDownFromColumnEnd" }?.seed)
        let (harness, model) = try await editor(try XCTUnwrap(Data(base64Encoded: seed)))
        let first = model.columns[0]
        let second = model.columns[1]
        setSelection(first, NSRange(location: try location(first, "b", 2), length: 0))
        let moved = await first.run { first.input?.performBlockAction(.moveDown) ?? false }
        XCTAssertTrue(moved)
        await second.settle()
        await harness.settle()
        await waitUntil { model.active == 1 }
        XCTAssertEqual(second.surface.blocks.first?.id, "b")
        XCTAssertEqual(model.active, 1, "the next column is active")
        XCTAssertEqual(second.textView.selectedRange, NSRange(location: try location(second, "b", 2), length: 0))
    }

    // MARK: - PR #285 review

    private func structureSeed(_ name: String) throws -> Data {
        let seed = try XCTUnwrap(BlockNoteColumnStructureCaptures.edits.first { $0.name == name }?.seed, name)
        return try XCTUnwrap(Data(base64Encoded: seed))
    }

    /// F1: following a query as it is typed never opens the column editor
    /// (the rest of the query would be typed there): it scrolls the document
    /// to the group's card. A deliberate jump opens it once, however many
    /// replies are in flight, until it closes.
    func testTypingAQueryNeverOpensTheColumnEditorAndADeliberateJumpOpensItOnce() async throws {
        let harness = try await makeHarness(state: try Self.groupState(columns: 2, perColumn: 40))
        addTeardownBlock { await harness.close() }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        harness.view.frame = window.bounds
        window.addSubview(harness.view)
        window.isHidden = false
        windows.append(window)
        harness.view.layoutIfNeeded()
        let navigation = harness.session.navigation
        await navigation.refresh()
        var opened = 0
        navigation.onOpenColumn = { _, _, _ in opened += 1 }
        let match = try XCTUnwrap(navigation.entries.first { $0.value.blockID == "c1p3" }?.key)
        let followed = await navigation.jump(to: .block(match), deliberate: false)
        XCTAssertTrue(followed)
        XCTAssertEqual(opened, 0, "typing a query never opens the editor")
        // Two deliberate jumps in flight: one editor.
        async let first = navigation.jump(to: .block(match))
        async let second = navigation.jump(to: .block(match))
        _ = await (first, second)
        XCTAssertEqual(opened, 1)
        navigation.columnEditorClosed()
        await navigation.jump(to: .block(match))
        XCTAssertEqual(opened, 2, "once closed, the next result opens it")
    }

    /// F1: an editor opened at a find result does not take first responder;
    /// one opened from the card does.
    func testAnEditorOpenedAtAResultDoesNotTakeTheKeyboard() async throws {
        let (_, model) = try await editor(try fixture("two"), target: ("c2", "c"))
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        let container = ColumnTextContainer(frame: window.bounds)
        container.takesFocusOnOpen = false
        window.addSubview(container)
        window.makeKeyAndVisible()
        windows.append(window)
        show(model, in: container)
        XCTAssertTrue(container.shown === model.columns[1].textView)
        XCTAssertFalse(model.columns.contains { $0.textView.isFirstResponder }, "no keyboard")
    }

    /// F2: a key typed while Move down takes the caret's block into the next
    /// column is typed there, in the moved block, never in the column it left.
    func testAKeyHeldDuringAMoveIsTypedWhereTheBlockWent() async throws {
        let (harness, model) = try await editor(try structureSeed("moveDownFromColumnEnd"))
        let first = model.columns[0]
        let second = model.columns[1]
        let before = first.surface.blocks.filter { $0.id != "b" }.map { text(of: $0) }
        setSelection(first, NSRange(location: try location(first, "b", 2), length: 0))
        XCTAssertTrue(first.input?.performBlockAction(.moveDown) ?? false)
        first.textView.insertText("z")
        await first.settle()
        await second.settle()
        await harness.settle()
        await waitUntil { model.active == 1 && (try? self.text(of: self.block(second, "b")))?.contains("z") == true }
        await second.settle()
        await harness.settle()
        let moved = text(of: try block(second, "b"))
        XCTAssertEqual(moved.firstIndex(of: "z").map { moved.distance(from: moved.startIndex, to: $0) }, 2, moved)
        XCTAssertEqual(first.surface.blocks.map { text(of: $0) }, before, "nothing typed in the column it left")
        XCTAssertTrue(harness.session.input?.composition.pendingRecoveries.isEmpty ?? true)
    }

    /// F3: Backspace at a column's first block moves it to the end of the
    /// previous column, and the caret goes with it.
    func testBackspaceAcrossAColumnEdgeTakesTheCaretWithTheBlock() async throws {
        let (harness, model) = try await editor(try fixture("two"))
        model.active = 1
        let first = model.columns[0]
        let second = model.columns[1]
        setSelection(second, NSRange(location: try location(second, "c", 0), length: 0))
        second.textView.deleteBackward()
        await second.settle()
        await first.settle()
        await harness.settle()
        await waitUntil { model.active == 0 }
        XCTAssertEqual(first.surface.blocks.last?.id, "c")
        XCTAssertEqual(model.active, 0, "the previous column is active")
        XCTAssertEqual(first.textView.selectedRange, NSRange(location: try location(first, "c", 0), length: 0))
    }

    /// F4: a column command never reports its block as moved: deleting the
    /// shown column and undoing it does not later pull the caret into it.
    func testDeletingAndRestoringAColumnDoesNotPullTheCaretLater() async throws {
        let (harness, model) = try await editor(try structureSeed("removeColumnOfThree"))
        model.active = 2
        let shown = model.columns[2]
        let id = try XCTUnwrap(shown.surface.blocks.first?.id)
        setSelection(shown, NSRange(location: try location(shown, id, 0), length: 0))
        XCTAssertTrue(model.perform(.delete))
        await waitUntil { model.columns.count == 2 }
        model.active = 0
        let first = model.columns[0]
        _ = first.input?.undo()
        await waitUntil { model.columns.count == 3 }
        await harness.settle()
        let firstID = try XCTUnwrap(first.surface.blocks.first?.id)
        setSelection(first, NSRange(location: try location(first, firstID, 0), length: 0))
        first.textView.insertText("k")
        for session in model.columns { await session.settle() }
        await harness.settle()
        XCTAssertEqual(model.active, 0, "typing stays in its column")
        XCTAssertTrue(text(of: try block(first, firstID)).hasPrefix("k"))
    }

    /// F5: a result inside a collapsed toggle in a column opens it (view
    /// state) before the caret goes there.
    func testAResultInsideACollapsedToggleIsRevealed() async throws {
        let state = try Self.groupState(columns: 2, perColumn: 2, toggle: true)
        let (_, model) = try await editor(state, target: ("c0", "c0inside"))
        let column = try XCTUnwrap(model.activeSession)
        XCTAssertEqual(model.active, 0)
        XCTAssertFalse(column.surface.isHidden(blockID: "c0inside"), "the toggle opened")
        XCTAssertEqual(
            column.textView.selectedRange, NSRange(location: try location(column, "c0inside", 0), length: 0))
        // Without a target the toggle starts collapsed, as BlockNote's does.
        let (_, plain) = try await editor(state)
        XCTAssertTrue(try XCTUnwrap(plain.columns.first).surface.isHidden(blockID: "c0inside"))
    }

}
