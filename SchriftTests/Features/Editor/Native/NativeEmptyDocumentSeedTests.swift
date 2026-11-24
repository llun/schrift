import Foundation
import UIKit
import XCTest

@testable import Schrift

@MainActor
final class NativeEmptyDocumentSeedTests: NativeEditingTestCase {
    private static let emptyUpdate = Data([0, 0])

    /// Seeding a 2-byte empty Yjs state (which projects to zero blocks while
    /// remaining renderable and typeable) produces `document-store` → exactly
    /// one `blockGroup` → one `blockContainer(id)` → one `paragraph` with
    /// default props, replays cleanly onto a fresh replica, and refuses
    /// unsupported root shapes.
    func testSeedEmptyParagraphOnTwoByteDocProducesSingleBlockGroupAndParagraph() throws {
        let doc = YDoc(clientID: 10)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(Self.emptyUpdate), origin: .remote)

        let before = NativeBlockProjection.project(doc)
        XCTAssertTrue(before.blocks.isEmpty)
        XCTAssertTrue(before.isFullyRenderable)
        XCTAssertTrue(before.isFullyModeled)
        XCTAssertTrue(NativeBlockProjection.typability(doc, projected: before).canType)

        let engine = DocumentEngine(doc: doc)
        let seedID = "11111111-1111-4111-8111-111111111111"
        var persisted: [Data] = []
        let caret = try engine.seedEmptyParagraph(
            NativeEditCommand(id: UUID(), baseRevision: 0, blockID: "", kind: .seedEmptyParagraph(newID: seedID)),
            persist: { persisted.append($0) })

        XCTAssertEqual(caret, EditorPosition(blockID: seedID, offset: 0, assoc: -1))
        XCTAssertEqual(engine.revision, 1)
        XCTAssertEqual(persisted.count, 1)

        let root = try XCTUnwrap(doc.share[BlockNoteYjs.fragmentField])
        let rootChildren = YBlockProjection.children(of: root, includeFormats: false)
        XCTAssertEqual(rootChildren.count, 1)
        guard case .type(let group) = rootChildren[0].content else {
            return XCTFail("Expected a blockGroup child")
        }
        XCTAssertEqual(group.typeRef, .xmlElement(nodeName: "blockGroup"))
        let containers = YBlockProjection.children(of: group, includeFormats: false)
        XCTAssertEqual(containers.count, 1)

        let projected = NativeBlockProjection.project(doc)
        XCTAssertTrue(projected.isFullyRenderable)
        XCTAssertTrue(projected.isFullyModeled)
        XCTAssertTrue(NativeBlockProjection.typability(doc, projected: projected).canType)
        XCTAssertEqual(projected.blocks.count, 1)
        XCTAssertEqual(projected.blocks[0].id, seedID)
        XCTAssertEqual(projected.blocks[0].block.node, "paragraph")
        XCTAssertEqual(projected.blocks[0].block.runs, [])
        XCTAssertEqual(
            projected.blocks[0].block.props,
            [
                ProjectedProp(key: "backgroundColor", value: .string("default")),
                ProjectedProp(key: "textAlignment", value: .string("left")),
                ProjectedProp(key: "textColor", value: .string("default")),
            ])

        let replayed = YDoc(clientID: 11)
        defer { replayed.destroy() }
        try replayed.applyUpdate(YUpdateDecoder.decode(Self.emptyUpdate), origin: .remote)
        try replayed.applyUpdate(YUpdateDecoder.decode(persisted[0]), origin: .remote)
        let replayedProjection = NativeBlockProjection.project(replayed)
        XCTAssertEqual(replayedProjection.blocks.map(\.id), [seedID])
        XCTAssertEqual(replayedProjection.blocks.map(\.block.node), ["paragraph"])

        // An unsupported root is non-typeable and refuses seeding without writing.
        let unsupportedDoc = YDoc(clientID: 12)
        defer { unsupportedDoc.destroy() }
        _ = try unsupportedDoc.transact(local: true) { tx in
            let root = unsupportedDoc.get(BlockNoteYjs.fragmentField)
            let stray = YType(typeRef: .xmlElement(nodeName: "strayRoot"))
            _ = try YWrite.insertAfter(tx, into: root, after: nil, [.type(stray)])
        }
        let unsupportedProjection = NativeBlockProjection.project(unsupportedDoc)
        XCTAssertTrue(unsupportedProjection.blocks.isEmpty)
        XCTAssertFalse(unsupportedProjection.isFullyRenderable)
        XCTAssertFalse(NativeBlockProjection.typability(unsupportedDoc, projected: unsupportedProjection).canType)
        let unsupportedEngine = DocumentEngine(doc: unsupportedDoc)
        do {
            _ = try unsupportedEngine.seedEmptyParagraph(
                NativeEditCommand(id: UUID(), baseRevision: 0, blockID: "", kind: .seedEmptyParagraph(newID: seedID)),
                persist: { _ in XCTFail("Unsupported root must not persist") })
            XCTFail("Expected unsupportedNativeInput for unsupported root")
        } catch let error as DocumentEngineError {
            XCTAssertEqual(error, .unsupportedNativeInput)
        }
    }

    /// Seeding a document that already has blocks settles as a no-op without
    /// writing, persisting, advancing revision, or creating a second `blockGroup`.
    func testSeedEmptyParagraphIsNoOpWhenDocumentAlreadyHasBlocks() throws {
        let doc = YDoc(clientID: 20)
        defer { doc.destroy() }
        let existing = BlockNoteYjs.encode(
            [
                BlockNoteBlock(
                    node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("Existing")], id: "existing-1")
            ],
            clientID: 1)
        try doc.applyUpdate(YUpdateDecoder.decode(existing), origin: .remote)

        let engine = DocumentEngine(doc: doc)
        var persisted: [Data] = []
        let caret = try engine.seedEmptyParagraph(
            NativeEditCommand(
                id: UUID(), baseRevision: 0, blockID: "",
                kind: .seedEmptyParagraph(newID: "22222222-2222-4222-8222-222222222222")),
            persist: { persisted.append($0) })

        XCTAssertNil(caret)
        XCTAssertTrue(persisted.isEmpty)
        XCTAssertEqual(engine.revision, 0)
        let root = try XCTUnwrap(doc.share[BlockNoteYjs.fragmentField])
        XCTAssertEqual(YBlockProjection.children(of: root, includeFormats: false).count, 1)
        let projected = NativeBlockProjection.project(doc)
        XCTAssertEqual(projected.blocks.map(\.id), ["existing-1"])
        XCTAssertEqual(projected.blocks[0].block.runs, [InlineRun("Existing")])
    }

    /// When `document-store` already holds an empty `blockGroup`, seeding inserts
    /// the new paragraph container into that existing group rather than adding a
    /// second `blockGroup`.
    func testSeedEmptyParagraphReusesExistingEmptyBlockGroup() throws {
        let doc = YDoc(clientID: 30)
        defer { doc.destroy() }
        var originalGroup: YType?
        _ = try doc.transact(local: true) { tx in
            let root = doc.get(BlockNoteYjs.fragmentField)
            let group = YType(typeRef: .xmlElement(nodeName: "blockGroup"))
            _ = try YWrite.insertAfter(tx, into: root, after: nil, [.type(group)])
            originalGroup = group
        }

        let before = NativeBlockProjection.project(doc)
        XCTAssertTrue(before.blocks.isEmpty)
        XCTAssertTrue(before.isFullyRenderable)
        XCTAssertTrue(NativeBlockProjection.typability(doc, projected: before).canType)

        let engine = DocumentEngine(doc: doc)
        let seedID = "33333333-3333-4333-8333-333333333333"
        var persisted: [Data] = []
        let caret = try engine.seedEmptyParagraph(
            NativeEditCommand(id: UUID(), baseRevision: 0, blockID: "", kind: .seedEmptyParagraph(newID: seedID)),
            persist: { persisted.append($0) })

        XCTAssertEqual(caret, EditorPosition(blockID: seedID, offset: 0, assoc: -1))
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(engine.revision, 1)

        let root = try XCTUnwrap(doc.share[BlockNoteYjs.fragmentField])
        let rootChildren = YBlockProjection.children(of: root, includeFormats: false)
        XCTAssertEqual(rootChildren.count, 1, "must reuse existing blockGroup instead of creating a second")
        guard case .type(let reusedGroup) = rootChildren[0].content else {
            return XCTFail("Expected a blockGroup child")
        }
        XCTAssertTrue(reusedGroup === originalGroup)
        let projected = NativeBlockProjection.project(doc)
        XCTAssertEqual(projected.blocks.map(\.id), [seedID])
        XCTAssertEqual(projected.blocks[0].block.node, "paragraph")
    }

    /// A writable session over an empty 2-byte replica does not seed while in
    /// reading mode; entering editing seeds one empty paragraph (not recorded as
    /// an undo step), accepts typed text (including after tapping below the empty
    /// first line), keeps undo sane, and persists across a save/restore round trip.
    func testEditableSessionSeedsOnEnteringEditingAcceptsTypingAndSurvivesRestore() async throws {
        let harness = try await makeHarness(state: Self.emptyUpdate)
        addTeardownBlock { await harness.close() }
        let session = harness.session
        XCTAssertTrue(session.canType)
        XCTAssertFalse(session.hasUnsupportedRoot)

        // Reading mode must not seed.
        session.setEditing(false)
        await harness.settle()
        XCTAssertTrue(session.surface.blocks.isEmpty)
        XCTAssertTrue(harness.log.commands.isEmpty)

        // Entering editing seeds one empty paragraph, untracked by undo.
        session.setEditing(true)
        await harness.settle()
        XCTAssertEqual(session.surface.blocks.count, 1)
        XCTAssertEqual(session.surface.blocks[0].node, "paragraph")
        XCTAssertEqual(session.surface.blocks[0].runs, [])
        XCTAssertNil(harness.input.noticeKey)
        XCTAssertFalse(harness.input.history.canUndo, "seed must not create an undo step")
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: 0, length: 0))

        // Tapping in empty space below the single empty line clamps inside the paragraph.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        harness.view.frame = window.bounds
        window.addSubview(harness.view)
        window.isHidden = false
        defer {
            harness.view.removeFromSuperview()
            window.isHidden = true
        }
        harness.view.layoutIfNeeded()
        let belowLine = try XCTUnwrap(harness.view.closestPosition(to: CGPoint(x: 80, y: 300)))
        XCTAssertEqual(
            harness.view.offset(from: harness.view.beginningOfDocument, to: belowLine), 0,
            "tapping below the seeded empty line must clamp to offset 0, not endOfDocument")

        // Undoing immediately after seeding is a safe no-op.
        _ = await harness.run { harness.input.undo() }
        XCTAssertEqual(session.surface.blocks.count, 1)

        // Typing into the seeded paragraph works and is undoable back to the empty paragraph.
        harness.view.insertText("Hello")
        await harness.settle()
        XCTAssertNil(harness.input.noticeKey)
        XCTAssertEqual(session.surface.blocks.count, 1)
        XCTAssertEqual(session.surface.blocks[0].runs, [InlineRun("Hello")])
        XCTAssertTrue(harness.input.history.canUndo)

        let undone = await harness.run { harness.input.undo() }
        XCTAssertTrue(undone)
        XCTAssertEqual(session.surface.blocks.count, 1)
        XCTAssertEqual(session.surface.blocks[0].runs, [])
        XCTAssertFalse(harness.input.history.canUndo)

        let redone = await harness.run { harness.input.redo() }
        XCTAssertTrue(redone)
        XCTAssertEqual(session.surface.blocks.count, 1)
        XCTAssertEqual(session.surface.blocks[0].runs, [InlineRun("Hello")])

        // Durable save/restore round trip via ReplicaStore preserves the seeded paragraph and text.
        await session.close().value

        let restoredOptional = try await NativeEditorSession.restore(
            store: harness.store, scope: harness.scope, editable: true)
        let restored = try XCTUnwrap(restoredOptional)
        addTeardownBlock { await restored.close().value }
        XCTAssertTrue(restored.canType)
        XCTAssertEqual(restored.surface.blocks.count, 1)
        XCTAssertEqual(restored.surface.blocks[0].node, "paragraph")
        XCTAssertEqual(restored.surface.blocks[0].runs, [InlineRun("Hello")])
    }

    /// Read-only sessions (`inspect`, non-writable `seed`, or downgraded writable
    /// sessions) never seed an empty document, while a writable session over the
    /// exact same 2-byte state does.
    func testReadOnlySessionsNeverSeedEmptyDocument() async throws {
        let inspected = try await NativeEditorSession.inspect(state: Self.emptyUpdate)
        addTeardownBlock { await inspected.close().value }
        XCTAssertTrue(inspected.surface.blocks.isEmpty)
        inspected.setEditing(true)
        XCTAssertTrue(inspected.surface.blocks.isEmpty)
        XCTAssertFalse(inspected.textView.isEditable)

        let readOnlyReplica = try await NativeEditorSession.seed(state: Self.emptyUpdate)
        addTeardownBlock { await readOnlyReplica.close().value }
        XCTAssertTrue(readOnlyReplica.canType)
        XCTAssertFalse(readOnlyReplica.isWritable)
        readOnlyReplica.setEditing(true)
        await readOnlyReplica.settle()
        XCTAssertTrue(readOnlyReplica.surface.blocks.isEmpty)
        XCTAssertFalse(readOnlyReplica.textView.isEditable)

        let downgraded = try await NativeEditorSession.seed(state: Self.emptyUpdate)
        addTeardownBlock { await downgraded.close().value }
        let downgradedWrites = Locked(0)
        downgraded.enableTyping(persist: { _, _ in downgradedWrites.update { $0 += 1 } })
        downgraded.setExpectedWritable(false)
        downgraded.setEditing(true)
        await downgraded.settle()
        XCTAssertTrue(downgraded.surface.blocks.isEmpty)
        XCTAssertEqual(downgradedWrites.value, 0)
        XCTAssertFalse(downgraded.textView.isEditable)

        // Control: a writable session over the identical 2-byte state seeds on editing.
        let writable = try await NativeEditorSession.seed(state: Self.emptyUpdate)
        addTeardownBlock { await writable.close().value }
        let writableWrites = Locked(0)
        writable.enableTyping(persist: { _, _ in writableWrites.update { $0 += 1 } })
        writable.setEditing(true)
        await writable.settle()
        XCTAssertEqual(writable.surface.blocks.count, 1)
        XCTAssertEqual(writableWrites.value, 1)
    }

    /// If a remote update populates content before the queued seed command runs
    /// on the replica, the seed re-checks emptiness and settles as a no-op
    /// without refusing, showing a notice, or creating a duplicate `blockGroup`.
    func testConcurrentRemoteUpdateBeforeSeedSettlesAsNoOp() async throws {
        let gate = Latch()
        let gated = Locked(false)
        let session = try await NativeEditorSession.seed(
            state: Self.emptyUpdate,
            hooks: .init(beforeMessage: {
                let shouldHold = gated.value
                if shouldHold {
                    await gate.passing()
                }
            }))
        addTeardownBlock { await session.close().value }
        let writes = Locked(0)
        session.enableTyping(persist: { _, _ in writes.update { $0 += 1 } })
        await session.settle()
        XCTAssertTrue(session.surface.blocks.isEmpty)

        let remoteUpdate = BlockNoteYjs.encode(
            [
                BlockNoteBlock(
                    node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("From peer")], id: "peer-1")
            ],
            clientID: 99)

        // Hold the mailbox so the remote integrate lands ahead of the seed command.
        gated.value = true
        let integrateTask = Task {
            try await session.integrateServerState(remoteUpdate)
        }
        await waitUntil { gate.waiting > 0 }
        // Queue the seed while the surface still sees 0 blocks (baseRevision == 0).
        session.setEditing(true)
        XCTAssertEqual(session.input?.hasInFlightWork, true, "seed barrier must be queued before remote settles")
        gated.value = false
        gate.open()
        try await integrateTask.value
        await session.settle()

        XCTAssertEqual(writes.value, 0, "seed must settle as a no-op without journaling")
        XCTAssertNil(session.input?.noticeKey)
        XCTAssertEqual(session.surface.blocks.map(\.id), ["peer-1"])
        XCTAssertEqual(session.surface.blocks[0].runs, [InlineRun("From peer")])
        let rootGroupCount = await session.replicaDoc { doc -> Int in
            guard let root = doc.share[BlockNoteYjs.fragmentField] else { return 0 }
            return YBlockProjection.children(of: root, includeFormats: false).count
        }
        XCTAssertEqual(rootGroupCount, 1, "must never create a second blockGroup")
    }
}
