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

    // MARK: - Round 1 Review Regression Coverage

    /// Finding #1 & #10: a peer edit mid-drag re-resolves the target and drop line
    /// when the dragged block survives, and cancels when the dragged block is removed.
    func testPeerSurfaceChangeMidDragReResolvesTargetAndCancelsWhenDraggedBlockRemoved() async throws {
        let initialBlocks = [
            paragraph("p1", "First"),
            paragraph("p2", "Second"),
            paragraph("p3", "Third"),
            paragraph("p4", "Fourth"),
        ]
        let state = BlockNoteYjs.encode(initialBlocks, clientID: 1)
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }
        _ = mount(harness.session.textView)
        let drag = try XCTUnwrap(harness.session.textView.blockDragController)

        let p1Pt = try blockCenterWindowPoint(
            in: harness.session.textView, surface: harness.session.surface, blockID: "p1")
        let p3Pt = try blockCenterWindowPoint(
            in: harness.session.textView, surface: harness.session.surface, blockID: "p3")

        XCTAssertTrue(drag.beginDrag(blockID: "p1", atWindowPoint: p1Pt))
        drag.updateDrag(atWindowPoint: CGPoint(x: p1Pt.x, y: p3Pt.y - 4))
        XCTAssertEqual(drag.currentCandidate?.dropTarget, NativeBlockDropTarget(destination: .after("p2"), depth: 0))

        // Peer deletes `p2` while the user's finger holds steady mid-drag.
        let peer = YDoc(clientID: 2, gc: true)
        defer { peer.destroy() }
        try peer.applyUpdate(YUpdateDecoder.decode(state))
        let writer = BlockNoteWriter(doc: peer, schemas: BlockNoteWriter.nativePropSchemas)
        let removeP2 = try writer.deleteBlock(try writer.find("p2").item, id: "p2")
        try await harness.session.integrateServerState(removeP2)
        await harness.settle()

        XCTAssertTrue(drag.isDragging, "drag survives when another block changes")
        XCTAssertNotEqual(
            drag.currentCandidate?.dropTarget.destination, .after("p2"),
            "candidate must re-resolve instead of pointing to deleted p2")
        XCTAssertEqual(drag.currentCandidate?.dropTarget, NativeBlockDropTarget(destination: .after("p3"), depth: 0))

        // Peer deletes the dragged block `p1` itself -> drag cancels cleanly.
        let removeP1 = try writer.deleteBlock(try writer.find("p1").item, id: "p1")
        try await harness.session.integrateServerState(removeP1)
        await harness.settle()
        XCTAssertFalse(drag.isDragging)
        XCTAssertFalse(drag.isDropLineVisible)
    }

    /// Finding #2: scrolling the caret block off-screen hides the handle view
    /// without clearing `handleBlockID`, so scrolling back restores it without a
    /// new selection change.
    func testHandleSurvivesScrollingOffScreenAndBackWithoutSelectionChange() async throws {
        let blocks = (0..<60).map { paragraph("p\($0)", "Paragraph number \($0) with enough text.") }
        let harness = try await makeHarness(blocks)
        addTeardownBlock { await harness.close() }
        _ = mount(harness.session.textView, size: CGSize(width: 390, height: 320))
        let view = harness.session.textView
        let drag = try XCTUnwrap(view.blockDragController)

        setSelection(harness, NSRange(location: try location(harness.session, "p0", 0), length: 0))
        view.layoutIfNeeded()
        XCTAssertTrue(drag.isHandleVisible)
        XCTAssertEqual(drag.handleBlockID, "p0")

        // Scroll far below so p0 leaves the TextKit 2 viewport.
        let maxY = max(0, view.contentSize.height - view.bounds.height)
        XCTAssertGreaterThan(maxY, 300)
        view.contentOffset.y = maxY
        view.setNeedsLayout()
        view.layoutIfNeeded()
        XCTAssertEqual(drag.handleBlockID, "p0", "handleBlockID stays retained when fragment leaves viewport")

        // Scroll back to top without touching selection -> handle reappears.
        view.contentOffset.y = 0
        view.setNeedsLayout()
        view.layoutIfNeeded()
        XCTAssertEqual(drag.handleBlockID, "p0")
        XCTAssertTrue(drag.isHandleVisible, "handle must reappear on layout when caret block scrolls back in")
    }

    /// Finding #3: drop haptic and VoiceOver announcement wait for `applyStructural`'s
    /// `onSettled(true)` and do NOT fire when the engine refuses the move.
    func testDropHapticAndAnnouncementWaitForSettleAndSkipOnEngineRefusal() async throws {
        let initialBlocks = [
            paragraph("p1", "First"),
            paragraph("p2", "Second"),
            paragraph("p3", "Third"),
        ]
        let state = BlockNoteYjs.encode(initialBlocks, clientID: 1)
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }
        _ = mount(harness.session.textView)
        let drag = try XCTUnwrap(harness.session.textView.blockDragController)
        let spy = SpyDragHaptics()
        drag.haptics = spy
        var announcements: [String] = []
        drag.postAnnouncement = { announcements.append($0) }

        let p1Pt = try blockCenterWindowPoint(
            in: harness.session.textView, surface: harness.session.surface, blockID: "p1")
        let p3Pt = try blockCenterWindowPoint(
            in: harness.session.textView, surface: harness.session.surface, blockID: "p3")

        XCTAssertTrue(drag.beginDrag(blockID: "p1", atWindowPoint: p1Pt))
        drag.updateDrag(atWindowPoint: CGPoint(x: p1Pt.x, y: p3Pt.y - 4))
        XCTAssertEqual(drag.currentCandidate?.dropTarget, NativeBlockDropTarget(destination: .after("p2"), depth: 0))

        // Before the replica settles, neither drop haptic nor announcement has fired.
        XCTAssertTrue(drag.endDrag())
        XCTAssertEqual(spy.drops, 0, "drop haptic must wait for onSettled(true)")
        XCTAssertTrue(announcements.isEmpty, "VoiceOver announcement must wait for onSettled(true)")
        await harness.settle()
        XCTAssertEqual(spy.drops, 1)
        XCTAssertEqual(announcements, ["Moved after Second"])

        // Now force an engine-side refusal: lock `p1` directly on the replica so the
        // surface still thinks `p1` is draggable, then drop -> engine refuses -> no haptic/announcement.
        spy.drops = 0
        announcements = []
        let p1Now = try blockCenterWindowPoint(
            in: harness.session.textView, surface: harness.session.surface, blockID: "p1")
        let p2Now = try blockCenterWindowPoint(
            in: harness.session.textView, surface: harness.session.surface, blockID: "p2")
        XCTAssertTrue(drag.beginDrag(blockID: "p1", atWindowPoint: p1Now))
        drag.updateDrag(atWindowPoint: CGPoint(x: p1Now.x, y: p2Now.y - 10))
        XCTAssertEqual(drag.currentCandidate?.dropTarget, NativeBlockDropTarget(destination: .before("p2"), depth: 0))

        // Delete `p2` on the replica while surface hasn't yet received a patch, or
        // lock `p1` via replica doc mutation inside a no-patch inspect: lock `p1`
        // by setting an unknown prop via `DocumentEngine`? Even simpler: submit an
        // invalid move via a peer update queued right ahead of our move on a paused mailbox!
        // Here we lock `p1` directly on the replica so `DocumentEngine.prepareBlockCommand` refuses it.
        _ = await harness.session.replicaDoc { doc in
            if let element = try? BlockNoteWriter(doc: doc, schemas: BlockNoteWriter.nativePropSchemas).find("p1")
                .element
            {
                try? doc.transact(origin: .remote) { tx in
                    try YWrite.mapSet(tx, on: element, key: "unknownLockProp", .any([.string("locked")]))
                }
            }
        }
        // Surface hasn't seen `.unknownLockProp` yet (it's still in-flight or refused by engine).
        _ = drag.endDrag()
        await harness.settle()
        XCTAssertEqual(spy.drops, 0, "refused move must not fire drop haptic")
        XCTAssertTrue(announcements.isEmpty, "refused move must not post VoiceOver announcement")
    }

    /// Finding #4: `showSourceDim` unions only laid-out viewport fragments in the
    /// dragged subtree, never `.zero` frames that stretch the dim up to y=0.
    func testSourceDimUsesOnlyLaidOutSubtreeFragmentsWithoutStretchingToTop() async throws {
        var blocks: [BlockNoteBlock] = (0..<25).map { paragraph("top-\($0)", "Top paragraph \($0)") }
        var parent = paragraph("parent", "Parent with many children")
        parent.children = (0..<40).map { paragraph("child-\($0)", "Nested child paragraph \($0)") }
        blocks.append(parent)
        blocks.append(paragraph("tail", "Tail"))

        let harness = try await makeHarness(blocks)
        addTeardownBlock { await harness.close() }
        _ = mount(harness.session.textView, size: CGSize(width: 390, height: 240))
        let view = harness.session.textView
        let drag = try XCTUnwrap(view.blockDragController)

        // Scroll so `parent` sits mid-viewport with many blocks above it and many children below.
        let parentPos = try XCTUnwrap(harness.session.surface.rangeIndex.position(for: "parent"))
        let layout = try XCTUnwrap(view.textLayoutManager)
        let content = try XCTUnwrap(layout.textContentManager)
        let parentLoc = try XCTUnwrap(
            content.location(
                content.documentRange.location,
                offsetBy: harness.session.surface.rangeIndex.entries[parentPos].range.location))
        let relocatedY = layout.textViewportLayoutController.relocateViewport(to: parentLoc)
        view.contentOffset.y = max(0, relocatedY - 80)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        layout.textViewportLayoutController.layoutViewport()

        let parentRect = try XCTUnwrap(
            NativeDropLayoutHelper.fragmentFrame(
                forBlockAt: parentPos, entries: harness.session.surface.rangeIndex.entries, contentManager: content,
                layoutManager: layout, docStart: content.documentRange.location))
        let expectedMinY = view.textContainerInset.top + parentRect.minY
        XCTAssertGreaterThan(expectedMinY, 200, "parent should sit far below document y=0")

        let parentPt = try blockCenterWindowPoint(in: view, surface: harness.session.surface, blockID: "parent")
        XCTAssertTrue(drag.beginDrag(blockID: "parent", atWindowPoint: parentPt))
        let dimFrame = try XCTUnwrap(drag.sourceDimFrame)
        XCTAssertEqual(
            dimFrame.minY, expectedMinY, accuracy: 2.0,
            "dim must start at parent's laid-out minY, not stretch to y=0 from un-laid-out children")
        drag.cancelDrag()
    }

    /// Finding #5: `handleView` stays in `orderAuxiliarySubviews`'s reading order
    /// (before the footer) and does not thrash subviews across repeated layout passes.
    func testHandleStaysInReadingOrderBeforeFooterAcrossLayoutPasses() async throws {
        let harness = try await makeHarness([paragraph("p1", "First"), paragraph("p2", "Second")])
        addTeardownBlock { await harness.close() }
        let view = harness.session.textView
        let footer = UIView(frame: CGRect(x: 0, y: 400, width: 390, height: 60))
        view.addSubview(footer)
        view.footerAccessoryView = footer
        _ = mount(view)

        let drag = try XCTUnwrap(view.blockDragController)
        setSelection(harness, NSRange(location: try location(harness.session, "p1", 0), length: 0))
        view.setNeedsLayout()
        view.layoutIfNeeded()

        XCTAssertTrue(drag.isHandleVisible)
        let handleIdx = try XCTUnwrap(view.subviews.firstIndex { $0 === drag.handleView })
        let footerIdx = try XCTUnwrap(view.subviews.firstIndex { $0 === footer })
        XCTAssertLessThan(handleIdx, footerIdx, "drag handle must sit before footer in VoiceOver reading order")
        XCTAssertGreaterThan(drag.handleView.layer.zPosition, 0, "zPosition keeps handle visually above text")

        let orderBefore = view.subviews.map(ObjectIdentifier.init)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        XCTAssertEqual(view.subviews.map(ObjectIdentifier.init), orderBefore, "subview order must stay stable")
    }

    /// Finding #6: a bounds size change cancels an active drag; a content shift
    /// at unchanged size re-resolves the drop target and drop line.
    func testLayoutSizeChangeCancelsDragAndContentShiftReResolvesTarget() async throws {
        let blocks = (0..<20).map { paragraph("p\($0)", "Paragraph \($0)") }
        let harness = try await makeHarness(blocks)
        addTeardownBlock { await harness.close() }
        let window = mount(harness.session.textView, size: CGSize(width: 390, height: 400))
        let view = harness.session.textView
        let drag = try XCTUnwrap(view.blockDragController)

        // 1) Content shift (scroll / geometry shift without bounds size change) re-resolves target.
        let p0Pt = try blockCenterWindowPoint(in: view, surface: harness.session.surface, blockID: "p0")
        let p2Pt = try blockCenterWindowPoint(in: view, surface: harness.session.surface, blockID: "p2")
        XCTAssertTrue(drag.beginDrag(blockID: "p0", atWindowPoint: p0Pt))
        drag.updateDrag(atWindowPoint: CGPoint(x: p0Pt.x, y: p2Pt.y - 4))
        let beforeTarget = drag.currentCandidate?.dropTarget
        XCTAssertEqual(beforeTarget, NativeBlockDropTarget(destination: .after("p1"), depth: 0))

        view.contentOffset.y = 140
        view.setNeedsLayout()
        view.layoutIfNeeded()
        XCTAssertTrue(drag.isDragging, "content shift at unchanged size keeps drag active")
        XCTAssertNotEqual(
            drag.currentCandidate?.dropTarget, beforeTarget,
            "content shift must re-resolve target against new geometry")

        // 2) Bounds size change (rotation / Split View) cancels the drag.
        view.frame = CGRect(x: 0, y: 0, width: 320, height: window.bounds.height)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        XCTAssertFalse(drag.isDragging, "bounds size change must cancel active drag")
        XCTAssertFalse(drag.isDropLineVisible)
    }

    /// Finding #7 & #10: auto-scroll advances `contentOffset.y`, re-resolves the drop
    /// target on a long document, and inside a stacked `ColumnTextContainer` lays out
    /// before resolving and clamps strictly to the active column's region.
    func testAutoScrollAdvancesOffsetReResolvesTargetAndClampsInsideColumnContainer() async throws {
        // Part A: standalone long NativeTextView auto-scrolls and updates drop target.
        let longBlocks = (0..<40).map { paragraph("p\($0)", "Scrollable paragraph \($0)") }
        let harness = try await makeHarness(longBlocks)
        addTeardownBlock { await harness.close() }
        let window = mount(harness.session.textView, size: CGSize(width: 390, height: 320))
        let view = harness.session.textView
        let drag = try XCTUnwrap(view.blockDragController)

        let p0Pt = try blockCenterWindowPoint(in: view, surface: harness.session.surface, blockID: "p0")
        XCTAssertTrue(drag.beginDrag(blockID: "p0", atWindowPoint: p0Pt))
        // Move finger into bottom 56 pt edge zone.
        let bottomEdgePt = CGPoint(x: p0Pt.x, y: window.bounds.maxY - 8)
        drag.updateDrag(atWindowPoint: bottomEdgePt)
        let targetBeforeScroll = drag.currentCandidate?.dropTarget
        let offsetBefore = view.contentOffset.y

        for _ in 0..<8 {
            XCTAssertTrue(drag.performAutoScrollStep(dt: 1.0 / 30.0))
        }
        XCTAssertGreaterThan(view.contentOffset.y, offsetBefore + 40, "auto-scroll must advance offset")
        XCTAssertNotEqual(
            drag.currentCandidate?.dropTarget, targetBeforeScroll,
            "auto-scroll must re-resolve drop target each frame")
        drag.cancelDrag()

        // Part B: stacked ColumnTextContainer lays out active column and clamps to col-1's region.
        let doc = YDoc(clientID: 1, gc: true)
        defer { doc.destroy() }
        let base = BlockNoteYjs.encode([paragraph("root", "Root")], clientID: 1)
        try doc.applyUpdate(YUpdateDecoder.decode(base))
        let root = try XCTUnwrap(doc.share[BlockNoteYjs.fragmentField])
        guard case .type(let group)? = YBlockProjection.children(of: root, includeFormats: false).first?.content else {
            return XCTFail("missing root group")
        }
        try doc.transact { tx in
            let cl = YType(typeRef: .xmlElement(nodeName: "columnList"))
            _ = try YWrite.insertAfter(tx, into: group, after: nil, [.type(cl)])
            try YWrite.mapSet(tx, on: cl, key: "id", .any([.string("cl")]))
            var lastCol: YItem?
            for colID in ["col-1", "col-2"] {
                let col = YType(typeRef: .xmlElement(nodeName: "column"))
                lastCol = try YWrite.insertAfter(tx, into: cl, after: lastCol, [.type(col)])
                try YWrite.mapSet(tx, on: col, key: "id", .any([.string(colID)]))
                try YWrite.mapSet(tx, on: col, key: "width", .any([.int(1)]))
                var lastBlock: YItem?
                for idx in 0..<25 {
                    let c = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
                    lastBlock = try YWrite.insertAfter(tx, into: col, after: lastBlock, [.type(c)])
                    try YWrite.mapSet(tx, on: c, key: "id", .any([.string("\(colID)-\(idx)")]))
                    let p = YType(typeRef: .xmlElement(nodeName: "paragraph"))
                    _ = try YWrite.insertAfter(tx, into: c, after: nil, [.type(p)])
                    for (k, v) in Self.paragraphProps { try YWrite.mapSet(tx, on: p, key: k, .any([v])) }
                    let t = YType(typeRef: .xmlText)
                    _ = try YWrite.insertAfter(tx, into: p, after: nil, [.type(t)])
                    try t.insert(0, "\(colID) line \(idx)", nil)
                }
            }
        }
        let colState = try YStateEncoder.encodeStateAsUpdate(doc)
        let colHarness = try await makeHarness(state: colState)
        addTeardownBlock { await colHarness.close() }
        let col1 = try unwrapped(await colHarness.session.openColumn(group: "cl", column: "col-1"))
        let col2 = try unwrapped(await colHarness.session.openColumn(group: "cl", column: "col-2"))
        addTeardownBlock {
            await col1.close().value
            await col2.close().value
        }

        let colWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 320))
        let container = ColumnTextContainer(frame: colWindow.bounds)
        colWindow.addSubview(container)
        colWindow.isHidden = false
        windows.append(colWindow)
        container.show([col1.textView, col2.textView], widths: [1, 1], active: 0)
        container.layoutIfNeeded()
        // Trigger a second pass once TextKit measures content heights.
        col1.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        col2.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        container.setNeedsLayout()
        container.layoutIfNeeded()

        let col1Bounds = try XCTUnwrap(container.scrollBounds(for: col1.textView))
        XCTAssertLessThan(
            col1Bounds.upperBound, container.contentSize.height - container.bounds.height - 50,
            "col-1 bounds must stop well before col-2's bottom")

        let colDrag = try XCTUnwrap(col1.textView.blockDragController)
        let startColPt = try blockCenterWindowPoint(in: col1.textView, surface: col1.surface, blockID: "col-1-0")
        XCTAssertTrue(colDrag.beginDrag(blockID: "col-1-0", atWindowPoint: startColPt))
        colDrag.updateDrag(atWindowPoint: CGPoint(x: startColPt.x, y: colWindow.bounds.maxY - 6))
        let initialCol1Offset = col1.textView.contentOffset.y

        // Step once: container lays out col1 immediately so col1.textView.contentOffset tracks it.
        XCTAssertTrue(colDrag.performAutoScrollStep(dt: 1.0 / 30.0))
        XCTAssertGreaterThan(
            col1.textView.contentOffset.y, initialCol1Offset,
            "ColumnTextContainer must lay out col-1 immediately during auto-scroll")

        // Step many times: must clamp at col-1's region and never scroll into col-2.
        for _ in 0..<80 {
            _ = colDrag.performAutoScrollStep(dt: 1.0 / 20.0)
        }
        XCTAssertLessThanOrEqual(
            container.contentOffset.y, col1Bounds.upperBound + 0.5,
            "auto-scroll in col-1 must clamp to col-1's region, never spilling into col-2")
        colDrag.cancelDrag()
    }

    /// Finding #8: `willResignActive` cancels an active drag, hiding the handle resets
    /// pointer-hover highlight, and RTL uses `textContainerInset.right` as leading inset.
    func testResignActiveCancelsDragHoverResetsOnHideAndRTLUsesTrailingInset() async throws {
        let harness = try await makeHarness([paragraph("p1", "First"), paragraph("p2", "Second")])
        addTeardownBlock { await harness.close() }
        let view = harness.session.textView
        _ = mount(view)
        let drag = try XCTUnwrap(view.blockDragController)

        // 1) willResignActive cancels an active drag.
        let p1Pt = try blockCenterWindowPoint(in: view, surface: harness.session.surface, blockID: "p1")
        XCTAssertTrue(drag.beginDrag(blockID: "p1", atWindowPoint: p1Pt))
        XCTAssertTrue(drag.isDragging)
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertFalse(drag.isDragging, "willResignActive must cancel an active drag")

        // 2) Pointer hover highlight resets when handle hides.
        setSelection(harness, NSRange(location: try location(harness.session, "p1", 0), length: 0))
        view.layoutIfNeeded()
        drag.handleView.setPointerHoveringForTesting(true)
        XCTAssertTrue(drag.handleView.isShowingHighlightChrome)
        view.isEditable = false
        XCTAssertFalse(drag.handleView.isShowingHighlightChrome, "hover highlight must clear when hidden")
        view.isEditable = true
        view.layoutIfNeeded()
        XCTAssertFalse(drag.handleView.isShowingHighlightChrome, "hover highlight must stay cleared on re-show")

        // 3) RTL uses textContainerInset.right as leading inset (not .left).
        view.semanticContentAttribute = .forceRightToLeft
        view.textContainerInset = UIEdgeInsets(top: 16, left: 10, bottom: 16, right: 32)
        view.layoutIfNeeded()
        drag.layoutHandle()
        let expectedRTLX = min(
            view.bounds.width - NativeBlockDragMetrics.handleWidth,
            view.bounds.width - view.textContainerInset.right)
        XCTAssertEqual(drag.handleView.frame.minX, round(expectedRTLX), accuracy: 1.0)

        let line = NativeDropLayoutHelper.makeDropLineView()
        NativeDropLayoutHelper.layoutDropLine(line, indicatorY: 40, depth: 0, in: view)
        XCTAssertEqual(line.frame.maxX, view.bounds.width - 32, accuracy: 1.0, "RTL drop line starts at right inset")
        XCTAssertEqual(line.frame.minX, 10, accuracy: 1.0, "RTL drop line ends at left inset")
    }

    /// Finding #9: handle keeps 22 pt visual width with a 44×44 hit target, preview
    /// height grows without a 76 pt cap at AX Dynamic Type, grip icon scales, and
    /// shadow uses a design-system token instead of raw `UIColor.black`.
    func testDesignSystemHandleHitTarget44x44DynamicTypePreviewHeightScaledGripAndTokenShadow() async throws {
        let harness = try await makeHarness([
            paragraph("p1", "A moderately long paragraph that wraps cleanly onto two lines at large sizes")
        ])
        addTeardownBlock { await harness.close() }
        let view = harness.session.textView
        _ = mount(view)
        let drag = try XCTUnwrap(view.blockDragController)

        // Handle visual width is 22 pt, hit target expands to 44×44 pt.
        setSelection(harness, NSRange(location: try location(harness.session, "p1", 0), length: 0))
        view.layoutIfNeeded()
        XCTAssertEqual(drag.handleView.bounds.size, CGSize(width: 22, height: 44))
        XCTAssertTrue(drag.handleView.point(inside: CGPoint(x: -10, y: 22), with: nil))
        XCTAssertTrue(drag.handleView.point(inside: CGPoint(x: 32, y: 22), with: nil))
        XCTAssertFalse(drag.handleView.point(inside: CGPoint(x: -13, y: 22), with: nil))
        XCTAssertFalse(drag.handleView.point(inside: CGPoint(x: 35, y: 22), with: nil))

        // Preview grows past 76 pt and scales its grip icon at Accessibility Extra Extra Extra Large.
        let largeControls = NativeBlockControls(textView: view)
        view.traitOverrides.preferredContentSizeCategory = .large
        view.updateTraitsIfNeeded()
        let defaultPreview = NativeBlockDragPreviewView(
            block: harness.session.surface.blocks[0], childCount: 2, controls: largeControls, maxWidth: 320)

        view.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        view.updateTraitsIfNeeded()
        let axPreview = NativeBlockDragPreviewView(
            block: harness.session.surface.blocks[0], childCount: 2, controls: largeControls, maxWidth: 320)

        XCTAssertGreaterThan(axPreview.frame.height, 76, "AX Dynamic Type preview must not clip at 76 pt")
        XCTAssertGreaterThan(axPreview.gripPointSize, defaultPreview.gripPointSize, "preview grip icon must scale")

        let expectedShadow = largeControls.color(\.surfaceScrim).withAlphaComponent(1).cgColor
        XCTAssertEqual(axPreview.layer.shadowColor, expectedShadow, "shadow must come from surfaceScrim token")
    }

    /// Finding #10: card long-press path accepts attachment cards and dividers while
    /// refusing prose blocks so text selection is never contested.
    func testCardLongPressAcceptsCardsAndDividerAndRejectsProse() async throws {
        let doc = YDoc(clientID: 1, gc: true)
        defer { doc.destroy() }
        let base = BlockNoteYjs.encode(
            [
                paragraph("p1", "Plain prose paragraph"),
                BlockNoteBlock(node: "divider", props: [], runs: [], id: "div1"),
            ], clientID: 1)
        try doc.applyUpdate(YUpdateDecoder.decode(base))
        let root = try XCTUnwrap(doc.share[BlockNoteYjs.fragmentField])
        guard case .type(let group)? = YBlockProjection.children(of: root, includeFormats: false).first?.content else {
            return XCTFail("missing root group")
        }
        try doc.transact { tx in
            let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            let last = YBlockProjection.children(of: group, includeFormats: false).last
            _ = try YWrite.insertAfter(tx, into: group, after: last, [.type(container)])
            try YWrite.mapSet(tx, on: container, key: "id", .any([.string("tbl1")]))
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
            let t = YType(typeRef: .xmlText)
            _ = try YWrite.insertAfter(tx, into: para, after: nil, [.type(t)])
            try t.insert(0, "Cell", nil)
        }
        let harness = try await makeHarness(state: try YStateEncoder.encodeStateAsUpdate(doc))
        addTeardownBlock { await harness.close() }
        let view = harness.session.textView
        _ = mount(view)
        let drag = try XCTUnwrap(view.blockDragController)

        let p1Local = view.convert(
            try blockCenterWindowPoint(in: view, surface: harness.session.surface, blockID: "p1"), from: nil)
        let divLocal = view.convert(
            try blockCenterWindowPoint(in: view, surface: harness.session.surface, blockID: "div1"), from: nil)
        let tblLocal = view.convert(
            try blockCenterWindowPoint(in: view, surface: harness.session.surface, blockID: "tbl1"), from: nil)

        XCTAssertNil(drag.cardBlockID(at: p1Local))
        XCTAssertFalse(drag.canBeginCardLongPress(at: p1Local), "prose paragraph must reject card long-press")

        XCTAssertEqual(drag.cardBlockID(at: divLocal), "div1")
        XCTAssertTrue(drag.canBeginCardLongPress(at: divLocal), "divider must accept card long-press")

        XCTAssertEqual(drag.cardBlockID(at: tblLocal), "tbl1")
        XCTAssertTrue(drag.canBeginCardLongPress(at: tblLocal), "table card must accept card long-press")
    }

    /// Finding #10: sliding left on a nested block un-nests it to depth 0 and one undo restores it.
    func testHorizontalSlideLeftUnnestsChildBlockAndUndoesInOneStep() async throws {
        var parent = bullet("b1", "Parent bullet")
        parent.children = [paragraph("c1", "Nested child")]
        let harness = try await makeHarness([parent, paragraph("p2", "Trailing")])
        addTeardownBlock { await harness.close() }
        let view = harness.session.textView
        _ = mount(view)
        let drag = try XCTUnwrap(view.blockDragController)

        XCTAssertEqual(harness.session.surface.blocks.map(\.depth), [0, 1, 0])
        let c1Pt = try blockCenterWindowPoint(in: view, surface: harness.session.surface, blockID: "c1")
        XCTAssertTrue(drag.beginDrag(blockID: "c1", atWindowPoint: c1Pt))
        drag.updateDrag(atWindowPoint: CGPoint(x: c1Pt.x - 48, y: c1Pt.y))
        XCTAssertEqual(drag.currentCandidate?.dropTarget, NativeBlockDropTarget(destination: .after("b1"), depth: 0))
        XCTAssertTrue(drag.endDrag())
        await harness.settle()

        XCTAssertEqual(harness.session.surface.blocks.map(\.id), ["b1", "c1", "p2"])
        XCTAssertEqual(harness.session.surface.blocks.map(\.depth), [0, 0, 0])

        XCTAssertTrue(harness.input.undo())
        await harness.settle()
        XCTAssertEqual(harness.session.surface.blocks.map(\.depth), [0, 1, 0])
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
