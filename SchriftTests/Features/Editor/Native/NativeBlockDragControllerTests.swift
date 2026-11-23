import UIKit
import XCTest

@testable import Schrift

/// Unit and coordinator tests for `NativeBlockDragController` and its pure
/// slot/depth, auto-scroll, handle-visibility, and announcement helpers.
@MainActor
final class NativeBlockDragControllerTests: NativeEditingTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows { window.isHidden = true }
        windows = []
        try await super.tearDown()
    }

    private func mount(_ textView: NativeTextView, size: CGSize = CGSize(width: 390, height: 600)) -> UIWindow {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.addSubview(textView)
        textView.frame = window.bounds
        window.isHidden = false
        textView.layoutIfNeeded()
        windows.append(window)
        return window
    }

    private func snap(
        _ id: String,
        node: String = "paragraph",
        text: String? = nil,
        depth: Int = 0,
        parentID: String? = nil,
        props: [ProjectedProp] = [],
        preview: NativeBlockPreview? = nil,
        isOpaque: Bool = false,
        isLocked: Bool = false
    ) -> BlockSnapshot {
        var snapshot = BlockSnapshot(
            id: id,
            node: node,
            props: props,
            runs: (text ?? id).isEmpty ? [] : [InlineRun(text ?? id)],
            isOpaque: isOpaque,
            depth: depth,
            parentID: parentID)
        snapshot.preview = preview
        snapshot.isLocked = isLocked
        return snapshot
    }

    private func toggle(_ id: String, _ text: String, children: [BlockNoteBlock] = []) -> BlockNoteBlock {
        BlockNoteBlock(
            node: "toggleListItem", props: Self.paragraphProps, runs: [InlineRun(text)], id: id, children: children)
    }

    private func tableDoc() throws -> Data {
        let doc = YDoc(clientID: 1, gc: true)
        defer { doc.destroy() }
        let base = BlockNoteYjs.encode([paragraph("p1", "First"), paragraph("p2", "Second")], clientID: 1)
        try doc.applyUpdate(YUpdateDecoder.decode(base))
        let root = try XCTUnwrap(doc.share[BlockNoteYjs.fragmentField])
        guard case .type(let group)? = YBlockProjection.children(of: root, includeFormats: false).first?.content else {
            XCTFail("missing root group")
            return base
        }
        try doc.transact { tx in
            let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            _ = try YWrite.insertAfter(tx, into: group, after: nil, [.type(container)])
            try YWrite.mapSet(tx, on: container, key: "id", .any([.string("tbl")]))
            let table = YType(typeRef: .xmlElement(nodeName: "table"))
            _ = try YWrite.insertAfter(tx, into: container, after: nil, [.type(table)])
            try YWrite.mapSet(tx, on: table, key: "textColor", .any([.string("default")]))
            let row = YType(typeRef: .xmlElement(nodeName: "tableRow"))
            _ = try YWrite.insertAfter(tx, into: table, after: nil, [.type(row)])
            let cell = YType(typeRef: .xmlElement(nodeName: "tableCell"))
            _ = try YWrite.insertAfter(tx, into: row, after: nil, [.type(cell)])
            for (k, v) in [
                ("backgroundColor", YAnyValue.string("default")), ("colspan", .int(1)), ("rowspan", .int(1)),
                ("textAlignment", .string("left")), ("textColor", .string("default")),
            ] {
                try YWrite.mapSet(tx, on: cell, key: k, .any([v]))
            }
            let para = YType(typeRef: .xmlElement(nodeName: "tableParagraph"))
            _ = try YWrite.insertAfter(tx, into: cell, after: nil, [.type(para)])
            let xmlText = YType(typeRef: .xmlText)
            _ = try YWrite.insertAfter(tx, into: para, after: nil, [.type(xmlText)])
            try xmlText.insert(0, "Cell", nil)
        }
        return try YStateEncoder.encodeStateAsUpdate(doc)
    }

    private func columnDoc() throws -> Data {
        let doc = YDoc(clientID: 1, gc: true)
        defer { doc.destroy() }
        let base = BlockNoteYjs.encode([paragraph("p1", "Top"), paragraph("p2", "Bottom")], clientID: 1)
        try doc.applyUpdate(YUpdateDecoder.decode(base))
        let root = try XCTUnwrap(doc.share[BlockNoteYjs.fragmentField])
        guard case .type(let group)? = YBlockProjection.children(of: root, includeFormats: false).first?.content else {
            XCTFail("missing root group")
            return base
        }
        try doc.transact { tx in
            let cl = YType(typeRef: .xmlElement(nodeName: "columnList"))
            _ = try YWrite.insertAfter(tx, into: group, after: nil, [.type(cl)])
            try YWrite.mapSet(tx, on: cl, key: "id", .any([.string("cl")]))
            var lastCol: YItem?
            for (colID, items) in [
                ("col-1", [("c1-a", "Alpha"), ("c1-b", "Beta"), ("c1-c", "Gamma")]),
                ("col-2", [("c2-a", "Other")]),
            ] {
                let col = YType(typeRef: .xmlElement(nodeName: "column"))
                lastCol = try YWrite.insertAfter(tx, into: cl, after: lastCol, [.type(col)])
                try YWrite.mapSet(tx, on: col, key: "id", .any([.string(colID)]))
                try YWrite.mapSet(tx, on: col, key: "width", .any([.int(1)]))
                var lastBlock: YItem?
                for (id, text) in items {
                    let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
                    lastBlock = try YWrite.insertAfter(tx, into: col, after: lastBlock, [.type(container)])
                    try YWrite.mapSet(tx, on: container, key: "id", .any([.string(id)]))
                    let para = YType(typeRef: .xmlElement(nodeName: "paragraph"))
                    _ = try YWrite.insertAfter(tx, into: container, after: nil, [.type(para)])
                    for (k, v) in Self.paragraphProps { try YWrite.mapSet(tx, on: para, key: k, .any([v])) }
                    let xmlText = YType(typeRef: .xmlText)
                    _ = try YWrite.insertAfter(tx, into: para, after: nil, [.type(xmlText)])
                    try xmlText.insert(0, text, nil)
                }
            }
        }
        return try YStateEncoder.encodeStateAsUpdate(doc)
    }

    private func blockCenterWindowPoint(
        in textView: NativeTextView, surface: NativeTextSurface, blockID: String
    ) throws -> CGPoint {
        let pos = try XCTUnwrap(surface.rangeIndex.position(for: blockID))
        let layout = try XCTUnwrap(textView.textLayoutManager)
        let content = try XCTUnwrap(layout.textContentManager)
        layout.textViewportLayoutController.layoutViewport()
        let rect = try XCTUnwrap(
            NativeDropLayoutHelper.fragmentFrame(
                forBlockAt: pos, entries: surface.rangeIndex.entries, contentManager: content,
                layoutManager: layout, docStart: content.documentRange.location))
        let local = CGPoint(x: textView.textContainerInset.left + 20, y: textView.textContainerInset.top + rect.midY)
        return textView.convert(local, to: nil)
    }

    // MARK: - Pure Slot & Depth Resolution

    func testSlotResolverMapsTouchYAndHorizontalOffsetToSnappedDepth() {
        let blocks = [
            snap("a", node: "bulletListItem"),
            snap("b", node: "paragraph"),
            snap("c", node: "paragraph"),
        ]
        let frames = [
            NativeVisibleBlockFrame(index: 0, frame: CGRect(x: 16, y: 16, width: 358, height: 24)),
            NativeVisibleBlockFrame(index: 1, frame: CGRect(x: 16, y: 48, width: 358, height: 24)),
            NativeVisibleBlockFrame(index: 2, frame: CGRect(x: 16, y: 80, width: 358, height: 24)),
        ]

        // Dragging "c" above "a" -> before "a" at depth 0, even if dragged right.
        let top = NativeBlockDragSlotResolver.resolve(
            draggedBlockID: "c", blocks: blocks, visibleFrames: frames,
            touchY: 20, horizontalOffset: 64, indentStep: 32)
        XCTAssertEqual(top?.dropTarget, NativeBlockDropTarget(destination: .before("a"), depth: 0))
        XCTAssertEqual(top?.indicatorY, 16)

        // Dragging "c" between "a" and "b" with no horizontal slide -> sibling after "a" at depth 0.
        let betweenFlat = NativeBlockDragSlotResolver.resolve(
            draggedBlockID: "c", blocks: blocks, visibleFrames: frames,
            touchY: 44, horizontalOffset: 8, indentStep: 32)
        XCTAssertEqual(betweenFlat?.dropTarget, NativeBlockDropTarget(destination: .after("a"), depth: 0))

        // Sliding right >= 1 step (+32 pt) nests "c" as firstChild of "a" at depth 1.
        let betweenNested = NativeBlockDragSlotResolver.resolve(
            draggedBlockID: "c", blocks: blocks, visibleFrames: frames,
            touchY: 44, horizontalOffset: 36, indentStep: 32)
        XCTAssertEqual(betweenNested?.dropTarget, NativeBlockDropTarget(destination: .firstChild(of: "a"), depth: 1))

        // Dragging "b" straight right in-place nests it under "a".
        let inPlaceNest = NativeBlockDragSlotResolver.resolve(
            draggedBlockID: "b", blocks: blocks, visibleFrames: frames,
            touchY: 60, horizontalOffset: 32, indentStep: 32)
        XCTAssertEqual(inPlaceNest?.dropTarget, NativeBlockDropTarget(destination: .firstChild(of: "a"), depth: 1))
        XCTAssertNotNil(inPlaceNest)
        if let inPlaceNest {
            XCTAssertGreaterThanOrEqual(inPlaceNest.indicatorY, 40)
            XCTAssertLessThan(inPlaceNest.indicatorY, 48)
        }

        // Dragging "b" straight without moving horizontally is a no-op -> nil.
        let noOp = NativeBlockDragSlotResolver.resolve(
            draggedBlockID: "b", blocks: blocks, visibleFrames: frames,
            touchY: 60, horizontalOffset: 0, indentStep: 32)
        XCTAssertNil(noOp)

        // RTL mirrors horizontal drag direction: sliding left (-32 pt) nests.
        let rtlNest = NativeBlockDragSlotResolver.resolve(
            draggedBlockID: "b", blocks: blocks, visibleFrames: frames,
            touchY: 60, horizontalOffset: -32, indentStep: 32, isRTL: true)
        XCTAssertEqual(rtlNest?.dropTarget, NativeBlockDropTarget(destination: .firstChild(of: "a"), depth: 1))
    }

    func testSlotResolverSkipsDraggedSubtreeFoldedChildrenAndClampsRootOnlyCards() {
        let blocks = [
            snap("t", node: "toggleListItem", depth: 0),
            snap("h1", node: "paragraph", depth: 1, parentID: "t"),
            snap("h2", node: "paragraph", depth: 1, parentID: "t"),
            snap("tbl", node: "table", depth: 0),
            snap("p", node: "paragraph", depth: 0),
        ]
        // Toggle "t" is collapsed: only indices 0, 3, 4 are visible.
        let hidden = [false, true, true, false, false]
        let frames = [
            NativeVisibleBlockFrame(index: 0, frame: CGRect(x: 16, y: 16, width: 358, height: 24)),
            NativeVisibleBlockFrame(index: 3, frame: CGRect(x: 16, y: 48, width: 358, height: 60)),
            NativeVisibleBlockFrame(index: 4, frame: CGRect(x: 16, y: 116, width: 358, height: 24)),
        ]

        // Dropping "p" right after collapsed toggle "t" while sliding right stays at depth 0 after "t".
        let afterFolded = NativeBlockDragSlotResolver.resolve(
            draggedBlockID: "p", blocks: blocks, expanded: [], hidden: hidden,
            visibleFrames: frames, touchY: 44, horizontalOffset: 64, indentStep: 32)
        XCTAssertEqual(afterFolded?.dropTarget, NativeBlockDropTarget(destination: .after("t"), depth: 0))

        // Dragging table "tbl" below "p" while sliding right stays clamped to depth 0.
        let tableAfterP = NativeBlockDragSlotResolver.resolve(
            draggedBlockID: "tbl", blocks: blocks, expanded: [], hidden: hidden,
            visibleFrames: frames, touchY: 140, horizontalOffset: 64, indentStep: 32)
        XCTAssertEqual(tableAfterP?.dropTarget, NativeBlockDropTarget(destination: .after("p"), depth: 0))
    }

    // MARK: - Pure Auto-Scroll Edge Detection

    func testAutoScrollVelocityRampsInEdgeZonesAndIsZeroInCenter() {
        let minY: CGFloat = 0
        let maxY: CGFloat = 600
        let threshold: CGFloat = 56

        // Center of viewport -> 0.
        XCTAssertEqual(
            NativeBlockDragAutoScroll.velocity(touchY: 300, visibleMinY: minY, visibleMaxY: maxY), 0)
        // Exactly on edge-zone boundaries -> 0.
        XCTAssertEqual(
            NativeBlockDragAutoScroll.velocity(touchY: threshold, visibleMinY: minY, visibleMaxY: maxY), 0)
        XCTAssertEqual(
            NativeBlockDragAutoScroll.velocity(touchY: maxY - threshold, visibleMinY: minY, visibleMaxY: maxY), 0)

        // Top zone scrolls upward (negative) and accelerates closer to the top edge.
        let topGentle = NativeBlockDragAutoScroll.velocity(touchY: 40, visibleMinY: minY, visibleMaxY: maxY)
        let topFast = NativeBlockDragAutoScroll.velocity(touchY: 4, visibleMinY: minY, visibleMaxY: maxY)
        XCTAssertLessThan(topGentle, 0)
        XCTAssertLessThan(topFast, topGentle)

        // Bottom zone scrolls downward (positive) and accelerates closer to the bottom edge.
        let bottomGentle = NativeBlockDragAutoScroll.velocity(touchY: 560, visibleMinY: minY, visibleMaxY: maxY)
        let bottomFast = NativeBlockDragAutoScroll.velocity(touchY: 596, visibleMinY: minY, visibleMaxY: maxY)
        XCTAssertGreaterThan(bottomGentle, 0)
        XCTAssertGreaterThan(bottomFast, bottomGentle)

        // Tiny viewport shrinks zones to height / 3 so the center stays quiet.
        XCTAssertEqual(
            NativeBlockDragAutoScroll.velocity(touchY: 45, visibleMinY: 0, visibleMaxY: 90), 0)
    }

    // MARK: - Pure Handle Visibility & Card Eligibility

    func testHandlePolicyRespectsEditabilityLockedOpaqueAndHoverPriority() {
        let blocks = [
            snap("normal", node: "paragraph"),
            snap("locked", node: "paragraph", isLocked: true),
            snap("opaque", node: "unknownBlock", isOpaque: true),
            snap("other", node: "paragraph"),
        ]

        // Editable + draggable caret block -> shows handle on caret block.
        XCTAssertEqual(
            NativeBlockDragHandlePolicy.targetBlockID(
                isEditable: true, canReorder: true, isDragging: false,
                hoveredBlockID: nil, caretBlockID: "normal", blocks: blocks),
            "normal")

        // Reading mode (not editable) or cannot reorder -> nil.
        XCTAssertNil(
            NativeBlockDragHandlePolicy.targetBlockID(
                isEditable: false, canReorder: true, isDragging: false,
                hoveredBlockID: nil, caretBlockID: "normal", blocks: blocks))
        XCTAssertNil(
            NativeBlockDragHandlePolicy.targetBlockID(
                isEditable: true, canReorder: false, isDragging: false,
                hoveredBlockID: nil, caretBlockID: "normal", blocks: blocks))

        // Locked or opaque caret block -> nil.
        XCTAssertNil(
            NativeBlockDragHandlePolicy.targetBlockID(
                isEditable: true, canReorder: true, isDragging: false,
                hoveredBlockID: nil, caretBlockID: "locked", blocks: blocks))
        XCTAssertNil(
            NativeBlockDragHandlePolicy.targetBlockID(
                isEditable: true, canReorder: true, isDragging: false,
                hoveredBlockID: nil, caretBlockID: "opaque", blocks: blocks))

        // Pointer hover takes precedence over caret; hovering locked/opaque hides handle.
        XCTAssertEqual(
            NativeBlockDragHandlePolicy.targetBlockID(
                isEditable: true, canReorder: true, isDragging: false,
                hoveredBlockID: "other", caretBlockID: "normal", blocks: blocks),
            "other")
        XCTAssertNil(
            NativeBlockDragHandlePolicy.targetBlockID(
                isEditable: true, canReorder: true, isDragging: false,
                hoveredBlockID: "locked", caretBlockID: "normal", blocks: blocks))

        // Active drag hides the handle.
        XCTAssertNil(
            NativeBlockDragHandlePolicy.targetBlockID(
                isEditable: true, canReorder: true, isDragging: true,
                hoveredBlockID: nil, caretBlockID: "normal", blocks: blocks))

        // Long-press card nodes vs prose nodes.
        for card in ["image", "file", "video", "audio", "pdf", "divider", "table", "columnList"] {
            XCTAssertTrue(NativeBlockDragHandlePolicy.isLongPressDraggableCard(node: card), card)
        }
        for prose in [
            "paragraph", "heading", "bulletListItem", "numberedListItem", "checkListItem", "quote", "codeBlock",
        ] {
            XCTAssertFalse(NativeBlockDragHandlePolicy.isLongPressDraggableCard(node: prose), prose)
        }
    }

    // MARK: - Pure VoiceOver Announcement Text

    func testAnnouncementTextCoversAllDestinationsAndSummaries() {
        let labels = NativeEditorLabels()
        let longText = String(repeating: "a", count: 60)
        let blocks = [
            snap("first", node: "paragraph", text: "Intro paragraph"),
            snap("emptyDiv", node: "divider", text: ""),
            snap("tbl", node: "table", text: "", preview: .table(cells: [["A"]], rowCount: 2, columnCount: 3)),
            snap("long", node: "paragraph", text: longText),
        ]

        XCTAssertEqual(
            NativeBlockDragAnnouncement.message(for: .before("first"), in: blocks, labels: labels),
            "Moved to top")
        XCTAssertEqual(
            NativeBlockDragAnnouncement.message(for: .before("emptyDiv"), in: blocks, labels: labels),
            "Moved before Divider")
        XCTAssertEqual(
            NativeBlockDragAnnouncement.message(for: .after("tbl"), in: blocks, labels: labels),
            "Moved after Table, 2 by 3")
        XCTAssertEqual(
            NativeBlockDragAnnouncement.message(for: .firstChild(of: "first"), in: blocks, labels: labels),
            "Moved inside Intro paragraph")

        let truncated = NativeBlockDragAnnouncement.message(for: .after("long"), in: blocks, labels: labels)
        XCTAssertTrue(truncated.hasPrefix("Moved after "))
        XCTAssertTrue(truncated.hasSuffix("…"))
        XCTAssertLessThan(truncated.count, 60)
    }

    // MARK: - Coordinator & Real NativeTextView Integration

    func testProgrammaticDragMovesBlockFiresHapticsPostsAnnouncementAndUndoesInOneStep() async throws {
        let harness = try await makeHarness([
            paragraph("p1", "First paragraph"),
            paragraph("p2", "Second paragraph"),
            paragraph("p3", "Third paragraph"),
        ])
        addTeardownBlock { await harness.close() }
        _ = mount(harness.session.textView)
        let drag = try XCTUnwrap(harness.session.textView.blockDragController)
        let spy = SpyDragHaptics()
        drag.haptics = spy
        var announcements: [String] = []
        drag.postAnnouncement = { announcements.append($0) }

        // Handle is shown beside the caret's block.
        setSelection(harness, NSRange(location: try location(harness.session, "p1", 0), length: 0))
        harness.session.textView.layoutIfNeeded()
        XCTAssertTrue(drag.isHandleVisible)
        XCTAssertEqual(drag.handleBlockID, "p1")

        let startPt = try blockCenterWindowPoint(
            in: harness.session.textView, surface: harness.session.surface, blockID: "p1")
        let targetPt = try blockCenterWindowPoint(
            in: harness.session.textView, surface: harness.session.surface, blockID: "p3")

        XCTAssertTrue(drag.beginDrag(blockID: "p1", atWindowPoint: startPt))
        XCTAssertTrue(drag.isDragging)
        XCTAssertFalse(drag.isHandleVisible, "handle hides while dragging")
        XCTAssertEqual(spy.lifts, 1)

        // Drag below p2 (to just above p3's midpoint -> after p2).
        let belowP2 = CGPoint(x: startPt.x, y: targetPt.y - 4)
        drag.updateDrag(atWindowPoint: belowP2)
        XCTAssertTrue(drag.isDropLineVisible)
        XCTAssertEqual(drag.currentCandidate?.dropTarget, NativeBlockDropTarget(destination: .after("p2"), depth: 0))
        XCTAssertGreaterThanOrEqual(spy.selectionTicks, 1)

        XCTAssertTrue(drag.endDrag())
        await harness.settle()

        XCTAssertEqual(harness.session.surface.blocks.map(\.id), ["p2", "p1", "p3"])
        XCTAssertEqual(spy.drops, 1)
        XCTAssertEqual(announcements, ["Moved after Second paragraph"])
        XCTAssertFalse(drag.isDragging)
        XCTAssertFalse(drag.isDropLineVisible)

        // One undo restores original order.
        XCTAssertTrue(harness.input.undo())
        await harness.settle()
        XCTAssertEqual(harness.session.surface.blocks.map(\.id), ["p1", "p2", "p3"])
    }

    func testHorizontalSlideRightNestsUnderListItemAndCancelRestoresWithoutMoving() async throws {
        let harness = try await makeHarness([
            bullet("b1", "Parent bullet"),
            paragraph("p1", "Child candidate"),
            paragraph("p2", "Trailing"),
        ])
        addTeardownBlock { await harness.close() }
        _ = mount(harness.session.textView)
        let drag = try XCTUnwrap(harness.session.textView.blockDragController)

        let p1Pt = try blockCenterWindowPoint(
            in: harness.session.textView, surface: harness.session.surface, blockID: "p1")

        // First test cancel: drag right then cancel -> no Yjs mutation.
        let revisionBefore = harness.session.revision
        XCTAssertTrue(drag.beginDrag(blockID: "p1", atWindowPoint: p1Pt))
        drag.updateDrag(atWindowPoint: CGPoint(x: p1Pt.x + 48, y: p1Pt.y))
        XCTAssertEqual(
            drag.currentCandidate?.dropTarget,
            NativeBlockDropTarget(destination: .firstChild(of: "b1"), depth: 1))
        drag.cancelDrag()
        await harness.settle()
        XCTAssertEqual(harness.session.revision, revisionBefore)
        XCTAssertEqual(harness.session.surface.blocks.map(\.depth), [0, 0, 0])

        // Now commit the horizontal slide right -> nests under b1 at depth 1.
        XCTAssertTrue(drag.beginDrag(blockID: "p1", atWindowPoint: p1Pt))
        drag.updateDrag(atWindowPoint: CGPoint(x: p1Pt.x + 48, y: p1Pt.y))
        XCTAssertTrue(drag.endDrag())
        await harness.settle()
        XCTAssertEqual(harness.session.surface.blocks.map(\.id), ["b1", "p1", "p2"])
        XCTAssertEqual(harness.session.surface.blocks.map(\.depth), [0, 1, 0])
    }

    func testLockedBlockShowsNoHandleAndRefusesDrag() async throws {
        let lockedBlock = BlockNoteBlock(
            node: "paragraph",
            props: Self.paragraphProps + [("futureProp", .string("keep"))],
            runs: [InlineRun("Locked block")],
            id: "locked-1")
        let harness = try await makeHarness([paragraph("p1", "Editable"), lockedBlock])
        addTeardownBlock { await harness.close() }
        _ = mount(harness.session.textView)
        let drag = try XCTUnwrap(harness.session.textView.blockDragController)

        setSelection(harness, NSRange(location: try location(harness.session, "locked-1", 0), length: 0))
        harness.session.textView.layoutIfNeeded()
        XCTAssertFalse(drag.isHandleVisible, "locked block must show no handle")
        XCTAssertFalse(drag.beginDrag(blockID: "locked-1", atWindowPoint: CGPoint(x: 40, y: 40)))

        // Moving caret to editable block reveals handle; turning off editing hides it.
        setSelection(harness, NSRange(location: try location(harness.session, "p1", 0), length: 0))
        harness.session.textView.layoutIfNeeded()
        XCTAssertTrue(drag.isHandleVisible)
        harness.session.textView.isEditable = false
        XCTAssertFalse(drag.isHandleVisible)
    }

    func testHoverMovesHandleOnIPadAndClearsBackToCaretBlock() async throws {
        let harness = try await makeHarness([
            paragraph("p1", "First"),
            paragraph("p2", "Second"),
        ])
        addTeardownBlock { await harness.close() }
        _ = mount(harness.session.textView)
        let drag = try XCTUnwrap(harness.session.textView.blockDragController)

        setSelection(harness, NSRange(location: try location(harness.session, "p1", 0), length: 0))
        harness.session.textView.layoutIfNeeded()
        XCTAssertEqual(drag.handleBlockID, "p1")

        let p2Window = try blockCenterWindowPoint(
            in: harness.session.textView, surface: harness.session.surface, blockID: "p2")
        let p2Local = harness.session.textView.convert(p2Window, from: nil)
        drag.handleHover(at: p2Local)
        XCTAssertEqual(drag.handleBlockID, "p2")
        XCTAssertTrue(drag.isHandleVisible)

        drag.clearHover()
        XCTAssertEqual(drag.handleBlockID, "p1")
    }

    func testFoldedToggleMovesIntactWithItsChildren() async throws {
        let harness = try await makeHarness([
            toggle("t1", "Section", children: [paragraph("c1", "Hidden child")]),
            paragraph("p1", "Below"),
        ])
        addTeardownBlock { await harness.close() }
        _ = mount(harness.session.textView)
        let drag = try XCTUnwrap(harness.session.textView.blockDragController)
        XCTAssertFalse(harness.session.surface.isExpanded("t1"))

        let t1Pt = try blockCenterWindowPoint(
            in: harness.session.textView, surface: harness.session.surface, blockID: "t1")
        let p1Pt = try blockCenterWindowPoint(
            in: harness.session.textView, surface: harness.session.surface, blockID: "p1")

        XCTAssertTrue(drag.beginDrag(blockID: "t1", atWindowPoint: t1Pt))
        drag.updateDrag(atWindowPoint: CGPoint(x: t1Pt.x, y: p1Pt.y + 24))
        XCTAssertEqual(drag.currentCandidate?.dropTarget, NativeBlockDropTarget(destination: .after("p1"), depth: 0))
        XCTAssertTrue(drag.endDrag())
        await harness.settle()

        XCTAssertEqual(harness.session.surface.blocks.map(\.id), ["p1", "t1", "c1"])
        XCTAssertEqual(harness.session.surface.blocks.map(\.depth), [0, 0, 1])
    }

    func testTableStaysTopLevelAndColumnInnerSurfaceReordersWithinColumn() async throws {
        // 1) Table card stays at depth 0 even when dragged sideways.
        let tableHarness = try await makeHarness(state: try tableDoc())
        addTeardownBlock { await tableHarness.close() }
        _ = mount(tableHarness.session.textView)
        let tableDrag = try XCTUnwrap(tableHarness.session.textView.blockDragController)
        let tblPt = try blockCenterWindowPoint(
            in: tableHarness.session.textView, surface: tableHarness.session.surface, blockID: "tbl")
        let p2Pt = try blockCenterWindowPoint(
            in: tableHarness.session.textView, surface: tableHarness.session.surface, blockID: "p2")
        XCTAssertTrue(tableDrag.beginDrag(blockID: "tbl", atWindowPoint: tblPt))
        tableDrag.updateDrag(atWindowPoint: CGPoint(x: tblPt.x + 80, y: p2Pt.y + 20))
        XCTAssertEqual(
            tableDrag.currentCandidate?.dropTarget,
            NativeBlockDropTarget(destination: .after("p2"), depth: 0))
        XCTAssertTrue(tableDrag.endDrag())
        await tableHarness.settle()
        XCTAssertEqual(tableHarness.session.surface.blocks.map(\.id), ["p1", "p2", "tbl"])
        XCTAssertEqual(tableHarness.session.surface.blocks.map(\.depth), [0, 0, 0])

        // 2) Column group moves before/after in root AND inner column surface reorders within its own column.
        let colHarness = try await makeHarness(state: try columnDoc())
        addTeardownBlock { await colHarness.close() }
        _ = mount(colHarness.session.textView)
        let colSession = try unwrapped(
            await colHarness.session.openColumn(group: "cl", column: "col-1"), "column opens")
        addTeardownBlock { await colSession.close().value }
        _ = mount(colSession.textView)
        let innerDrag = try XCTUnwrap(colSession.textView.blockDragController)
        let aPt = try blockCenterWindowPoint(in: colSession.textView, surface: colSession.surface, blockID: "c1-a")
        let cPt = try blockCenterWindowPoint(in: colSession.textView, surface: colSession.surface, blockID: "c1-c")
        XCTAssertTrue(innerDrag.beginDrag(blockID: "c1-a", atWindowPoint: aPt))
        innerDrag.updateDrag(atWindowPoint: CGPoint(x: aPt.x, y: cPt.y + 20))
        XCTAssertTrue(innerDrag.endDrag())
        let settled = await colSession.settle()
        XCTAssertTrue(settled)
        XCTAssertEqual(colSession.surface.blocks.map(\.id), ["c1-b", "c1-c", "c1-a"])
    }
}

@MainActor
private final class SpyDragHaptics: NativeBlockDragHaptics {
    var prepares = 0
    var lifts = 0
    var selectionTicks = 0
    var drops = 0

    func prepare() { prepares += 1 }
    func lift() { lifts += 1 }
    func targetChanged() { selectionTicks += 1 }
    func drop() { drops += 1 }
}
