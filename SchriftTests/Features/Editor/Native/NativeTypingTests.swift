import UIKit
import XCTest

@testable import Schrift

@MainActor
final class NativeTypingTests: DocumentEngineTestCase {
    private enum DiskError: Error { case full }

    private func session(_ blocks: [BlockNoteBlock] = seedBlocks()) throws -> NativeEditorSession {
        try NativeEditorSession(state: BlockNoteYjs.encode(blocks, clientID: Self.seedClientID))
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

    func testOrdinaryEditsReconcileOnceAndAreDurableBeforePublication() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = ReplicaScope(
            serverOrigin: "https://example.test", ownerUserID: UUID(), org: "docs", documentID: UUID())
        let store = ReplicaStore(directory: directory)
        let state = BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID)
        _ = try store.create(for: scope, checkpoint: state)
        let session = try NativeEditorSession(state: state)
        defer { session.close() }
        var expectedBefore = session.textView.textStorage.string
        var commands: [NativeEditCommand] = []
        session.enableTyping { command, bytes in
            XCTAssertEqual(session.textView.textStorage.string, expectedBefore, "echo waits for the journal")
            XCTAssertThrowsError(try session.engine.replaceText(block: Self.firstID, range: 0..<0, with: "reentrant"))
            commands.append(command)
            try store.append(
                bytes, for: scope, commandID: command.id, baseRevision: command.baseRevision, origin: .local)
        }
        let input = try XCTUnwrap(session.input)
        let engineProjected = session.engine.projectedBlockCount
        let engineVisited = session.engine.visitedEntryCount
        for (range, text) in [
            (NSRange(location: 0, length: 0), "a"), (NSRange(location: 0, length: 0), "b"),
            (NSRange(location: 1, length: 1), "😀"), (NSRange(location: 1, length: 2), ""),
        ] {
            XCTAssertTrue(input.replace(range: range, with: text))
            assertMatches(session)
            let restored = try XCTUnwrap(store.restore(for: scope))
            let replica = YDoc(clientID: 99)
            defer { replica.destroy() }
            try replica.applyUpdate(YUpdateDecoder.decode(restored.checkpoint), origin: .remote)
            for update in restored.updates { try replica.applyUpdate(YUpdateDecoder.decode(update), origin: .remote) }
            XCTAssertEqual(session.surface.blocks, projection(replica))
            expectedBefore = session.textView.textStorage.string
        }
        XCTAssertEqual(commands.map(\.baseRevision), [0, 1, 2, 3])
        XCTAssertEqual(Set(commands.map(\.id)).count, 4)
        XCTAssertEqual(session.engine.projectedBlockCount, engineProjected, "ordinary typing uses text deltas")
        XCTAssertEqual(session.engine.visitedEntryCount - engineVisited, 4, "only the touched index entry is visited")
    }

    func testDuplicateEchoIsIgnoredButOtherRebuildAndUntaggedLocalPatchesWin() throws {
        let session = try session()
        defer { session.close() }
        let recording = TypingPatchRecorder(session.surface)
        session.engine.surface = recording
        session.enableTyping { _, _ in }
        XCTAssertTrue(try XCTUnwrap(session.input).replace(range: NSRange(location: 0, length: 0), with: "x"))
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

    func testMultipleEmissionsOfOneCommandAreNotConfusedWithDuplicateEchoes() throws {
        let session = try session()
        defer { session.close() }
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
    func testObjectCharactersInvalidRangesAndSurrogateSplitsAreRefusedBeforeMutation() throws {
        let session = try session()
        defer { session.close() }
        var writes = 0
        session.enableTyping { _, _ in writes += 1 }
        let input = try XCTUnwrap(session.input)
        let original = session.textView.textStorage.string
        let first = try XCTUnwrap(session.surface.rangeIndex.entry(for: Self.firstID))
        for (range, replacement) in [
            (NSRange(location: 0, length: 0), "\u{fffc}"), (first.separatorRange, "\u{fffc}"),
            (NSRange(location: 0, length: 0), "a\u{fffc}\nb"),
            (NSRange(location: -1, length: 0), "x"), (NSRange(location: 0, length: Int.max), "x"),
        ] {
            XCTAssertFalse(input.replace(range: range, with: replacement))
            XCTAssertEqual(session.textView.textStorage.string, original)
        }
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(session.engine.revision, 0)
        XCTAssertFalse(session.engine.nativeWriteFailed)
        XCTAssertTrue(input.replace(range: NSRange(location: 0, length: 0), with: "😀"))
        let before = session.textView.textStorage.string
        XCTAssertFalse(input.replace(range: NSRange(location: 1, length: 0), with: "x"))
        XCTAssertEqual(session.textView.textStorage.string, before)
        XCTAssertEqual(writes, 1)
    }

    func testOpaqueAndPlaceholderBlocksAndDuplicateIDsAreReadOnly() throws {
        let blocks = [
            BlockNoteBlock(node: "table", props: [], runs: [], id: "table"),
            BlockNoteBlock(
                node: "heading", props: Self.paragraphProps + [("level", .int(1)), ("isToggleable", .bool(true))],
                runs: [InlineRun("toggle")], id: "toggle"),
        ]
        let session = try session(blocks)
        defer { session.close() }
        var writes = 0
        session.enableTyping { _, _ in writes += 1 }
        let input = try XCTUnwrap(session.input)
        for entry in session.surface.rangeIndex.entries {
            XCTAssertFalse(input.replace(range: NSRange(location: entry.range.location, length: 0), with: "x"))
        }
        XCTAssertEqual(writes, 0)
        let duplicate = try self.session([Self.seedBlocks()[0], Self.seedBlocks()[0]])
        defer { duplicate.close() }
        duplicate.enableTyping { _, _ in XCTFail("duplicate IDs must not become edit targets") }
        XCTAssertFalse(try XCTUnwrap(duplicate.input).replace(range: NSRange(location: 0, length: 0), with: "x"))
    }

    func testUnsupportedMarkedTextKeepsTheReadOnlyRefusalAndUndoIsDisabled() throws {
        let session = try session()
        defer { session.close() }
        session.enableTyping { _, _ in XCTFail("marked text must never become a write") }
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
        XCTAssertEqual(session.engine.revision, 0)
        XCTAssertNil(session.textView.undoManager)
        XCTAssertFalse(session.textView.canPerformAction(NSSelectorFromString("undo:"), withSender: nil))
    }

    func testReplacementInsideMarkedRunPreservesAuthoritativeAttributes() throws {
        let session = try session()
        defer { session.close() }
        session.enableTyping { _, _ in }
        let entry = try XCTUnwrap(session.surface.rangeIndex.entry(for: Self.secondID))
        let offset = entry.textRange.location + "Second paragraph has ".utf16.count + 1
        XCTAssertTrue(try XCTUnwrap(session.input).replace(range: NSRange(location: offset, length: 2), with: "X"))
        let projected = try XCTUnwrap(session.engine.nativeSnapshot(for: Self.secondID))
        XCTAssertEqual(session.surface.blocks[1], projected)
        XCTAssertTrue(
            try XCTUnwrap(session.textView.textStorage.attribute(.font, at: offset, effectiveRange: nil) as? UIFont)
                .fontDescriptor.symbolicTraits.contains(.traitBold))
        assertMatches(session)
    }

    func testFailedAppendStopsWritesAndRetainsUnconfirmedBytesWithoutPublishingEcho() throws {
        let session = try session()
        defer { session.close() }
        session.enableTyping { _, _ in throw DiskError.full }
        let original = session.textView.textStorage.string
        XCTAssertFalse(try XCTUnwrap(session.input).replace(range: NSRange(location: 0, length: 0), with: "x"))
        XCTAssertEqual(session.textView.textStorage.string, original)
        XCTAssertEqual(session.input?.noticeKey, .native_editor_storage_failed)
        XCTAssertFalse(session.textView.isEditable)
        XCTAssertNotNil(session.engine.unconfirmedNativeUpdate)
        XCTAssertTrue(session.engine.nativeWriteFailed)
        XCTAssertThrowsError(try session.engine.replaceText(block: Self.firstID, range: 0..<0, with: "retry"))
        XCTAssertThrowsError(try session.engine.compositionBegan(blockID: Self.firstID, at: 0))
    }

    func testStaleCommandIsRefusedWithoutCallingPersistenceOrMutating() throws {
        let session = try session()
        defer { session.close() }
        let original = session.textView.textStorage.string
        let command = NativeEditCommand(
            id: UUID(), baseRevision: 1, blockID: Self.firstID, range: 0..<0, replacement: "x")
        XCTAssertThrowsError(try session.engine.replaceText(command) { _ in XCTFail("stale command") }) {
            XCTAssertEqual($0 as? DocumentEngineError, .staleNativeCommand)
        }
        XCTAssertEqual(session.textView.textStorage.string, original)
        XCTAssertFalse(session.engine.nativeWriteFailed)
    }

    func testUIKitInsertAndDeleteAreInterceptedOnce() throws {
        let session = try session()
        defer { session.close() }
        var writes = 0
        session.enableTyping { _, _ in writes += 1 }
        XCTAssertFalse(try XCTUnwrap(session.input).replace(range: NSRange(location: 0, length: 0), with: ""))
        XCTAssertEqual(writes, 0)
        session.textView.selectedRange = NSRange(location: 0, length: 0)
        session.textView.insertText("x")
        XCTAssertEqual(session.surface.blocks[0].runs.map(\.text).joined(), "xFirst paragraph.")
        XCTAssertEqual(writes, 1)
        assertMatches(session)
        session.textView.selectedRange = NSRange(location: 1, length: 0)
        session.textView.deleteBackward()
        XCTAssertEqual(session.surface.blocks[0].runs.map(\.text).joined(), "First paragraph.")
        XCTAssertEqual(writes, 2)
        assertMatches(session)
        session.textView.selectedRange = NSRange(location: 0, length: 0)
        session.textView.deleteBackward()
        XCTAssertEqual(writes, 2, "Backspace at the document boundary cannot mutate another block")
        let start = session.textView.beginningOfDocument
        let end = try XCTUnwrap(session.textView.position(from: start, offset: 1))
        let range = try XCTUnwrap(session.textView.textRange(from: start, to: end))
        session.textView.replace(range, withText: "Z")
        XCTAssertEqual(session.surface.blocks[0].runs.map(\.text).joined(), "Zirst paragraph.")
        XCTAssertEqual(writes, 3)
        assertMatches(session)
    }

    func testBackspaceAtTheFirstBlockIsQuietAndAtTheDocumentEndShowsANotice() throws {
        let session = try session()
        defer { session.close() }
        var writes = 0
        session.enableTyping { _, _ in writes += 1 }
        let input = try XCTUnwrap(session.input)
        let original = session.textView.textStorage.string
        // The first block has nothing above it: a quiet no-op, not an error.
        session.textView.selectedRange = NSRange(location: 0, length: 0)
        session.textView.deleteBackward()
        XCTAssertEqual(session.textView.textStorage.string, original)
        XCTAssertEqual(writes, 0)
        XCTAssertNil(input.noticeKey)
        XCTAssertTrue(session.textView.isEditable)
        // The end-of-document caret sits after the last separator, which no block owns:
        // Backspace there is refused with a notice, like typing there, never swallowed.
        session.textView.selectedRange = NSRange(location: session.textView.textStorage.length, length: 0)
        session.textView.deleteBackward()
        XCTAssertEqual(session.textView.textStorage.string, original)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(input.noticeKey, .native_editor_input_unavailable)
    }

    func testUnreadableMarksCannotTurnScrubbedDisplayIntoAWriterTarget() throws {
        let session = try session([
            BlockNoteBlock(
                node: "paragraph", props: Self.paragraphProps,
                runs: [InlineRun("future", marks: [("unknown-extension", "{}")])], id: Self.firstID)
        ])
        defer { session.close() }
        session.enableTyping { _, _ in XCTFail("projection scrubbed an unknown mark") }
        let original = session.textView.textStorage.string
        XCTAssertFalse(try XCTUnwrap(session.input).replace(range: NSRange(location: 0, length: 0), with: "x"))
        XCTAssertEqual(session.textView.textStorage.string, original)
        XCTAssertFalse(session.engine.nativeWriteFailed)
    }

    func testDisjointUIKitRangesAreRefusedInsteadOfReplacingTheirUnion() throws {
        let session = try session()
        defer { session.close() }
        session.enableTyping { _, _ in XCTFail("disjoint replacements must not write") }
        let original = session.textView.textStorage.string
        let input = try XCTUnwrap(session.input)
        XCTAssertFalse(
            input.textView(
                session.textView,
                shouldChangeTextInRanges: [
                    NSValue(range: NSRange(location: 0, length: 1)), NSValue(range: NSRange(location: 3, length: 1)),
                ], replacementText: "x"))
        XCTAssertFalse(input.textView(session.textView, shouldChangeTextInRanges: [], replacementText: "x"))
        XCTAssertEqual(session.textView.textStorage.string, original)
        XCTAssertEqual(session.engine.revision, 0)
    }

    func testKeystrokeWorkDoesNotProjectOrEncodeTheWholeLargeDocument() throws {
        let blocks = (0..<5_000).map { index in
            BlockNoteBlock(
                node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("Paragraph \(index)")],
                id: "block-\(index)")
        }
        let session = try session(blocks)
        defer { session.close() }
        var update: Data?
        session.enableTyping { _, bytes in update = bytes }
        let projections = session.engine.projectedBlockCount
        let visits = session.engine.visitedEntryCount
        let snapshots = session.engine.nativeSnapshotCount
        let entry = try XCTUnwrap(session.surface.rangeIndex.entry(for: "block-2500"))
        XCTAssertTrue(
            try XCTUnwrap(session.input).replace(
                range: NSRange(location: entry.textRange.location, length: 0), with: "x"))
        XCTAssertEqual(session.engine.projectedBlockCount - projections, 0)
        XCTAssertEqual(session.engine.visitedEntryCount - visits, 1)
        XCTAssertEqual(session.engine.nativeSnapshotCount - snapshots, 1)
        XCTAssertLessThan(try XCTUnwrap(update).count, 100, "only the local incremental update is encoded")
        XCTAssertEqual(session.surface.blocks[2_500].runs.map(\.text).joined(), "xParagraph 2500")
        assertMatches(session)
    }
}

@MainActor
private final class TypingPatchRecorder: @preconcurrency EditorSurface {
    let surface: NativeTextSurface
    var patches: [BlockPatch] = []
    init(_ surface: NativeTextSurface) { self.surface = surface }
    func applyPatch(_ patch: BlockPatch) {
        patches.append(patch)
        surface.applyPatch(patch)
    }
}
