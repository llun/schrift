import UIKit
import XCTest

@testable import Schrift

@MainActor
final class NativeTypingTests: DocumentEngineTestCase {
    private enum DiskError: Error { case full }

    private func session(_ blocks: [BlockNoteBlock] = seedBlocks()) async throws -> NativeEditorSession {
        let session = try await NativeEditorSession.seed(
            state: BlockNoteYjs.encode(blocks, clientID: Self.seedClientID))
        addTeardownBlock { await session.close().value }
        return session
    }

    private func assertMatches(_ session: NativeEditorSession, file: StaticString = #filePath, line: UInt = #line) {
        let fresh = AttributedDocumentProjection.attributedString(
            blocks: session.surface.blocks, traits: session.surface.traits, labels: session.surface.labels)
        XCTAssertTrue(session.textView.textStorage.isEqual(to: fresh), file: file, line: line)
        XCTAssertEqual(
            session.surface.rangeIndex.entries,
            ProjectionRangeIndex(blocks: session.surface.blocks, labels: session.surface.labels).entries,
            file: file, line: line)
    }

    /// Option A (PR08b): typing is shown at once and journaled in order after
    /// it; the canonical revision (publication) advances only on the journaled
    /// result.
    func testOrdinaryEditsReconcileOnceAndAreDurableBeforePublication() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = ReplicaScope(
            serverOrigin: "https://example.test", ownerUserID: UUID(), org: "docs", documentID: UUID())
        let store = ReplicaStore(directory: directory)
        let state = BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID)
        _ = try store.create(for: scope, checkpoint: state)
        let session = try await NativeEditorSession.seed(state: state)
        addTeardownBlock { await session.close().value }
        let revisions = Locked<[UInt64]>([])
        let commands = Locked<[NativeEditCommand]>([])
        session.enableTyping(persist: { [weak session] command, bytes in
            // The canonical revision the display shows has not advanced yet.
            revisions.update {
                $0.append(DispatchQueue.main.sync { MainActor.assumeIsolated { session?.revision ?? .max } })
            }
            commands.update { $0.append(command) }
            try store.append(
                bytes, for: scope, commandID: command.id, baseRevision: command.baseRevision, origin: .local)
        })
        let input = try XCTUnwrap(session.input)
        let engineProjected = await session.engine { $0.projectedBlockCount }
        let engineVisited = await session.engine { $0.visitedEntryCount }
        for (range, text) in [
            (NSRange(location: 0, length: 0), "a"), (NSRange(location: 0, length: 0), "b"),
            (NSRange(location: 1, length: 1), "😀"), (NSRange(location: 1, length: 2), ""),
        ] {
            XCTAssertTrue(input.replace(range: range, with: text))
            await session.settle()
            assertMatches(session)
            let restored = try XCTUnwrap(store.restore(for: scope))
            let replica = YDoc(clientID: 99)
            defer { replica.destroy() }
            try replica.applyUpdate(YUpdateDecoder.decode(restored.checkpoint), origin: .remote)
            for update in restored.updates { try replica.applyUpdate(YUpdateDecoder.decode(update), origin: .remote) }
            XCTAssertEqual(session.surface.blocks, projection(replica))
        }
        XCTAssertEqual(revisions.value, [0, 1, 2, 3], "each journal append precedes its publication")
        XCTAssertEqual(commands.value.map(\.baseRevision), [0, 1, 2, 3])
        XCTAssertEqual(Set(commands.value.map(\.id)).count, 4)
        let projected = await session.engine { $0.projectedBlockCount }
        let visited = await session.engine { $0.visitedEntryCount }
        XCTAssertEqual(projected, engineProjected, "ordinary typing uses text deltas")
        XCTAssertEqual(visited.map { $0 - (engineVisited ?? 0) }, 4, "only the touched index entry is visited")
    }

    func testDuplicateEchoIsIgnoredButOtherRebuildAndUntaggedLocalPatchesWin() async throws {
        let session = try await session()
        let recording = PatchLog(session)
        session.enableTyping(persist: { _, _ in })
        XCTAssertTrue(try XCTUnwrap(session.input).replace(range: NSRange(location: 0, length: 0), with: "x"))
        await session.settle()
        let echo = try XCTUnwrap(recording.patches.last)
        XCTAssertNotNil(echo.nativeCommand)
        let expected = session.textView.textStorage.string
        session.surface.applyPatch(echo)
        XCTAssertEqual(session.textView.textStorage.string, expected)
        let surface = NativeTextSurface(blocks: session.surface.blocks, storage: NativeTextView().textStorage)
        surface.applyPatch(
            BlockPatch(
                [.replaceBlock(blockID: Self.firstID, block: session.surface.blocks[0])],
                origin: .localUser, nativeCommand: echo.nativeCommand))
        var rebuilt = session.surface.blocks[0]
        rebuilt.runs = [InlineRun("authoritative", marks: [("bold", "{}")])]
        surface.applyPatch(
            BlockPatch(
                [.replaceBlock(blockID: rebuilt.id, block: rebuilt)], origin: .other,
                nativeCommand: echo.nativeCommand))
        XCTAssertEqual(surface.blocks[0], rebuilt)
        surface.applyPatch(
            BlockPatch(
                [
                    .text(
                        blockID: rebuilt.id,
                        deltas: [TextDelta(range: 0..<0, replacement: "y", marks: [])])
                ], origin: .localUser))
        XCTAssertEqual(surface.blocks[0].runs.map(\.text).joined(), "yauthoritative")
        XCTAssertTrue(
            surface.storage.isEqual(
                to: AttributedDocumentProjection.attributedString(
                    blocks: surface.blocks, traits: surface.traits, labels: surface.labels)))
    }

    func testMultipleEmissionsOfOneCommandAreNotConfusedWithDuplicateEchoes() async throws {
        let session = try await session()
        let view = NativeTextView()
        let surface = NativeTextSurface(blocks: session.surface.blocks, storage: view.textStorage)
        let id = UUID()
        for emission in 0..<2 {
            let patch = BlockPatch(
                [
                    .text(
                        blockID: Self.firstID,
                        deltas: [TextDelta(range: 0..<0, replacement: "a", marks: [])])
                ], origin: .localUser,
                nativeCommand: NativePatchStamp(commandID: id, baseRevision: 0, emission: emission))
            surface.applyPatch(patch)
            surface.applyPatch(patch)
        }
        XCTAssertEqual(surface.blocks[0].runs.map(\.text).joined(), "aaFirst paragraph.")
        let patch = BlockPatch(
            [
                .text(
                    blockID: Self.firstID,
                    deltas: [TextDelta(range: 0..<0, replacement: "z", marks: [])])
            ], origin: .localUser,
            nativeCommand: NativePatchStamp(commandID: UUID(), baseRevision: 1, emission: 0))
        surface.applyPatch(patch)
        let expected = view.textStorage.string
        surface.applyPatch(patch)
        XCTAssertEqual(view.textStorage.string, expected)
    }

    /// Newlines and ranges across separators are range commands since PR04b
    /// (`NativeRangeCommandTests`); object characters, invalid ranges and
    /// surrogate splits stay refused.
    func testObjectCharactersInvalidRangesAndSurrogateSplitsAreRefusedBeforeMutation() async throws {
        let session = try await session()
        let writes = Locked(0)
        session.enableTyping(persist: { _, _ in writes.update { $0 += 1 } })
        let input = try XCTUnwrap(session.input)
        let original = session.textView.textStorage.string
        let first = try XCTUnwrap(session.surface.rangeIndex.entry(for: Self.firstID))
        for (range, replacement) in [
            (NSRange(location: 0, length: 0), "\u{fffc}"), (first.separatorRange, "\u{fffc}"),
            (NSRange(location: 0, length: 0), "a\u{fffc}\nb"),
            (NSRange(location: -1, length: 0), "x"), (NSRange(location: 0, length: Int.max), "x"),
        ] {
            let taken = await session.run { input.replace(range: range, with: replacement) }
            XCTAssertFalse(taken)
            XCTAssertEqual(session.textView.textStorage.string, original)
        }
        XCTAssertEqual(writes.value, 0)
        let revision = await session.engine { $0.revision }
        let failed = await session.engine { $0.nativeWriteFailed }
        XCTAssertEqual(revision, 0)
        XCTAssertEqual(failed, false)
        let typed = await session.run { input.replace(range: NSRange(location: 0, length: 0), with: "😀") }
        XCTAssertTrue(typed)
        let before = session.textView.textStorage.string
        let split = await session.run { input.replace(range: NSRange(location: 1, length: 0), with: "x") }
        XCTAssertFalse(split)
        XCTAssertEqual(session.textView.textStorage.string, before)
        XCTAssertEqual(writes.value, 1)
    }

    func testOpaqueAndPlaceholderBlocksAndDuplicateIDsAreReadOnly() async throws {
        let blocks = [
            BlockNoteBlock(node: "table", props: [], runs: [], id: "table"),
            // A toggle heading is a native block since PR06b; an unknown node is not.
            BlockNoteBlock(node: "futureBlock", props: [], runs: [InlineRun("future")], id: "future"),
        ]
        let session = try await session(blocks)
        let writes = Locked(0)
        session.enableTyping(persist: { _, _ in writes.update { $0 += 1 } })
        let input = try XCTUnwrap(session.input)
        for entry in session.surface.rangeIndex.entries {
            let taken = await session.run {
                input.replace(range: NSRange(location: entry.range.location, length: 0), with: "x")
            }
            XCTAssertFalse(taken)
        }
        XCTAssertEqual(writes.value, 0)
        let duplicate = try await self.session([Self.seedBlocks()[0], Self.seedBlocks()[0]])
        duplicate.enableTyping(persist: { _, _ in XCTFail("duplicate IDs must not become edit targets") })
        let duplicateInput = try XCTUnwrap(duplicate.input)
        let taken = await duplicate.run { duplicateInput.replace(range: NSRange(location: 0, length: 0), with: "x") }
        XCTAssertFalse(taken)
    }

    func testUnsupportedMarkedTextKeepsTheReadOnlyRefusalAndUndoIsDisabled() async throws {
        let session = try await session()
        session.enableTyping(persist: { _, _ in XCTFail("marked text must never become a write") })
        let original = session.textView.attributedText
        // A cross-block selection is not a supported composition (PR03).
        let first = try XCTUnwrap(session.surface.rangeIndex.entry(for: Self.firstID))
        let second = try XCTUnwrap(session.surface.rangeIndex.entry(for: Self.secondID))
        session.textView.selectedRange = NSRange(
            location: first.textRange.location + 10,
            length: second.textRange.location + 5 - first.textRange.location - 10)
        session.textView.setMarkedText("仮", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertEqual(session.input?.noticeKey, .native_editor_marked_unavailable)
        XCTAssertNil(session.textView.markedTextRange)
        XCTAssertFalse(session.textView.isEditable)
        XCTAssertTrue(session.textView.attributedText.isEqual(to: try XCTUnwrap(original)))
        let revision = await session.engine { $0.revision }
        XCTAssertEqual(revision, 0)
        // PR07b: the history exists, but a refused (read-only) editor offers no step.
        XCTAssertFalse(try XCTUnwrap(session.textView.undoManager).canUndo)
        XCTAssertFalse(session.textView.canPerformAction(NSSelectorFromString("undo:"), withSender: nil))
    }

    func testReplacementInsideMarkedRunPreservesAuthoritativeAttributes() async throws {
        let session = try await session()
        session.enableTyping(persist: { _, _ in })
        let entry = try XCTUnwrap(session.surface.rangeIndex.entry(for: Self.secondID))
        let offset = entry.textRange.location + "Second paragraph has ".utf16.count + 1
        XCTAssertTrue(try XCTUnwrap(session.input).replace(range: NSRange(location: offset, length: 2), with: "X"))
        await session.settle()
        let snapshot = await session.engine { $0.nativeSnapshot(for: Self.secondID) }
        let projected = try XCTUnwrap(snapshot ?? nil)
        XCTAssertEqual(session.surface.blocks[1], projected)
        XCTAssertTrue(
            try XCTUnwrap(session.textView.textStorage.attribute(.font, at: offset, effectiveRange: nil) as? UIFont)
                .fontDescriptor.symbolicTraits.contains(.traitBold))
        assertMatches(session)
    }

    /// The keystroke was shown (option A); the failed append rolls it back to
    /// canonical, freezes authoring and keeps the text as a recovery entry.
    func testFailedAppendStopsWritesAndRetainsUnconfirmedBytesWithoutPublishingEcho() async throws {
        let session = try await session()
        session.enableTyping(persist: { _, _ in throw DiskError.full })
        let original = session.textView.textStorage.string
        let input = try XCTUnwrap(session.input)
        let taken = await session.run { input.replace(range: NSRange(location: 0, length: 0), with: "x") }
        XCTAssertFalse(taken)
        XCTAssertEqual(session.textView.textStorage.string, original)
        XCTAssertEqual(session.input?.noticeKey, .native_editor_storage_failed)
        XCTAssertFalse(session.textView.isEditable)
        XCTAssertEqual(input.composition.pendingRecoveries.map(\.text), ["x"], "the dropped text is recoverable")
        let unconfirmed = await session.engine { $0.unconfirmedNativeUpdate != nil }
        let failed = await session.engine { $0.nativeWriteFailed }
        XCTAssertEqual(unconfirmed, true)
        XCTAssertEqual(failed, true)
        let refused = await session.engine { engine in
            (try? engine.replaceText(block: Self.firstID, range: 0..<0, with: "retry")) == nil
                && (try? engine.compositionBegan(blockID: Self.firstID, at: 0)) == nil
        }
        XCTAssertEqual(refused, true)
    }

    func testStaleCommandIsRefusedWithoutCallingPersistenceOrMutating() async throws {
        let session = try await session()
        let original = session.textView.textStorage.string
        let command = NativeEditCommand(
            id: UUID(), baseRevision: 1, blockID: Self.firstID, range: 0..<0, replacement: "x")
        let error = await session.engine { engine -> DocumentEngineError? in
            do {
                try engine.replaceText(command) { _ in XCTFail("stale command") }
                return nil
            } catch {
                return error as? DocumentEngineError
            }
        }
        XCTAssertEqual(error, .staleNativeCommand)
        await session.settle()
        XCTAssertEqual(session.textView.textStorage.string, original)
        let failed = await session.engine { $0.nativeWriteFailed }
        XCTAssertEqual(failed, false)
    }

    func testUIKitInsertAndDeleteAreInterceptedOnce() async throws {
        let session = try await session()
        let writes = Locked(0)
        session.enableTyping(persist: { _, _ in writes.update { $0 += 1 } })
        XCTAssertFalse(try XCTUnwrap(session.input).replace(range: NSRange(location: 0, length: 0), with: ""))
        await session.settle()
        XCTAssertEqual(writes.value, 0)
        session.textView.selectedRange = NSRange(location: 0, length: 0)
        session.textView.insertText("x")
        XCTAssertEqual(session.surface.blocks[0].runs.map(\.text).joined(), "xFirst paragraph.", "shown at once")
        await session.settle()
        XCTAssertEqual(writes.value, 1)
        assertMatches(session)
        session.textView.selectedRange = NSRange(location: 1, length: 0)
        session.textView.deleteBackward()
        XCTAssertEqual(session.surface.blocks[0].runs.map(\.text).joined(), "First paragraph.")
        await session.settle()
        XCTAssertEqual(writes.value, 2)
        assertMatches(session)
        session.textView.selectedRange = NSRange(location: 0, length: 0)
        session.textView.deleteBackward()
        await session.settle()
        XCTAssertEqual(writes.value, 2, "Backspace at the document boundary cannot mutate another block")
        let start = session.textView.beginningOfDocument
        let end = try XCTUnwrap(session.textView.position(from: start, offset: 1))
        let range = try XCTUnwrap(session.textView.textRange(from: start, to: end))
        session.textView.replace(range, withText: "Z")
        XCTAssertEqual(session.surface.blocks[0].runs.map(\.text).joined(), "Zirst paragraph.")
        await session.settle()
        XCTAssertEqual(writes.value, 3)
        assertMatches(session)
    }

    func testBackspaceAtTheFirstBlockIsQuietAndAtTheDocumentEndShowsANotice() async throws {
        let session = try await session()
        let writes = Locked(0)
        session.enableTyping(persist: { _, _ in writes.update { $0 += 1 } })
        let input = try XCTUnwrap(session.input)
        let original = session.textView.textStorage.string
        // The first block has nothing above it: a quiet no-op, not an error.
        session.textView.selectedRange = NSRange(location: 0, length: 0)
        session.textView.deleteBackward()
        await session.settle()
        XCTAssertEqual(session.textView.textStorage.string, original)
        XCTAssertEqual(writes.value, 0)
        XCTAssertNil(input.noticeKey)
        XCTAssertTrue(session.textView.isEditable)
        // The end-of-document caret sits after the last separator, which no block owns:
        // Backspace there is refused with a notice, like typing there, never swallowed.
        session.textView.selectedRange = NSRange(location: session.textView.textStorage.length, length: 0)
        session.textView.deleteBackward()
        await session.settle()
        XCTAssertEqual(session.textView.textStorage.string, original)
        XCTAssertEqual(writes.value, 0)
        XCTAssertEqual(input.noticeKey, .native_editor_input_unavailable)
    }

    /// PR05a: a mark this build does not know is kept in the snapshot and the
    /// replica (the native save writes raw Yjs), so its block stays typeable
    /// and an edit beside it never drops it. Typing does not extend it.
    func testUnknownMarksStayTypeableAndStored() async throws {
        let session = try await session([
            BlockNoteBlock(
                node: "paragraph", props: Self.paragraphProps,
                runs: [InlineRun("future", marks: [("unknown-extension", "{}")])], id: Self.firstID)
        ])
        let writes = Locked(0)
        session.enableTyping(persist: { _, _ in writes.update { $0 += 1 } })
        XCTAssertTrue(try XCTUnwrap(session.input).replace(range: NSRange(location: 0, length: 0), with: "x"))
        await session.settle()
        XCTAssertEqual(writes.value, 1)
        XCTAssertEqual(session.surface.blocks.first?.runs.map(\.text), ["x", "future"])
        XCTAssertEqual(session.surface.blocks.first?.runs.last?.marks.map(\.key), ["unknown-extension"])
        let failed = await session.engine { $0.nativeWriteFailed }
        XCTAssertEqual(failed, false)
    }

    func testDisjointUIKitRangesAreRefusedInsteadOfReplacingTheirUnion() async throws {
        let session = try await session()
        session.enableTyping(persist: { _, _ in XCTFail("disjoint replacements must not write") })
        let original = session.textView.textStorage.string
        let input = try XCTUnwrap(session.input)
        XCTAssertFalse(
            input.textView(
                session.textView,
                shouldChangeTextInRanges: [
                    NSValue(range: NSRange(location: 0, length: 1)), NSValue(range: NSRange(location: 3, length: 1)),
                ], replacementText: "x"))
        XCTAssertFalse(input.textView(session.textView, shouldChangeTextInRanges: [], replacementText: "x"))
        await session.settle()
        XCTAssertEqual(session.textView.textStorage.string, original)
        let revision = await session.engine { $0.revision }
        XCTAssertEqual(revision, 0)
    }

    func testKeystrokeWorkDoesNotProjectOrEncodeTheWholeLargeDocument() async throws {
        let blocks = (0..<5_000).map { index in
            BlockNoteBlock(
                node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("Paragraph \(index)")],
                id: "block-\(index)")
        }
        let session = try await session(blocks)
        let update = Locked<Data?>(nil)
        session.enableTyping(persist: { _, bytes in update.value = bytes })
        let counters: @Sendable (DocumentEngine) -> [Int] = {
            [$0.projectedBlockCount, $0.visitedEntryCount, $0.nativeSnapshotCount]
        }
        let counted = await session.engine(counters)
        let before = try XCTUnwrap(counted)
        let entry = try XCTUnwrap(session.surface.rangeIndex.entry(for: "block-2500"))
        XCTAssertTrue(
            try XCTUnwrap(session.input).replace(
                range: NSRange(location: entry.textRange.location, length: 0), with: "x"))
        await session.settle()
        let recounted = await session.engine(counters)
        let after = try XCTUnwrap(recounted)
        XCTAssertEqual(after[0] - before[0], 0)
        XCTAssertEqual(after[1] - before[1], 1)
        XCTAssertEqual(after[2] - before[2], 1)
        XCTAssertLessThan(try XCTUnwrap(update.value).count, 100, "only the local incremental update is encoded")
        XCTAssertEqual(session.surface.blocks[2_500].runs.map(\.text).joined(), "xParagraph 2500")
        assertMatches(session)
    }
}
