import Foundation
import UIKit
import XCTest

@testable import Schrift

@MainActor
final class NativeEmptyDocumentSeedTests: NativeEditingTestCase {
    private static let emptyUpdate = Data([0, 0])

    /// Mounts `view` in an active window so `becomeFirstResponder()` drives
    /// UIKit's real `textViewDidBeginEditing` lifecycle, and returns a cleanup
    /// closure for `defer`.
    private func mountInWindow(_ view: NativeTextView) -> () -> Void {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        return {
            view.resignFirstResponder()
            view.removeFromSuperview()
            window.isHidden = true
        }
    }

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

    /// Entering editing alone (e.g. title focus on a new subpage) must not
    /// write. Focusing the body seeds exactly one empty paragraph, typed text
    /// lands and survives restore, and undo never removes the seeded paragraph.
    func testEnteringEditingAloneDoesNotWriteAndBodyFocusSeedsOnceAndSurvivesRestore() async throws {
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

        // Entering editing alone (title focused, body unfocused) must not write.
        let unmount = mountInWindow(harness.view)
        defer { unmount() }
        session.setEditing(true)
        await harness.settle()
        XCTAssertTrue(harness.view.isEditable)
        XCTAssertFalse(harness.view.isFirstResponder)
        XCTAssertTrue(session.surface.blocks.isEmpty, "entering editing alone must not seed")
        XCTAssertTrue(harness.log.commands.isEmpty, "entering editing alone must not journal")
        XCTAssertNil(harness.input.noticeKey)

        // Focusing the body seeds exactly once.
        XCTAssertTrue(harness.view.becomeFirstResponder())
        await harness.settle()
        XCTAssertNil(harness.input.noticeKey)
        XCTAssertEqual(session.surface.blocks.count, 1)
        XCTAssertEqual(session.surface.blocks[0].node, "paragraph")
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: 0, length: 0))
        XCTAssertFalse(harness.input.history.canUndo, "seed must not create an undo step")
        let seedCountAfterFirstFocus = harness.log.commands.filter {
            if case .seedEmptyParagraph = $0.kind { true } else { false }
        }.count
        XCTAssertEqual(seedCountAfterFirstFocus, 1)

        // Blurring and refocusing the body must not seed a second time.
        XCTAssertTrue(harness.view.resignFirstResponder())
        XCTAssertTrue(harness.view.becomeFirstResponder())
        await harness.settle()
        let seedCountAfterRefocus = harness.log.commands.filter {
            if case .seedEmptyParagraph = $0.kind { true } else { false }
        }.count
        XCTAssertEqual(seedCountAfterRefocus, 1, "refocusing must not post a second seed")

        // Typing lands, undo clears only the typed text, and restore persists it.
        for character in "Hello" {
            harness.view.insertText(String(character))
        }
        await harness.settle()
        XCTAssertEqual(session.surface.blocks[0].runs, [InlineRun("Hello")])
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: 5, length: 0))

        let undone = await harness.run { harness.input.undo() }
        XCTAssertTrue(undone)
        XCTAssertEqual(session.surface.blocks.count, 1)
        XCTAssertEqual(session.surface.blocks[0].runs, [])
        XCTAssertFalse(harness.input.history.canUndo)

        harness.view.layoutIfNeeded()
        let belowLine = try XCTUnwrap(harness.view.closestPosition(to: CGPoint(x: 80, y: 300)))
        XCTAssertEqual(
            harness.view.offset(from: harness.view.beginningOfDocument, to: belowLine), 0,
            "tapping below the seeded empty line must clamp to offset 0, not endOfDocument")

        let redone = await harness.run { harness.input.redo() }
        XCTAssertTrue(redone)
        XCTAssertEqual(session.surface.blocks[0].runs, [InlineRun("Hello")])

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

    /// Keys typed while the seed barrier is in flight land in order; marked
    /// text started while the seed is in flight is refused quietly without a
    /// notice or disabling editing, and composition works once the seed lands.
    func testKeysAndMarkedTextWhileSeedIsInFlight() async throws {
        // 1. Rapid keys typed while the seed barrier is in flight land in exact order.
        do {
            let gate = Latch()
            let gated = Locked(false)
            let session = try await NativeEditorSession.seed(
                state: Self.emptyUpdate,
                hooks: .init(beforeMessage: {
                    if gated.value { await gate.passing() }
                }))
            addTeardownBlock { await session.close().value }
            session.enableTyping(persist: { _, _ in })
            session.setEditing(true)
            let unmount = mountInWindow(session.textView)
            defer {
                gated.value = false
                gate.open()
                unmount()
            }

            gated.value = true
            XCTAssertTrue(session.textView.becomeFirstResponder())
            await waitUntil { gate.waiting > 0 }
            XCTAssertTrue(session.surface.blocks.isEmpty, "seed must still be in flight behind the gate")
            for character in "Hello" {
                session.textView.insertText(String(character))
            }
            XCTAssertEqual(session.input?.hasInFlightWork, true)

            gated.value = false
            gate.open()
            await session.settle()

            XCTAssertNil(session.input?.noticeKey)
            XCTAssertEqual(session.surface.blocks.count, 1)
            XCTAssertEqual(session.surface.blocks[0].runs, [InlineRun("Hello")])
            XCTAssertEqual(session.textView.selectedRange, NSRange(location: 5, length: 0))
        }

        // 2. Marked text started while the seed is in flight is refused quietly; composition works once it lands.
        do {
            let gate = Latch()
            let gated = Locked(false)
            let session = try await NativeEditorSession.seed(
                state: Self.emptyUpdate,
                hooks: .init(beforeMessage: {
                    if gated.value { await gate.passing() }
                }))
            addTeardownBlock { await session.close().value }
            session.enableTyping(persist: { _, _ in })
            session.setEditing(true)
            let unmount = mountInWindow(session.textView)
            defer {
                gated.value = false
                gate.open()
                unmount()
            }

            gated.value = true
            XCTAssertTrue(session.textView.becomeFirstResponder())
            await waitUntil { gate.waiting > 0 }
            session.textView.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
            XCTAssertEqual(session.input?.composition.isActive, false, "marked text while seeding must be refused")
            XCTAssertNil(session.textView.markedTextRange)
            XCTAssertTrue(session.textView.isEditable, "refusing marked text while seeding must not lock editing")
            XCTAssertTrue(session.textView.isFirstResponder)
            XCTAssertNil(session.input?.noticeKey, "refusing marked text while seeding must not show a notice")

            gated.value = false
            gate.open()
            await session.settle()

            XCTAssertTrue(session.textView.isEditable)
            XCTAssertNil(session.input?.noticeKey)
            XCTAssertEqual(session.input?.composition.isActive, false, "refused marked text must not replay")
            XCTAssertNil(session.textView.markedTextRange)
            XCTAssertEqual(session.surface.blocks.count, 1)

            // Once the seeded paragraph lands, composition works normally.
            session.textView.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
            XCTAssertEqual(session.input?.composition.isActive, true)
            XCTAssertNotNil(session.textView.markedTextRange)
            session.textView.unmarkText()
            await session.settle()
            XCTAssertNil(session.input?.noticeKey)
            XCTAssertEqual(session.surface.blocks[0].runs, [InlineRun("日本")])
        }
    }

    /// A seed requested on body focus while blocked by an in-flight barrier or
    /// `awaitsReset` is posted automatically by `drain()` once input is idle,
    /// and any held keys replay into the seeded paragraph.
    func testSeedBlockedByInFlightBarrierOrResyncIsPostedWhenDrainBecomesIdle() async throws {
        // 1. Blocked by an in-flight barrier (`undo()` barrier ahead of body focus).
        do {
            let gate = Latch()
            let gated = Locked(false)
            let session = try await NativeEditorSession.seed(
                state: Self.emptyUpdate,
                hooks: .init(beforeMessage: {
                    if gated.value { await gate.passing() }
                }))
            addTeardownBlock { await session.close().value }
            let writes = Locked(0)
            session.enableTyping(persist: { _, _ in writes.update { $0 += 1 } })
            session.setEditing(true)
            let unmount = mountInWindow(session.textView)
            defer {
                gated.value = false
                gate.open()
                unmount()
            }
            let input = try XCTUnwrap(session.input)

            gated.value = true
            XCTAssertTrue(input.undo(), "undo posts a barrier on the empty surface")
            await waitUntil { gate.waiting > 0 }
            // Body focus fires while the undo barrier occupies `barrier`.
            XCTAssertTrue(session.textView.becomeFirstResponder())
            input.typeKey("H")
            input.typeKey("i")
            XCTAssertEqual(writes.value, 0, "seed must wait until the in-flight barrier drains")

            gated.value = false
            gate.open()
            await session.settle()

            XCTAssertNil(input.noticeKey)
            XCTAssertEqual(session.surface.blocks.count, 1)
            XCTAssertEqual(session.surface.blocks[0].runs, [InlineRun("Hi")])
        }

        // 2. Blocked by `awaitsReset` (`requestResync()` ahead of body focus).
        do {
            let gate = Latch()
            let gated = Locked(false)
            let session = try await NativeEditorSession.seed(
                state: Self.emptyUpdate,
                hooks: .init(beforeMessage: {
                    if gated.value { await gate.passing() }
                }))
            addTeardownBlock { await session.close().value }
            let writes = Locked(0)
            session.enableTyping(persist: { _, _ in writes.update { $0 += 1 } })
            session.setEditing(true)
            let unmount = mountInWindow(session.textView)
            defer {
                gated.value = false
                gate.open()
                unmount()
            }
            let input = try XCTUnwrap(session.input)

            gated.value = true
            input.requestResync()
            await waitUntil { gate.waiting > 0 }
            XCTAssertTrue(session.textView.becomeFirstResponder())
            input.typeKey("O")
            input.typeKey("K")
            XCTAssertEqual(writes.value, 0, "seed must wait for awaitsReset to clear")

            gated.value = false
            gate.open()
            await session.settle()

            XCTAssertNil(input.noticeKey)
            XCTAssertEqual(session.surface.blocks.count, 1)
            XCTAssertEqual(session.surface.blocks[0].runs, [InlineRun("OK")])
        }
    }

    /// When a seed barrier goes `.stale` due to an epoch bump / resync, the
    /// seed retries automatically (when still empty) or yields cleanly (when
    /// remote content appeared), never shows `native_editor_input_unavailable`,
    /// and held typed text still lands.
    func testStaleSeedAfterEpochBumpRetriesAndTypedTextStillLands() async throws {
        // Subcase A: document stays empty across epoch bump -> seed goes .stale, retries, and "Hi" lands.
        do {
            let gate = Latch()
            let gated = Locked(false)
            let session = try await NativeEditorSession.seed(
                state: Self.emptyUpdate,
                hooks: .init(beforeMessage: {
                    if gated.value { await gate.passing() }
                }))
            addTeardownBlock { await session.close().value }
            session.enableTyping(persist: { _, _ in })
            session.setEditing(true)
            let unmount = mountInWindow(session.textView)
            defer {
                gated.value = false
                gate.open()
                unmount()
            }
            let input = try XCTUnwrap(session.input)
            let replica = try XCTUnwrap(session.replica)

            var sawStale = false
            session.onDelivery = { delivery in
                if case .stale? = delivery.result { sawStale = true }
            }

            // Hold a replica-side resync ahead of body focus so the seed sees an older epoch.
            gated.value = true
            XCTAssertTrue(replica.mailbox.post(.resync(surfaceID: session.surfaceID)))
            await waitUntil { gate.waiting > 0 }
            XCTAssertTrue(session.textView.becomeFirstResponder())
            input.typeKey("H")
            input.typeKey("i")

            gated.value = false
            gate.open()
            await session.settle()

            XCTAssertTrue(sawStale, "the seed barrier must have gone .stale across the epoch bump")
            XCTAssertNil(input.noticeKey, "retried stale seed must not show input unavailable")
            XCTAssertEqual(session.surface.blocks.count, 1)
            XCTAssertEqual(session.surface.blocks[0].runs, [InlineRun("Hi")])
        }

        // Subcase B: remote content arrives before the resync -> seed goes .stale while blocks now exist.
        do {
            let gate = Latch()
            let gated = Locked(false)
            let session = try await NativeEditorSession.seed(
                state: Self.emptyUpdate,
                hooks: .init(beforeMessage: {
                    if gated.value { await gate.passing() }
                }))
            addTeardownBlock { await session.close().value }
            let writes = Locked<[NativeEditCommand.Kind]>([])
            session.enableTyping(persist: { command, _ in writes.update { $0.append(command.kind) } })
            session.setEditing(true)
            let unmount = mountInWindow(session.textView)
            defer {
                gated.value = false
                gate.open()
                unmount()
            }
            let input = try XCTUnwrap(session.input)
            let replica = try XCTUnwrap(session.replica)

            var sawStale = false
            session.onDelivery = { delivery in
                if case .stale? = delivery.result { sawStale = true }
            }

            let remoteUpdate = BlockNoteYjs.encode(
                [
                    BlockNoteBlock(
                        node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("Peer")], id: "peer-1")
                ],
                clientID: 99)

            gated.value = true
            let integrateTask = Task { try await session.integrateServerState(remoteUpdate) }
            await waitUntil { gate.waiting > 0 }
            XCTAssertTrue(replica.mailbox.post(.resync(surfaceID: session.surfaceID)))
            XCTAssertTrue(session.textView.becomeFirstResponder())
            input.typeKey("Hi ")

            gated.value = false
            gate.open()
            try await integrateTask.value
            await session.settle()

            XCTAssertTrue(sawStale, "the seed barrier must have gone .stale across the resync")
            XCTAssertFalse(
                writes.value.contains {
                    if case .seedEmptyParagraph = $0 { true } else { false }
                },
                "must never write a seed once remote content appeared")
            XCTAssertNil(input.noticeKey, "stale seed after content appeared must never show an error notice")
            XCTAssertEqual(session.surface.blocks.map(\.id), ["peer-1"])
            XCTAssertEqual(session.surface.blocks[0].runs, [InlineRun("Hi Peer")])
            let rootGroupCount = await session.replicaDoc { doc -> Int in
                guard let root = doc.share[BlockNoteYjs.fragmentField] else { return 0 }
                return YBlockProjection.children(of: root, includeFormats: false).count
            }
            XCTAssertEqual(rootGroupCount, 1, "must never create a second blockGroup")
        }
    }

    /// If a remote update populates content before the queued seed command runs
    /// on the replica, the seed re-checks emptiness and settles as a no-op
    /// without refusing, showing a notice, or creating a duplicate `blockGroup`,
    /// and held typing lands cleanly in the existing block.
    func testConcurrentRemoteUpdateBeforeSeedSettlesAsNoOp() async throws {
        let gate = Latch()
        let gated = Locked(false)
        let session = try await NativeEditorSession.seed(
            state: Self.emptyUpdate,
            hooks: .init(beforeMessage: {
                if gated.value { await gate.passing() }
            }))
        addTeardownBlock { await session.close().value }
        let writes = Locked<[NativeEditCommand.Kind]>([])
        session.enableTyping(persist: { command, _ in writes.update { $0.append(command.kind) } })
        session.setEditing(true)
        let unmount = mountInWindow(session.textView)
        defer {
            gated.value = false
            gate.open()
            unmount()
        }
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
        // Body focus queues the seed while the surface still sees 0 blocks; typing is held behind it.
        XCTAssertTrue(session.textView.becomeFirstResponder())
        session.textView.insertText("Hi ")
        XCTAssertEqual(session.input?.hasInFlightWork, true, "seed barrier must be queued before remote settles")
        gated.value = false
        gate.open()
        try await integrateTask.value
        await session.settle()

        XCTAssertFalse(
            writes.value.contains {
                if case .seedEmptyParagraph = $0 { true } else { false }
            },
            "seed must settle as a no-op without journaling a seed")
        XCTAssertNil(session.input?.noticeKey)
        XCTAssertEqual(session.surface.blocks.map(\.id), ["peer-1"])
        XCTAssertEqual(session.surface.blocks[0].runs, [InlineRun("Hi From peer")])
        let rootGroupCount = await session.replicaDoc { doc -> Int in
            guard let root = doc.share[BlockNoteYjs.fragmentField] else { return 0 }
            return YBlockProjection.children(of: root, includeFormats: false).count
        }
        XCTAssertEqual(rootGroupCount, 1, "must never create a second blockGroup")
    }

    /// Read-only sessions (`inspect`, non-writable `seed`, or downgraded writable
    /// sessions) never seed an empty document, while a writable session seeds
    /// only when the body text view begins editing (not on `setEditing(true)`).
    func testReadOnlySessionsNeverSeedEmptyDocument() async throws {
        let inspected = try await NativeEditorSession.inspect(state: Self.emptyUpdate)
        addTeardownBlock { await inspected.close().value }
        let unmountInspected = mountInWindow(inspected.textView)
        inspected.setEditing(true)
        _ = inspected.textView.becomeFirstResponder()
        XCTAssertTrue(inspected.surface.blocks.isEmpty)
        XCTAssertFalse(inspected.textView.isEditable)
        unmountInspected()

        let readOnlyReplica = try await NativeEditorSession.seed(state: Self.emptyUpdate)
        addTeardownBlock { await readOnlyReplica.close().value }
        let unmountReadOnly = mountInWindow(readOnlyReplica.textView)
        XCTAssertTrue(readOnlyReplica.canType)
        XCTAssertFalse(readOnlyReplica.isWritable)
        readOnlyReplica.setEditing(true)
        _ = readOnlyReplica.textView.becomeFirstResponder()
        await readOnlyReplica.settle()
        XCTAssertTrue(readOnlyReplica.surface.blocks.isEmpty)
        XCTAssertFalse(readOnlyReplica.textView.isEditable)
        unmountReadOnly()

        let downgraded = try await NativeEditorSession.seed(state: Self.emptyUpdate)
        addTeardownBlock { await downgraded.close().value }
        let downgradedWrites = Locked(0)
        downgraded.enableTyping(persist: { _, _ in downgradedWrites.update { $0 += 1 } })
        downgraded.setExpectedWritable(false)
        let unmountDowngraded = mountInWindow(downgraded.textView)
        downgraded.setEditing(true)
        _ = downgraded.textView.becomeFirstResponder()
        XCTAssertEqual(downgraded.input?.seedEmptyParagraphIfNeeded(), false)
        await downgraded.settle()
        XCTAssertTrue(downgraded.surface.blocks.isEmpty)
        XCTAssertEqual(downgradedWrites.value, 0)
        XCTAssertFalse(downgraded.textView.isEditable)
        unmountDowngraded()

        // Control: writable session does NOT write on setEditing(true), DOES write on body focus.
        let writable = try await NativeEditorSession.seed(state: Self.emptyUpdate)
        addTeardownBlock { await writable.close().value }
        let writableWrites = Locked(0)
        writable.enableTyping(persist: { _, _ in writableWrites.update { $0 += 1 } })
        let unmountWritable = mountInWindow(writable.textView)
        defer { unmountWritable() }
        writable.setEditing(true)
        await writable.settle()
        XCTAssertTrue(writable.surface.blocks.isEmpty)
        XCTAssertEqual(writableWrites.value, 0, "entering editing alone must not write")

        XCTAssertTrue(writable.textView.becomeFirstResponder())
        await writable.settle()
        XCTAssertEqual(writable.surface.blocks.count, 1)
        XCTAssertEqual(writableWrites.value, 1, "body focus must seed exactly once")
    }

    /// When the last storage block is hidden (a folded toggle child or hidden
    /// completed checklist item), `closestPosition(to:)` clamps taps below the
    /// last visible line to the end of the last VISIBLE entry's text range
    /// rather than `endOfDocument - 1`, and double-tapping never selects hidden
    /// text. Existing clamping for attachment and code last blocks is preserved.
    func testClosestPositionClampsToLastVisibleBlockAndNeverSelectsHiddenText() async throws {
        let tapPoint = CGPoint(x: 80, y: 400)

        // 1. Folded toggle child as the last block in storage.
        let foldedHarness = try await makeHarness([
            BlockNoteBlock(
                node: "toggleListItem", props: Self.paragraphProps, runs: [InlineRun("Toggle heading")],
                id: "folded-toggle",
                children: [
                    BlockNoteBlock(
                        node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("Hidden secret")],
                        id: "folded-child")
                ])
        ])
        addTeardownBlock { await foldedHarness.close() }
        let unmountFolded = mountInWindow(foldedHarness.view)
        defer { unmountFolded() }

        XCTAssertFalse(foldedHarness.session.surface.isHidden(position: 0))
        XCTAssertTrue(foldedHarness.session.surface.isHidden(position: 1), "toggle child must start folded")
        let expectedEnd = NSMaxRange(foldedHarness.session.surface.rangeIndex.entries[0].textRange)

        let clamped = try XCTUnwrap(foldedHarness.view.closestPosition(to: tapPoint))
        XCTAssertEqual(
            foldedHarness.view.offset(from: foldedHarness.view.beginningOfDocument, to: clamped), expectedEnd,
            "tap below a folded toggle must land at the end of the last visible block, not inside the hidden child")

        let clampedEndOfDoc = foldedHarness.view.clampedClosestPosition(for: foldedHarness.view.endOfDocument)
        XCTAssertEqual(
            foldedHarness.view.offset(from: foldedHarness.view.beginningOfDocument, to: clampedEndOfDoc), expectedEnd,
            "clamping endOfDocument must land at the last visible block, never endOfDocument - 1 inside hidden text")

        foldedHarness.view.selectedRange = NSRange(location: 0, length: 0)
        foldedHarness.view.selectWordForDoubleTap(at: tapPoint)
        let selected = foldedHarness.view.selectedRange
        XCTAssertLessThanOrEqual(
            NSMaxRange(selected), expectedEnd, "double-tap below folded last block must never select hidden text")
        if selected.length > 0 {
            XCTAssertFalse(foldedHarness.session.surface.isHidden(atUTF16: selected.location))
            XCTAssertFalse(foldedHarness.session.surface.isHidden(atUTF16: NSMaxRange(selected) - 1))
        }
        unmountFolded()

        // 2. Hidden completed checklist item as the last block in storage.
        let checkHarness = try await makeHarness([
            BlockNoteBlock(
                node: "checkListItem", props: Self.paragraphProps + [("checked", .bool(false))],
                runs: [InlineRun("Visible task")], id: "check-open"),
            BlockNoteBlock(
                node: "checkListItem", props: Self.paragraphProps + [("checked", .bool(true))],
                runs: [InlineRun("Hidden done task")], id: "check-done"),
        ])
        addTeardownBlock { await checkHarness.close() }
        checkHarness.session.setEditing(false)
        _ = checkHarness.session.setChecklistPresentation(hidesCompleted: true, settlingIDs: [])
        let unmountCheck = mountInWindow(checkHarness.view)
        defer { unmountCheck() }

        XCTAssertTrue(checkHarness.session.surface.isHidden(position: 1))
        let checkEnd = NSMaxRange(checkHarness.session.surface.rangeIndex.entries[0].textRange)
        let checkPos = try XCTUnwrap(checkHarness.view.closestPosition(to: tapPoint))
        XCTAssertEqual(
            checkHarness.view.offset(from: checkHarness.view.beginningOfDocument, to: checkPos), checkEnd,
            "tap below hidden completed checklist item must clamp to the last visible checklist item")
        let checkClampedEnd = checkHarness.view.clampedClosestPosition(for: checkHarness.view.endOfDocument)
        XCTAssertEqual(
            checkHarness.view.offset(from: checkHarness.view.beginningOfDocument, to: checkClampedEnd), checkEnd,
            "clamping endOfDocument must skip hidden completed checklist items")
        unmountCheck()

        // 3. Code block as the last block keeps clamping to text end (endOfDocument - 1).
        let codeHarness = try await makeHarness([
            BlockNoteBlock(
                node: "codeBlock", props: [("language", .string("swift"))],
                runs: [InlineRun("let x = 1\nlet y = 2")], id: "code-last")
        ])
        addTeardownBlock { await codeHarness.close() }
        let unmountCode = mountInWindow(codeHarness.view)
        defer { unmountCode() }
        let codeEnd = NSMaxRange(codeHarness.session.surface.rangeIndex.entries[0].textRange)
        let codePos = try XCTUnwrap(codeHarness.view.closestPosition(to: tapPoint))
        XCTAssertEqual(codeHarness.view.offset(from: codeHarness.view.beginningOfDocument, to: codePos), codeEnd)
        unmountCode()

        // 4. Attachment (divider) as the last block keeps clamping to text end (endOfDocument - 1).
        let dividerHarness = try await makeHarness([
            BlockNoteBlock(node: "divider", props: [], runs: [], id: "divider-last")
        ])
        addTeardownBlock { await dividerHarness.close() }
        let unmountDivider = mountInWindow(dividerHarness.view)
        defer { unmountDivider() }
        let dividerEnd = NSMaxRange(dividerHarness.session.surface.rangeIndex.entries[0].textRange)
        let dividerPos = try XCTUnwrap(dividerHarness.view.closestPosition(to: tapPoint))
        XCTAssertEqual(
            dividerHarness.view.offset(from: dividerHarness.view.beginningOfDocument, to: dividerPos), dividerEnd)
    }

    /// Tapping the empty-document view only arms `requestBodyFocusWhenReady()`
    /// after editing has actually begun; if `onRequestEdit` refuses, no stale
    /// focus request remains to steal focus later.
    func testRefusedEmptyBodyTapDoesNotLeaveStaleBodyFocusRequest() async throws {
        let harness = try await makeHarness(state: Self.emptyUpdate)
        addTeardownBlock { await harness.close() }
        let session = harness.session
        session.setEditing(false)
        await harness.settle()

        // Refused edit request must NOT arm pendingBodyFocus.
        let refusingView = NativeEditorView(
            session: session, title: "Empty", serverOrigin: "https://example.test",
            externalIsEditing: false, onRequestEdit: {})
        refusingView.handleEmptyBodyTap()
        XCTAssertFalse(session.textView.isEditable)
        XCTAssertFalse(session.hasPendingBodyFocus, "refused edit request must not leave pendingBodyFocus armed")

        // Mounting the view and later entering editing (e.g. via title-focused flow) must not steal focus or seed.
        let unmount = mountInWindow(session.textView)
        defer { unmount() }
        session.setEditing(true)
        await harness.settle()
        XCTAssertFalse(session.textView.isFirstResponder, "refused empty-body tap must not later steal focus")
        XCTAssertTrue(session.surface.blocks.isEmpty, "entering editing without body focus must not seed")

        // Control: an accepted edit request arms body focus, focuses the empty textView when mounted, and seeds.
        session.setEditing(false)
        session.textView.removeFromSuperview()
        let acceptingView = NativeEditorView(
            session: session, title: "Empty", serverOrigin: "https://example.test",
            externalIsEditing: false, onRequestEdit: { session.setEditing(true) })
        acceptingView.handleEmptyBodyTap()
        XCTAssertTrue(session.textView.isEditable)
        XCTAssertTrue(session.hasPendingBodyFocus)

        let unmountAccepted = mountInWindow(session.textView)
        defer { unmountAccepted() }
        await harness.settle()
        XCTAssertTrue(session.textView.isFirstResponder, "accepted empty-body tap must focus the empty canvas")
        XCTAssertFalse(session.hasPendingBodyFocus)
        XCTAssertEqual(session.surface.blocks.count, 1, "accepted empty-body tap focuses body and seeds once")
    }

    /// When a stale seed's retry is deferred (`pendingSeed` set because input
    /// became busy/resetting during the drain), held keys are NOT dropped and
    /// `lastOutcome` is not failed; once the reset finishes, the deferred seed
    /// runs and the held keys land.
    func testStaleSeedWithDeferredRetryKeepsHeldKeysAndLands() async throws {
        let gate = Latch()
        let gated = Locked(false)
        let session = try await NativeEditorSession.seed(
            state: Self.emptyUpdate,
            hooks: .init(beforeMessage: {
                if gated.value { await gate.passing() }
            }))
        addTeardownBlock { await session.close().value }
        session.enableTyping(persist: { _, _ in })
        session.setEditing(true)
        let unmount = mountInWindow(session.textView)
        defer {
            gated.value = false
            gate.open()
            unmount()
        }
        let input = try XCTUnwrap(session.input)
        let replica = try XCTUnwrap(session.replica)
        input.resetOutcome()

        var sawStale = false
        session.onDelivery = { delivery in
            if case .stale? = delivery.result { sawStale = true }
        }

        // Queue: replica-side resync (epoch 0 -> 1), body-focus seed (epoch 0 -> .stale),
        // held keys, and two coordinator resyncs so `.stale` is queued while `resyncsAsked == 1`
        // and drains in the same batch as the second `.reset`. When that `.reset` patch applies,
        // trigger one more resync so the stale seed's retry sees `awaitsReset == true` and defers
        // via `pendingSeed` instead of dropping held keys.
        var deferredOnce = false
        let previousOnPatch = session.surface.onPatchApplied
        session.surface.onPatchApplied = { [weak input] patch in
            previousOnPatch?(patch)
            if !deferredOnce, sawStale {
                deferredOnce = true
                input?.requestResync()
            }
        }

        gated.value = true
        XCTAssertTrue(replica.mailbox.post(.resync(surfaceID: session.surfaceID)))
        await waitUntil { gate.waiting > 0 }
        XCTAssertTrue(session.textView.becomeFirstResponder())
        input.typeKey("H")
        input.typeKey("i")
        input.requestResync()
        input.requestResync()

        gated.value = false
        gate.open()
        await session.settle()

        XCTAssertTrue(sawStale, "the initial seed barrier must have gone .stale")
        XCTAssertTrue(deferredOnce, "the resync inside drain must have forced the stale retry to defer")
        XCTAssertNil(input.noticeKey, "a deferred stale seed retry must not show an error notice")
        XCTAssertNotEqual(input.lastOutcome, false, "a deferred stale seed retry must not fail lastOutcome")
        XCTAssertEqual(session.surface.blocks.count, 1)
        XCTAssertEqual(session.surface.blocks[0].runs, [InlineRun("Hi")])
    }

    /// A refused seed on a still-empty document shows `native_editor_input_unavailable`
    /// when held keys were dropped, and stays quiet when no held input was lost.
    func testRefusedSeedWithHeldKeysShowsNoticeAndWithoutHeldKeysStaysQuiet() async throws {
        // 1. Refused seed with held keys -> noticeKey == .native_editor_input_unavailable.
        do {
            let gate = Latch()
            let gated = Locked(false)
            let session = try await NativeEditorSession.seed(
                state: Self.emptyUpdate,
                hooks: .init(beforeMessage: {
                    if gated.value { await gate.passing() }
                }))
            addTeardownBlock { await session.close().value }
            session.enableTyping(persist: { _, _ in })
            session.setEditing(true)
            let unmount = mountInWindow(session.textView)
            defer {
                gated.value = false
                gate.open()
                unmount()
            }
            let input = try XCTUnwrap(session.input)
            let replica = try XCTUnwrap(session.replica)

            gated.value = true
            XCTAssertTrue(replica.mailbox.post(.setWritable(nil)))
            await waitUntil { gate.waiting > 0 }
            XCTAssertTrue(session.textView.becomeFirstResponder())
            input.typeKey("L")
            input.typeKey("o")

            gated.value = false
            gate.open()
            await session.settle()

            XCTAssertTrue(session.surface.blocks.isEmpty)
            XCTAssertEqual(
                input.noticeKey, .native_editor_input_unavailable,
                "dropping held keys on a refused empty-doc seed must surface input unavailable")
        }

        // 2. Refused seed with NO held keys -> no spurious notice.
        do {
            let gate = Latch()
            let gated = Locked(false)
            let session = try await NativeEditorSession.seed(
                state: Self.emptyUpdate,
                hooks: .init(beforeMessage: {
                    if gated.value { await gate.passing() }
                }))
            addTeardownBlock { await session.close().value }
            session.enableTyping(persist: { _, _ in })
            session.setEditing(true)
            let unmount = mountInWindow(session.textView)
            defer {
                gated.value = false
                gate.open()
                unmount()
            }
            let input = try XCTUnwrap(session.input)
            let replica = try XCTUnwrap(session.replica)

            gated.value = true
            XCTAssertTrue(replica.mailbox.post(.setWritable(nil)))
            await waitUntil { gate.waiting > 0 }
            XCTAssertTrue(session.textView.becomeFirstResponder())

            gated.value = false
            gate.open()
            await session.settle()

            XCTAssertTrue(session.surface.blocks.isEmpty)
            XCTAssertNil(input.noticeKey, "refused empty-doc seed with no held keys must not show a notice")
        }
    }

    /// Redoing a history step on an emptied document restores the step's saved
    /// selection instead of clobbering it back to offset 0 of the first block.
    func testRedoOnEmptiedDocumentKeepsRestoredSelection() async throws {
        let initial = BlockNoteYjs.encode(
            [
                BlockNoteBlock(
                    node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("Hello")], id: "p1")
            ],
            clientID: 1)
        let harness = try await makeHarness(state: initial)
        addTeardownBlock { await harness.close() }
        let session = harness.session
        session.setEditing(true)
        let unmount = mountInWindow(harness.view)
        defer { unmount() }

        // Paste multi-block text as one undoable step so redo restores the pasted blocks with caret at the end.
        let board = try XCTUnwrap(UIPasteboard(name: UIPasteboard.Name("redo-empty-\(UUID())"), create: true))
        defer { UIPasteboard.remove(withName: board.name) }
        harness.input.pasteboard = board
        board.string = "First\n\nSecond"
        harness.view.selectedRange = NSRange(location: 5, length: 0)
        XCTAssertTrue(harness.input.pasteFromPasteboard())
        await harness.settle()
        XCTAssertGreaterThan(session.surface.blocks.count, 1)
        let expectedRunsAfterDelete = Array(session.surface.blocks.dropFirst().map(\.runs))

        // Remote peer deletes the original first block, leaving only the locally pasted block(s).
        let peerDoc = YDoc(clientID: 99)
        defer { peerDoc.destroy() }
        try peerDoc.applyUpdate(YUpdateDecoder.decode(initial), origin: .remote)
        let deleteFirstUpdate = try BlockNoteWriter(doc: peerDoc).transaction(origin: .remote) { tx in
            guard let root = peerDoc.share[BlockNoteYjs.fragmentField],
                let firstChild = YBlockProjection.children(of: root, includeFormats: false).first,
                case .type(let group) = firstChild.content
            else { return XCTFail("Expected blockGroup in peer doc") }
            try YWrite.delete(tx, from: group, at: 0, length: 1)
        }
        try await session.integrateServerState(deleteFirstUpdate)
        XCTAssertEqual(session.surface.blocks.map(\.runs), expectedRunsAfterDelete)
        let expectedRestoredRange = harness.view.selectedRange
        XCTAssertGreaterThan(expectedRestoredRange.location, 0, "selection before undo must be past offset 0")

        // Undo removes the locally pasted block(s), emptying the document while keeping redo available.
        let undone = await harness.run { harness.input.undo() }
        XCTAssertTrue(undone)
        XCTAssertTrue(session.surface.blocks.isEmpty, "undoing the only remaining local blocks empties the doc")
        XCTAssertTrue(harness.input.history.canRedo)

        // Redo brings the blocks back; applyNow must NOT overwrite history's restored caret back to 0.
        let redone = await harness.run { harness.input.redo() }
        XCTAssertTrue(redone)
        XCTAssertEqual(session.surface.blocks.map(\.runs), expectedRunsAfterDelete)
        XCTAssertEqual(
            harness.view.selectedRange, expectedRestoredRange,
            "redo on an emptied doc must preserve history's restored caret rather than resetting to 0")
    }

    /// Fulfilling a pending body focus after a remote `[image, paragraph]`
    /// update places the caret in the paragraph, not the leading image placeholder.
    func testBodyFocusAfterRemoteImageAndParagraphPlacesCaretInParagraph() async throws {
        let harness = try await makeHarness(state: Self.emptyUpdate)
        addTeardownBlock { await harness.close() }
        let session = harness.session
        session.setEditing(false)
        await harness.settle()

        let remoteUpdate = BlockNoteYjs.encode(
            [
                BlockNoteBlock(
                    node: "image", props: [("url", .string("/media/photo.png"))], runs: [], id: "img-1"),
                BlockNoteBlock(
                    node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("Body")], id: "para-1"),
            ],
            clientID: 99)
        try await session.integrateServerState(remoteUpdate)
        XCTAssertEqual(session.surface.blocks.map(\.node), ["image", "paragraph"])
        let paraEntry = try XCTUnwrap(session.surface.rangeIndex.entry(for: "para-1"))
        XCTAssertGreaterThan(paraEntry.textRange.location, 0)

        // Enter editing and arm body focus before mounting in a window; caret starts at 0 (the image).
        session.textView.selectedRange = NSRange(location: 0, length: 0)
        session.setEditing(true)
        session.requestBodyFocusWhenReady()
        XCTAssertTrue(session.hasPendingBodyFocus)

        let unmount = mountInWindow(session.textView)
        defer { unmount() }
        await harness.settle()

        XCTAssertTrue(session.textView.isFirstResponder)
        XCTAssertFalse(session.hasPendingBodyFocus)
        XCTAssertEqual(
            session.textView.selectedRange, NSRange(location: paraEntry.textRange.location, length: 0),
            "body focus must skip the leading image placeholder and place the caret in the paragraph")

        session.textView.insertText("Hi ")
        await harness.settle()
        XCTAssertEqual(session.surface.blocks[1].runs, [InlineRun("Hi Body")])
    }

    /// Keys typed while a body-focus seed is deferred (e.g. behind an in-flight
    /// resync) still seed a paragraph and land cleanly even if the user blurs
    /// the body before input becomes idle.
    func testBlurringBodyWhileSeedIsDeferredStillSeedsAndReplaysHeldKeys() async throws {
        let gate = Latch()
        let gated = Locked(false)
        let session = try await NativeEditorSession.seed(
            state: Self.emptyUpdate,
            hooks: .init(beforeMessage: {
                if gated.value { await gate.passing() }
            }))
        addTeardownBlock { await session.close().value }
        session.enableTyping(persist: { _, _ in })
        session.setEditing(true)
        let unmount = mountInWindow(session.textView)
        defer {
            gated.value = false
            gate.open()
            unmount()
        }
        let input = try XCTUnwrap(session.input)

        gated.value = true
        input.requestResync()
        await waitUntil { gate.waiting > 0 }
        XCTAssertTrue(session.textView.becomeFirstResponder())
        input.typeKey("H")
        input.typeKey("i")
        XCTAssertTrue(session.textView.resignFirstResponder())

        gated.value = false
        gate.open()
        await session.settle()

        XCTAssertNil(input.noticeKey)
        XCTAssertEqual(session.surface.blocks.count, 1)
        XCTAssertEqual(session.surface.blocks.first?.runs, [InlineRun("Hi")])
    }

    /// When a delivery turns a session read-only while `pendingBodyFocus` is
    /// armed before the view enters a window, the pending request is cleared so
    /// later editing or mounting never steals focus.
    func testReadOnlyDeliveryClearsPendingBodyFocusRequest() async throws {
        let session = try await NativeEditorSession.seed(state: Self.emptyUpdate)
        addTeardownBlock { await session.close().value }
        session.enableTyping(persist: { _, _ in })
        await session.settle()
        let replica = try XCTUnwrap(session.replica)

        session.setEditing(true)
        session.requestBodyFocusWhenReady()
        XCTAssertTrue(session.hasPendingBodyFocus)

        // A replica delivery turns the session read-only before the view mounts.
        XCTAssertTrue(replica.mailbox.post(.setWritable(nil)))
        await session.settle()
        XCTAssertFalse(session.isWritable)
        XCTAssertFalse(session.textView.isEditable)
        XCTAssertFalse(session.hasPendingBodyFocus, "read-only delivery must clear pendingBodyFocus")

        // Restoring writability, entering editing, and mounting in a window must not steal focus.
        XCTAssertTrue(replica.mailbox.post(.setWritable({ _, _ in })))
        await session.settle()
        session.setEditing(true)
        let unmount = mountInWindow(session.textView)
        defer { unmount() }
        await session.settle()

        XCTAssertFalse(session.textView.isFirstResponder, "cleared body-focus request must not later steal focus")
        XCTAssertTrue(session.surface.blocks.isEmpty)
    }
}
