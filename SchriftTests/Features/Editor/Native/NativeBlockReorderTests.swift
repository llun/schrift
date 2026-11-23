import UIKit
import XCTest

@testable import Schrift

/// Engine, pure drop-target resolver, and coordinator tests for arbitrary
/// single-block drag-to-reorder (`.moveBlock(NativeMoveDestination)`).
@MainActor
final class NativeBlockReorderTests: NativeEditingTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows { window.isHidden = true }
        windows = []
        try await super.tearDown()
    }

    private func nested(_ block: BlockNoteBlock, _ children: [BlockNoteBlock]) -> BlockNoteBlock {
        var block = block
        block.children = children
        return block
    }

    private func numbered(_ id: String, _ text: String, start: Int? = nil) -> BlockNoteBlock {
        BlockNoteBlock(
            node: "numberedListItem",
            props: Self.paragraphProps + [("start", start.map { .int($0) } ?? .undefined)],
            runs: [InlineRun(text)], id: id)
    }

    private func toggleBlock(_ id: String, _ text: String, children: [BlockNoteBlock] = []) -> BlockNoteBlock {
        BlockNoteBlock(
            node: "toggleListItem", props: Self.paragraphProps, runs: [InlineRun(text)], id: id, children: children)
    }

    private func snap(
        _ id: String,
        node: String = "paragraph",
        depth: Int = 0,
        parentID: String? = nil,
        props: [ProjectedProp] = [],
        isOpaque: Bool = false,
        isLocked: Bool = false
    ) -> BlockSnapshot {
        var snapshot = BlockSnapshot(
            id: id, node: node, props: props, runs: [InlineRun(id)], isOpaque: isOpaque, depth: depth,
            parentID: parentID)
        snapshot.isLocked = isLocked
        return snapshot
    }

    private func ids(_ session: NativeEditorSession) -> [String] { session.surface.blocks.map(\.id) }

    private func depths(_ session: NativeEditorSession) -> [Int] { session.surface.blocks.map(\.depth) }

    private func caret(_ harness: Harness, _ id: String, _ offset: Int, length: Int = 0) throws {
        setSelection(harness, NSRange(location: try location(harness.session, id, offset), length: length))
    }

    private func payload(_ session: NativeEditorSession, _ id: String) async throws -> Data {
        let data = await session.engine { $0.subtreePayload([id]) }
        return try XCTUnwrap(data ?? nil, "\(id) has a lossless payload")
    }

    private func replayNestedGroup(_ harness: Harness, _ id: String) throws -> Bool? {
        let restored = try XCTUnwrap(harness.store.restore(for: harness.scope))
        let replica = YDoc(clientID: 98)
        defer { replica.destroy() }
        try replica.applyUpdate(YUpdateDecoder.decode(restored.checkpoint), origin: .remote)
        for update in restored.updates { try replica.applyUpdate(YUpdateDecoder.decode(update), origin: .remote) }
        let writer = BlockNoteWriter(doc: replica, schemas: BlockNoteWriter.nativePropSchemas)
        return try writer.find(id).nested == nil ? nil : true
    }

    private func columnSession(_ harness: Harness, _ column: String) async throws -> NativeEditorSession {
        let session = try await unwrapped(
            await harness.session.openColumn(group: "cl", column: column), "the column opens")
        addTeardownBlock { await session.close().value }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.addSubview(session.textView)
        session.textView.frame = window.bounds
        window.isHidden = false
        windows.append(window)
        return session
    }

    // MARK: - Pure Drop-Target Resolver

    func testDropTargetResolvesBeforeAfterFirstChildAndClampsDepth() {
        let blocks = [
            snap("a", depth: 0),
            snap("b", depth: 1, parentID: "a"),
            snap("c", depth: 2, parentID: "b"),
            snap("d", depth: 0),
            snap("e", depth: 0),
        ]

        // Slot 0: before the first block, always depth 0.
        XCTAssertEqual(
            NativeBlockReorder.dropTarget(moving: "e", in: blocks, slotIndex: 0, requestedDepth: 4),
            NativeBlockDropTarget(destination: .before("a"), depth: 0))

        // Slot 1 (between `a` and its first child `b`): only depth 1 is structurally valid.
        XCTAssertEqual(
            NativeBlockReorder.dropTarget(moving: "e", in: blocks, slotIndex: 1, requestedDepth: 0),
            NativeBlockDropTarget(destination: .firstChild(of: "a"), depth: 1))
        XCTAssertEqual(
            NativeBlockReorder.dropTarget(moving: "e", in: blocks, slotIndex: 1, requestedDepth: 5),
            NativeBlockDropTarget(destination: .firstChild(of: "a"), depth: 1))

        // Slot 3 (after `c` at depth 2, before `d` at depth 0): depth 0..3 all map unambiguously.
        XCTAssertEqual(
            NativeBlockReorder.dropTarget(moving: "e", in: blocks, slotIndex: 3, requestedDepth: -2),
            NativeBlockDropTarget(destination: .after("a"), depth: 0))
        XCTAssertEqual(
            NativeBlockReorder.dropTarget(moving: "e", in: blocks, slotIndex: 3, requestedDepth: 1),
            NativeBlockDropTarget(destination: .after("b"), depth: 1))
        XCTAssertEqual(
            NativeBlockReorder.dropTarget(moving: "e", in: blocks, slotIndex: 3, requestedDepth: 2),
            NativeBlockDropTarget(destination: .after("c"), depth: 2))
        XCTAssertEqual(
            NativeBlockReorder.dropTarget(moving: "e", in: blocks, slotIndex: 3, requestedDepth: 3),
            NativeBlockDropTarget(destination: .firstChild(of: "c"), depth: 3))
        XCTAssertEqual(
            NativeBlockReorder.dropTarget(moving: "e", in: blocks, slotIndex: 3, requestedDepth: 9),
            NativeBlockDropTarget(destination: .firstChild(of: "c"), depth: 3))

        // Moving `c` in place (slot 2 or 3) to root or sibling of `b` works; same slot+depth is a no-op.
        XCTAssertEqual(
            NativeBlockReorder.dropTarget(moving: "c", in: blocks, slotIndex: 2, requestedDepth: 0),
            NativeBlockDropTarget(destination: .after("a"), depth: 0))
        XCTAssertEqual(
            NativeBlockReorder.dropTarget(moving: "c", in: blocks, slotIndex: 2, requestedDepth: 1),
            NativeBlockDropTarget(destination: .after("b"), depth: 1))
        XCTAssertNil(NativeBlockReorder.dropTarget(moving: "c", in: blocks, slotIndex: 2, requestedDepth: 2))
        XCTAssertNil(NativeBlockReorder.dropTarget(moving: "c", in: blocks, slotIndex: 3, requestedDepth: 2))
    }

    func testDropTargetEnforcesFoldedToggleRules() {
        let blocks = [
            snap("a", depth: 0),
            snap("t", node: "toggleListItem", depth: 0),
            snap("c1", depth: 1, parentID: "t"),
            snap("c2", depth: 1, parentID: "t"),
            snap("b", depth: 0),
        ]

        // Collapsed toggle: dropping after `t` (bottom edge slot 2 OR top of `b` slot 4)
        // clamps to depth 0 `.after("t")`, never `.firstChild(of: "t")`.
        XCTAssertEqual(
            NativeBlockReorder.dropTarget(moving: "a", in: blocks, expanded: [], slotIndex: 2, requestedDepth: 3),
            NativeBlockDropTarget(destination: .after("t"), depth: 0))
        XCTAssertEqual(
            NativeBlockReorder.dropTarget(moving: "a", in: blocks, expanded: [], slotIndex: 4, requestedDepth: 3),
            NativeBlockDropTarget(destination: .after("t"), depth: 0))

        // Slot strictly between hidden children returns nil.
        XCTAssertNil(
            NativeBlockReorder.dropTarget(moving: "a", in: blocks, expanded: [], slotIndex: 3, requestedDepth: 1))

        // Hidden children cannot be dragged.
        XCTAssertFalse(NativeBlockReorder.canDrag("c1", in: blocks, expanded: []))
        XCTAssertNil(
            NativeBlockReorder.dropTarget(moving: "c1", in: blocks, expanded: [], slotIndex: 0, requestedDepth: 0))

        // Folded toggle itself IS draggable past `b`, and its own slot is a no-op.
        XCTAssertTrue(NativeBlockReorder.canDrag("t", in: blocks, expanded: []))
        XCTAssertEqual(
            NativeBlockReorder.dropTarget(moving: "t", in: blocks, expanded: [], slotIndex: 5, requestedDepth: 0),
            NativeBlockDropTarget(destination: .after("b"), depth: 0))
        XCTAssertNil(
            NativeBlockReorder.dropTarget(moving: "t", in: blocks, expanded: [], slotIndex: 2, requestedDepth: 0))
        XCTAssertNil(
            NativeBlockReorder.dropTarget(moving: "t", in: blocks, expanded: [], slotIndex: 3, requestedDepth: 0))

        // Expanded toggle allows dropping as first child at slot 2.
        XCTAssertEqual(
            NativeBlockReorder.dropTarget(moving: "a", in: blocks, expanded: ["t"], slotIndex: 2, requestedDepth: 1),
            NativeBlockDropTarget(destination: .firstChild(of: "t"), depth: 1))
    }

    func testDropTargetEnforcesTablesColumnGroupsLockedOpaqueAndDepthCap() {
        let blocks = [
            snap("p", depth: 0),
            snap("k1", depth: 1, parentID: "p"),
            snap("k2", depth: 1, parentID: "p"),
            snap("tbl", node: "table", depth: 0),
            snap("cl", node: "columnList", depth: 0),
            snap("locked", depth: 0, isLocked: true),
            snap("opaque", node: "fancyWidget", depth: 0, isOpaque: true),
            snap("parentOfOpaque", depth: 0),
            snap("opaqueKid", node: "fancyWidget", depth: 1, parentID: "parentOfOpaque", isOpaque: true),
            snap("tail", depth: 0),
        ]

        // Table and column group stay depth 0: refused between depth-1 children (`k1`/`k2`), allowed at root.
        XCTAssertTrue(NativeBlockReorder.canDrag("tbl", in: blocks))
        XCTAssertTrue(NativeBlockReorder.canDrag("cl", in: blocks))
        XCTAssertNil(NativeBlockReorder.dropTarget(moving: "tbl", in: blocks, slotIndex: 2, requestedDepth: 0))
        XCTAssertNil(NativeBlockReorder.dropTarget(moving: "cl", in: blocks, slotIndex: 2, requestedDepth: 0))
        XCTAssertNil(NativeBlockReorder.dropTarget(moving: "tbl", in: blocks, slotIndex: 3, requestedDepth: 2))
        XCTAssertEqual(
            NativeBlockReorder.dropTarget(moving: "tbl", in: blocks, slotIndex: 0, requestedDepth: 2),
            NativeBlockDropTarget(destination: .before("p"), depth: 0))
        XCTAssertEqual(
            NativeBlockReorder.dropTarget(moving: "cl", in: blocks, slotIndex: 3, requestedDepth: 2),
            NativeBlockDropTarget(destination: .after("p"), depth: 0))

        // Nothing can drop as firstChild of a table, columnList, locked block, or opaque block.
        XCTAssertEqual(
            NativeBlockReorder.dropTarget(moving: "tail", in: blocks, slotIndex: 4, requestedDepth: 2),
            NativeBlockDropTarget(destination: .after("tbl"), depth: 0))
        XCTAssertEqual(
            NativeBlockReorder.dropTarget(moving: "tail", in: blocks, slotIndex: 5, requestedDepth: 2),
            NativeBlockDropTarget(destination: .after("cl"), depth: 0))
        XCTAssertEqual(
            NativeBlockReorder.dropTarget(moving: "tail", in: blocks, slotIndex: 6, requestedDepth: 2),
            NativeBlockDropTarget(destination: .after("locked"), depth: 0))
        XCTAssertEqual(
            NativeBlockReorder.dropTarget(moving: "tail", in: blocks, slotIndex: 7, requestedDepth: 2),
            NativeBlockDropTarget(destination: .after("opaque"), depth: 0))

        // Locked, opaque, and a parent with an opaque child are not draggable.
        XCTAssertFalse(NativeBlockReorder.canDrag("locked", in: blocks))
        XCTAssertFalse(NativeBlockReorder.canDrag("opaque", in: blocks))
        XCTAssertFalse(NativeBlockReorder.canDrag("parentOfOpaque", in: blocks))
        XCTAssertNil(NativeBlockReorder.dropTarget(moving: "locked", in: blocks, slotIndex: 0, requestedDepth: 0))
        XCTAssertNil(NativeBlockReorder.dropTarget(moving: "opaque", in: blocks, slotIndex: 0, requestedDepth: 0))
        XCTAssertNil(
            NativeBlockReorder.dropTarget(moving: "parentOfOpaque", in: blocks, slotIndex: 0, requestedDepth: 0))

        // Own visible subtree slot returns nil.
        XCTAssertNil(NativeBlockReorder.dropTarget(moving: "p", in: blocks, slotIndex: 1, requestedDepth: 1))
        XCTAssertNil(NativeBlockReorder.dropTarget(moving: "p", in: blocks, slotIndex: 2, requestedDepth: 1))

        // Depth cap accounts for the dragged block's own subtree height.
        var deepChain: [BlockSnapshot] = []
        for depth in 0...BlockNoteWriter.maxNestingDepth {
            deepChain.append(snap("d\(depth)", depth: depth, parentID: depth == 0 ? nil : "d\(depth - 1)"))
        }
        deepChain.append(snap("sub", depth: 0))
        deepChain.append(snap("subKid", depth: 1, parentID: "sub"))
        // Subtree height is 1, so max landing depth is maxNestingDepth - 1 (15).
        XCTAssertEqual(
            NativeBlockReorder.dropTarget(
                moving: "sub", in: deepChain, slotIndex: BlockNoteWriter.maxNestingDepth + 1, requestedDepth: 20),
            NativeBlockDropTarget(
                destination: .after("d\(BlockNoteWriter.maxNestingDepth - 1)"),
                depth: BlockNoteWriter.maxNestingDepth - 1))
    }

    // MARK: - Engine & Coordinator: Multi-Block Moves, Nesting, Subtrees & Selection

    func testMoveDownAndUpAcrossSeveralBlocksPreservesPayloadAndSelection() async throws {
        let harness = try await makeHarness([
            paragraph("a", "Alpha"),
            paragraph("b", "Bravo"),
            paragraph("c", "Charlie"),
            paragraph("d", "Delta"),
            paragraph("e", "Echo"),
        ])
        addTeardownBlock { await harness.close() }
        let session = harness.session

        // Selection inside the moved block keeps exact (offset, length).
        try caret(harness, "a", 1, length: 3)
        let movedDown = await harness.run { harness.input.moveBlock("a", to: .after("d")) }
        XCTAssertTrue(movedDown)
        XCTAssertEqual(ids(session), ["b", "c", "d", "a", "e"])
        XCTAssertEqual(harness.log.commands.last?.kind, .moveBlock(.after("d")))
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(session, "a", 1), length: 3))
        try await assertConsistent(harness, localCommands: 1)

        // Caret in another block follows the newly moved block to offset 0.
        try caret(harness, "c", 2)
        let movedUp = await harness.run { harness.input.moveBlock("e", to: .before("b")) }
        XCTAssertTrue(movedUp)
        XCTAssertEqual(ids(session), ["e", "b", "c", "d", "a"])
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(session, "e", 0), length: 0))
        try await assertConsistent(harness, localCommands: 2)
    }

    func testMoveToFirstChildAndOutToRootWithChildrenPrunesEmptiedGroups() async throws {
        var rich = heading("b", "")
        rich.runs = [InlineRun("Bold", marks: [("bold", "{}")]), InlineRun(" tail")]
        let harness = try await makeHarness([
            paragraph("a", "Alpha"),
            nested(rich, [nested(bullet("b1", "Child"), [paragraph("b11", "Grandchild")])]),
            paragraph("c", "Gamma"),
            paragraph("d", "Delta"),
        ])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let payloadBefore = try await payload(session, "b")

        // Indent `b` (with its 2-level subtree) as first child of `c` (creating `c`'s nested group).
        try caret(harness, "b", 2)
        let indented = await harness.run { harness.input.moveBlock("b", to: .firstChild(of: "c")) }
        XCTAssertTrue(indented)
        XCTAssertEqual(ids(session), ["a", "c", "b", "b1", "b11", "d"])
        XCTAssertEqual(depths(session), [0, 0, 1, 2, 3, 0])
        XCTAssertEqual(try block(session, "b").parentID, "c")
        let payloadAfterIndent = try await payload(session, "b")
        XCTAssertEqual(payloadAfterIndent, payloadBefore)
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(session, "b", 2), length: 0))

        // Insert `d` as first child of `c` (which already has a nested group containing `b`).
        let insertedBeforeB = await harness.run { harness.input.moveBlock("d", to: .firstChild(of: "c")) }
        XCTAssertTrue(insertedBeforeB)
        XCTAssertEqual(ids(session), ["a", "c", "d", "b", "b1", "b11"])
        XCTAssertEqual(depths(session), [0, 0, 1, 1, 2, 3])

        // Outdent `b` back to root after `c`, then outdent `d` to root before `a` (pruning `c`'s nested group).
        let outdentedB = await harness.run { harness.input.moveBlock("b", to: .after("c")) }
        XCTAssertTrue(outdentedB)
        XCTAssertEqual(ids(session), ["a", "c", "d", "b", "b1", "b11"])
        XCTAssertEqual(depths(session), [0, 0, 1, 0, 1, 2])
        let payloadAfterOutdent = try await payload(session, "b")
        XCTAssertEqual(payloadAfterOutdent, payloadBefore)

        let outdentedD = await harness.run { harness.input.moveBlock("d", to: .before("a")) }
        XCTAssertTrue(outdentedD)
        XCTAssertEqual(ids(session), ["d", "a", "c", "b", "b1", "b11"])
        XCTAssertEqual(depths(session), [0, 0, 0, 0, 1, 2])
        XCTAssertNil(try replayNestedGroup(harness, "c"), "emptied nested group is removed")
        try await assertConsistent(harness, localCommands: 4)
    }

    // MARK: - Folded Toggles

    func testFoldedToggleMovesWithHiddenChildrenAndDropAfterLandsOutsideSubtree() async throws {
        let harness = try await makeHarness([
            paragraph("a", "Alpha"),
            toggleBlock("t", "Toggle", children: [paragraph("c1", "Hidden one"), paragraph("c2", "Hidden two")]),
            paragraph("b", "Bravo"),
        ])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        XCTAssertTrue(session.surface.isHidden(blockID: "c1"), "collapsed by default")
        let togglePayload = try await payload(session, "t")

        // Drop `a` after folded toggle `t`: lands after `t`'s entire subtree, never inside hidden children.
        let dropAfter = await harness.run { harness.input.moveBlock("a", to: .after("t")) }
        XCTAssertTrue(dropAfter)
        XCTAssertEqual(ids(session), ["t", "c1", "c2", "a", "b"])
        XCTAssertEqual(depths(session), [0, 1, 1, 0, 0])
        XCTAssertTrue(session.surface.isHidden(blockID: "c1"))
        XCTAssertTrue(session.surface.isHidden(blockID: "c2"))
        XCTAssertFalse(session.surface.isExpanded("t"))

        // Coordinator refuses dropping as firstChild of a folded toggle or relative to a hidden child.
        let intoFolded = await harness.run { harness.input.moveBlock("b", to: .firstChild(of: "t")) }
        XCTAssertFalse(intoFolded)
        let afterHidden = await harness.run { harness.input.moveBlock("b", to: .after("c1")) }
        XCTAssertFalse(afterHidden)
        XCTAssertNil(harness.input.noticeKey)

        // Dragging the folded toggle itself carries its hidden children intact and stays folded.
        let moveToggle = await harness.run { harness.input.moveBlock("t", to: .after("b")) }
        XCTAssertTrue(moveToggle)
        XCTAssertEqual(ids(session), ["a", "b", "t", "c1", "c2"])
        XCTAssertTrue(session.surface.isHidden(blockID: "c1"))
        XCTAssertTrue(session.surface.isHidden(blockID: "c2"))
        XCTAssertFalse(session.surface.isExpanded("t"))
        let payloadAfterToggle = try await payload(session, "t")
        XCTAssertEqual(payloadAfterToggle, togglePayload)
        XCTAssertFalse(harness.view.accessibilityValue?.contains("Hidden") ?? true)
        try await assertConsistent(harness, localCommands: 2)
    }

    // MARK: - Tables & Column Groups

    func testTableMovesOnlyAtDepthZeroAndRejectsChildren() async throws {
        let base64 = try XCTUnwrap(BlockNoteTableCaptures.fixtures.first { $0.name == "styled" }?.update)
        let harness = try await makeHarness(state: try XCTUnwrap(Data(base64Encoded: base64)))
        addTeardownBlock { await harness.close() }
        let session = harness.session
        XCTAssertEqual(ids(session), ["lead", "tbl", "tail"])
        let tablePayload = try await payload(session, "tbl")

        // Moving the table to depth 0 (after `tail`, then before `lead`) succeeds losslessly.
        let movedDown = await harness.run { harness.input.moveBlock("tbl", to: .after("tail")) }
        XCTAssertTrue(movedDown)
        XCTAssertEqual(ids(session), ["lead", "tail", "tbl"])
        let tablePayloadAfter = try await payload(session, "tbl")
        XCTAssertEqual(tablePayloadAfter, tablePayload)

        // Nesting the table under a paragraph is refused.
        let nestedTable = await harness.run { harness.input.moveBlock("tbl", to: .firstChild(of: "lead")) }
        XCTAssertFalse(nestedTable)
        XCTAssertNil(harness.input.noticeKey)

        // Nesting a paragraph inside the table is refused.
        let intoTable = await harness.run { harness.input.moveBlock("tail", to: .firstChild(of: "tbl")) }
        XCTAssertFalse(intoTable)

        // Make `tail` a child of `lead`, then confirm the table cannot drop as a depth-1 sibling of `tail`.
        let nestTail = await harness.run { harness.input.moveBlock("tail", to: .firstChild(of: "lead")) }
        XCTAssertTrue(nestTail)
        let tableAtDepth1 = await harness.run { harness.input.moveBlock("tbl", to: .after("tail")) }
        XCTAssertFalse(tableAtDepth1)

        // Table can still drop at depth 0 before `lead`.
        let movedTop = await harness.run { harness.input.moveBlock("tbl", to: .before("lead")) }
        XCTAssertTrue(movedTop)
        XCTAssertEqual(ids(session), ["tbl", "lead", "tail"])
        XCTAssertEqual(depths(session), [0, 0, 1])
        let tablePayloadFinal = try await payload(session, "tbl")
        XCTAssertEqual(tablePayloadFinal, tablePayload)
        try await assertConsistent(harness, localCommands: 3)
    }

    func testColumnGroupMovesAsATopLevelCardAndRejectsNesting() async throws {
        let base64 = try XCTUnwrap(BlockNoteColumnCaptures.fixtures.first { $0.name == "two" }?.update)
        let harness = try await makeHarness(state: try XCTUnwrap(Data(base64Encoded: base64)))
        addTeardownBlock { await harness.close() }
        let session = harness.session
        XCTAssertEqual(ids(session), ["lead", "cl", "tail"])

        // Move the column group after `tail`, then before `lead`.
        let movedDown = await harness.run { harness.input.moveBlock("cl", to: .after("tail")) }
        XCTAssertTrue(movedDown)
        XCTAssertEqual(ids(session), ["lead", "tail", "cl"])

        // Nesting the column group as firstChild of `lead` is refused.
        let nestedGroup = await harness.run { harness.input.moveBlock("cl", to: .firstChild(of: "lead")) }
        XCTAssertFalse(nestedGroup)

        // Dropping a paragraph as firstChild of the column group is refused.
        let intoGroup = await harness.run { harness.input.moveBlock("lead", to: .firstChild(of: "cl")) }
        XCTAssertFalse(intoGroup)

        // Nest `tail` under `lead`; column group can still move before/after `lead` (a root block with children)
        // but NOT beside `tail` at depth 1.
        let nestTail = await harness.run { harness.input.moveBlock("tail", to: .firstChild(of: "lead")) }
        XCTAssertTrue(nestTail)
        let groupAtDepth1 = await harness.run { harness.input.moveBlock("cl", to: .after("tail")) }
        XCTAssertFalse(groupAtDepth1)

        let movedTop = await harness.run { harness.input.moveBlock("cl", to: .before("lead")) }
        XCTAssertTrue(movedTop)
        XCTAssertEqual(ids(session), ["cl", "lead", "tail"])
        XCTAssertEqual(depths(session), [0, 0, 1])

        // Dropping a normal block after the column group at depth 0 works.
        let leadAfterGroup = await harness.run { harness.input.moveBlock("lead", to: .after("cl")) }
        XCTAssertFalse(leadAfterGroup, "no-op: lead is already immediately after cl")
        let movedClBack = await harness.run { harness.input.moveBlock("cl", to: .after("lead")) }
        XCTAssertTrue(movedClBack)
        XCTAssertEqual(ids(session), ["lead", "tail", "cl"])
        try await assertConsistent(harness, localCommands: 4)
    }

    func testReorderWithinAnOpenColumnStaysInsideThatColumn() async throws {
        let base64 = try XCTUnwrap(BlockNoteColumnCaptures.fixtures.first { $0.name == "two" }?.update)
        let harness = try await makeHarness(state: try XCTUnwrap(Data(base64Encoded: base64)))
        addTeardownBlock { await harness.close() }
        let column = try await columnSession(harness, "c1")
        let columnInput = try XCTUnwrap(column.input)
        // Column c1 initially has ["a" (0), "b" (0), "b2" (1)].
        XCTAssertEqual(ids(column), ["a", "b", "b2"])
        XCTAssertEqual(depths(column), [0, 0, 1])

        // Move `b` (with its child `b2`) before `a` inside column c1.
        let movedUp = await column.run { columnInput.moveBlock("b", to: .before("a")) }
        XCTAssertTrue(movedUp)
        XCTAssertEqual(ids(column), ["b", "b2", "a"])
        XCTAssertEqual(depths(column), [0, 1, 0])

        // Outdent `b2` to column top level after `a`.
        let outdented = await column.run { columnInput.moveBlock("b2", to: .after("a")) }
        XCTAssertTrue(outdented)
        XCTAssertEqual(ids(column), ["b", "a", "b2"])
        XCTAssertEqual(depths(column), [0, 0, 0])

        // Indent `b2` as first child of `b`.
        let indented = await column.run { columnInput.moveBlock("b2", to: .firstChild(of: "b")) }
        XCTAssertTrue(indented)
        XCTAssertEqual(ids(column), ["b", "b2", "a"])
        XCTAssertEqual(depths(column), [0, 1, 0])

        // Engine refuses cross-column and column-to-root moves.
        let crossRefused = await harness.session.engine { engine -> Bool in
            let crossCol = NativeEditCommand(
                id: UUID(), baseRevision: engine.revision, blockID: "a", kind: .moveBlock(.after("c")))
            let toRoot = NativeEditCommand(
                id: UUID(), baseRevision: engine.revision, blockID: "a", kind: .moveBlock(.after("lead")))
            return !engine.canApplyStructural(crossCol) && !engine.canApplyStructural(toRoot)
        }
        XCTAssertEqual(crossRefused, true)
        await harness.settle()
        XCTAssertEqual(ids(harness.session), ["lead", "cl", "tail"], "document list never shows column blocks")
        try await assertConsistent(harness, localCommands: 3)
    }

    // MARK: - Refusals (Own Subtree, No-op, Locked, Opaque, Depth Limit)

    func testRefusesOwnSubtreeNoOpsLockedOpaqueAndDepthLimit() async throws {
        let locked = BlockNoteBlock(
            node: "paragraph", props: Self.paragraphProps + [("unknownProp", .string("keep"))],
            runs: [InlineRun("Locked")], id: "locked")
        let opaque = BlockNoteBlock(node: "fancyWidget", props: [], runs: [], id: "opaque")
        let harness = try await makeHarness([
            nested(paragraph("p", "Parent"), [paragraph("k1", "Kid1"), paragraph("k2", "Kid2")]),
            paragraph("s", "Sibling"),
            locked,
            opaque,
            nested(
                paragraph("badParent", "HasOpaque"),
                [BlockNoteBlock(node: "fancyWidget", props: [], runs: [], id: "okid")]),
        ])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let beforeIDs = ids(session)

        // Moving into own subtree (self or descendant) is refused.
        let intoSelf = await harness.run { harness.input.moveBlock("p", to: .after("p")) }
        let intoKid = await harness.run { harness.input.moveBlock("p", to: .after("k1")) }
        let childOfKid = await harness.run { harness.input.moveBlock("p", to: .firstChild(of: "k2")) }
        XCTAssertFalse(intoSelf)
        XCTAssertFalse(intoKid)
        XCTAssertFalse(childOfKid)

        // No-op moves (before next sibling, after previous sibling, firstChild when already first child) are refused.
        let noopBefore = await harness.run { harness.input.moveBlock("p", to: .before("s")) }
        let noopAfter = await harness.run { harness.input.moveBlock("s", to: .after("p")) }
        let noopFirst = await harness.run { harness.input.moveBlock("k1", to: .firstChild(of: "p")) }
        XCTAssertFalse(noopBefore)
        XCTAssertFalse(noopAfter)
        XCTAssertFalse(noopFirst)

        // Locked, opaque, and parent-with-opaque-child are refused.
        let moveLocked = await harness.run { harness.input.moveBlock("locked", to: .before("p")) }
        let moveOpaque = await harness.run { harness.input.moveBlock("opaque", to: .before("p")) }
        let moveBadParent = await harness.run { harness.input.moveBlock("badParent", to: .before("p")) }
        let intoLocked = await harness.run { harness.input.moveBlock("s", to: .firstChild(of: "locked")) }
        let intoOpaque = await harness.run { harness.input.moveBlock("s", to: .firstChild(of: "opaque")) }
        XCTAssertFalse(moveLocked)
        XCTAssertFalse(moveOpaque)
        XCTAssertFalse(moveBadParent)
        XCTAssertFalse(intoLocked)
        XCTAssertFalse(intoOpaque)

        XCTAssertNil(harness.input.noticeKey, "refusals are quiet like moveUp/moveDown")
        XCTAssertEqual(ids(session), beforeIDs)
        XCTAssertEqual(harness.log.commands.count, 0)
        try await assertConsistent(harness, localCommands: 0)
    }

    func testRefusesExceedingMaxNestingDepth() async throws {
        // Build a chain of depth 0...maxNestingDepth, plus a 2-level subtree `sub -> subKid`.
        var chain = paragraph("d\(BlockNoteWriter.maxNestingDepth)", "Leaf")
        for depth in stride(from: BlockNoteWriter.maxNestingDepth - 1, through: 0, by: -1) {
            chain = nested(paragraph("d\(depth)", "L\(depth)"), [chain])
        }
        let harness = try await makeHarness([
            chain,
            nested(paragraph("sub", "Sub"), [paragraph("subKid", "SubKid")]),
        ])
        addTeardownBlock { await harness.close() }

        // Landing `sub` (height 1) at depth 16 would put `subKid` at depth 17: refused.
        let tooDeep1 = await harness.run {
            harness.input.moveBlock("sub", to: .after("d\(BlockNoteWriter.maxNestingDepth)"))
        }
        let tooDeep2 = await harness.run {
            harness.input.moveBlock("sub", to: .firstChild(of: "d\(BlockNoteWriter.maxNestingDepth)"))
        }
        XCTAssertFalse(tooDeep1)
        XCTAssertFalse(tooDeep2)

        // Landing `sub` (height 1) at depth 15 (`after("d15")`) puts `subKid` at depth 16: allowed.
        let atLimit = await harness.run {
            harness.input.moveBlock("sub", to: .after("d\(BlockNoteWriter.maxNestingDepth - 1)"))
        }
        XCTAssertTrue(atLimit)
        XCTAssertEqual(try block(harness.session, "sub").depth, BlockNoteWriter.maxNestingDepth - 1)
        XCTAssertEqual(try block(harness.session, "subKid").depth, BlockNoteWriter.maxNestingDepth)
        try await assertConsistent(harness, localCommands: 1)
    }

    // MARK: - Numbered List Renumbering & Single-Step Undo

    func testNumberedListRenumberingMatchesMoveUp() async throws {
        let seed = [
            numbered("n1", "One", start: 5),
            numbered("n2", "Two"),
            numbered("n3", "Three"),
        ]
        let dragHarness = try await makeHarness(seed)
        addTeardownBlock { await dragHarness.close() }
        let stepHarness = try await makeHarness(seed)
        addTeardownBlock { await stepHarness.close() }

        // Move `n3` before `n1` in one drag command vs two `moveUp` commands.
        let dragged = await dragHarness.run { dragHarness.input.moveBlock("n3", to: .before("n1")) }
        XCTAssertTrue(dragged)

        try caret(stepHarness, "n3", 0)
        let up1 = await stepHarness.run { stepHarness.input.performBlockAction(.moveUp) }
        let up2 = await stepHarness.run { stepHarness.input.performBlockAction(.moveUp) }
        XCTAssertTrue(up1 && up2)

        XCTAssertEqual(ids(dragHarness.session), ["n3", "n1", "n2"])
        XCTAssertEqual(ids(dragHarness.session), ids(stepHarness.session))
        XCTAssertEqual(dragHarness.session.surface.blocks, stepHarness.session.surface.blocks)

        let dragNumbers = try ["n3", "n1", "n2"].map { id -> Int? in
            dragHarness.session.surface.storage.attribute(
                .nativeListNumber, at: try location(dragHarness.session, id, 0), effectiveRange: nil) as? Int
        }
        let stepNumbers = try ["n3", "n1", "n2"].map { id -> Int? in
            stepHarness.session.surface.storage.attribute(
                .nativeListNumber, at: try location(stepHarness.session, id, 0), effectiveRange: nil) as? Int
        }
        // `n3` has unset `start` so the run now starts at 1, matching BlockNote's `moveUp`.
        XCTAssertEqual(dragNumbers, [1, 2, 3])
        XCTAssertEqual(dragNumbers, stepNumbers)
        try await assertConsistent(dragHarness, localCommands: 1)
    }

    func testOneUndoRestoresMoveAndSelection() async throws {
        let harness = try await makeHarness([
            paragraph("a", "Alpha"),
            nested(paragraph("b", "Bravo"), [paragraph("b1", "Child")]),
            paragraph("c", "Charlie"),
            paragraph("d", "Delta"),
        ])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let initialBlocks = session.surface.blocks

        try caret(harness, "b", 3)
        await harness.settle()
        let beforeRange = harness.view.selectedRange

        let moved = await harness.run { harness.input.moveBlock("b", to: .firstChild(of: "d")) }
        XCTAssertTrue(moved)
        XCTAssertEqual(ids(session), ["a", "c", "d", "b", "b1"])
        XCTAssertEqual(depths(session), [0, 0, 0, 1, 2])
        XCTAssertTrue(harness.input.canUndo)

        // One undo restores the entire move (including pruning `d`'s nested group) and selection.
        let undone = await harness.run { harness.input.undo() }
        XCTAssertTrue(undone)
        XCTAssertEqual(session.surface.blocks, initialBlocks)
        XCTAssertNil(try replayNestedGroup(harness, "d"))
        XCTAssertEqual(harness.view.selectedRange, beforeRange)
        XCTAssertFalse(harness.input.canUndo)
        XCTAssertTrue(harness.input.canRedo)

        let redone = await harness.run { harness.input.redo() }
        XCTAssertTrue(redone)
        XCTAssertEqual(ids(session), ["a", "c", "d", "b", "b1"])
        XCTAssertEqual(depths(session), [0, 0, 0, 1, 2])
        try await assertConsistent(harness, localCommands: 3)
    }
}
