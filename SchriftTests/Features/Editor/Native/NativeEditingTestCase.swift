import UIKit
import XCTest

@testable import Schrift

/// The PR04b harness: a real `NativeTextView` over a restored durable replica
/// (so the unjournaled-transaction freeze is armed), every local command
/// journaled through `ReplicaStore.append`, and a private pasteboard. No sleeps.
@MainActor
class NativeEditingTestCase: DocumentEngineTestCase {
    final class WriteLog {
        var commands: [NativeEditCommand] = []
        /// The surface's blocks when each command was journaled.
        var blocksAtPersist: [[BlockSnapshot]] = []
    }

    @MainActor
    struct Harness {
        let session: NativeEditorSession
        let store: ReplicaStore
        let scope: ReplicaScope
        let log: WriteLog
        let directory: URL
        let pasteboard: UIPasteboard

        var input: NativeInputCoordinator { session.input! }
        var view: NativeTextView { session.textView }

        func close() {
            session.close()
            UIPasteboard.remove(withName: pasteboard.name)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func makeHarness(_ blocks: [BlockNoteBlock] = seedBlocks()) throws -> Harness {
        try makeHarness(state: BlockNoteYjs.encode(blocks, clientID: Self.seedClientID))
    }

    /// The same harness over any checkpoint, for shapes the block encoder
    /// cannot spell (tables, column lists).
    func makeHarness(state: Data) throws -> Harness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scope = ReplicaScope(
            serverOrigin: "https://example.test", ownerUserID: UUID(), org: "docs", documentID: UUID())
        let store = ReplicaStore(directory: directory)
        _ = try store.create(for: scope, checkpoint: state)
        let session = try XCTUnwrap(NativeEditorSession.restore(store: store, scope: scope))
        let log = WriteLog()
        session.enableTyping { [weak session] command, update in
            log.commands.append(command)
            log.blocksAtPersist.append(session?.surface.blocks ?? [])
            try store.append(
                update, for: scope, commandID: command.id, baseRevision: command.baseRevision, origin: .local)
        }
        let pasteboard = UIPasteboard.withUniqueName()
        session.input?.pasteboard = pasteboard
        return Harness(
            session: session, store: store, scope: scope, log: log, directory: directory, pasteboard: pasteboard)
    }

    /// Storage equals a fresh projection, the range index is current, exactly
    /// `localCommands` commands were journaled, and the journal replays to the
    /// surface. Nothing froze.
    func assertConsistent(
        _ harness: Harness, localCommands: Int, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let session = harness.session
        let fresh = AttributedDocumentProjection.attributedString(
            blocks: session.surface.blocks, traits: session.surface.traits, labels: session.surface.labels,
            geometry: session.surface.attachmentGeometry)
        XCTAssertTrue(
            session.textView.textStorage.isEqual(to: fresh), "storage equals the projection", file: file, line: line)
        XCTAssertEqual(
            session.surface.rangeIndex.entries,
            ProjectionRangeIndex(blocks: session.surface.blocks, labels: session.surface.labels).entries,
            file: file, line: line)
        let restored = try XCTUnwrap(harness.store.restore(for: harness.scope), file: file, line: line)
        XCTAssertEqual(
            restored.manifest.journal.filter { $0.origin == .local }.map(\.commandID),
            harness.log.commands.map(\.id), file: file, line: line)
        XCTAssertEqual(
            harness.log.commands.count, localCommands, "one journaled command per action", file: file, line: line)
        XCTAssertEqual(session.surface.blocks, try replay(harness), "replay equals the surface", file: file, line: line)
        XCTAssertFalse(session.engine.nativeWriteFailed, file: file, line: line)
        XCTAssertTrue(session.textView.isEditable, file: file, line: line)
    }

    func replay(_ harness: Harness) throws -> [BlockSnapshot] {
        let restored = try XCTUnwrap(harness.store.restore(for: harness.scope))
        let replica = YDoc(clientID: 99)
        defer { replica.destroy() }
        try replica.applyUpdate(YUpdateDecoder.decode(restored.checkpoint), origin: .remote)
        for update in restored.updates { try replica.applyUpdate(YUpdateDecoder.decode(update), origin: .remote) }
        return projection(replica)
    }

    /// The last journaled command's range, or a failure.
    func lastRange(_ harness: Harness, file: StaticString = #filePath, line: UInt = #line) -> NativeRangeCommand? {
        guard case .range(let range)? = harness.log.commands.last?.kind else {
            XCTFail("the last command is not a range command", file: file, line: line)
            return nil
        }
        return range
    }

    func location(_ session: NativeEditorSession, _ blockID: String, _ offset: Int) throws -> Int {
        try XCTUnwrap(session.surface.rangeIndex.entry(for: blockID)).textRange.location + offset
    }

    /// Selects from `anchor` to `head` the way UIKit reports it (unordered),
    /// growing from a caret at the anchor as Shift-arrows do, so the
    /// coordinator infers the direction.
    func select(
        _ harness: Harness, from anchor: (String, Int), to head: (String, Int)
    ) throws {
        let a = try location(harness.session, anchor.0, anchor.1)
        let h = try location(harness.session, head.0, head.1)
        setSelection(harness, NSRange(location: a, length: 0))
        setSelection(harness, NSRange(location: min(a, h), length: abs(h - a)))
    }

    /// What UIKit does for a selection change: assign and notify the delegate.
    func setSelection(_ harness: Harness, _ range: NSRange) {
        harness.view.selectedRange = range
        harness.input.textViewDidChangeSelection(harness.view)
    }

    func block(_ session: NativeEditorSession, _ id: String) throws -> BlockSnapshot {
        try XCTUnwrap(session.surface.blocks.first { $0.id == id })
    }

    func texts(_ session: NativeEditorSession) -> [String] {
        session.surface.blocks.map { text(of: $0) }
    }

    func paragraph(_ id: String, _ text: String) -> BlockNoteBlock {
        BlockNoteBlock(
            node: "paragraph", props: Self.paragraphProps, runs: text.isEmpty ? [] : [InlineRun(text)], id: id)
    }

    func heading(_ id: String, _ text: String, toggle: Bool = false) -> BlockNoteBlock {
        BlockNoteBlock(
            node: "heading", props: Self.paragraphProps + [("level", .int(2)), ("isToggleable", .bool(toggle))],
            runs: [InlineRun(text)], id: id)
    }

    func bullet(_ id: String, _ text: String) -> BlockNoteBlock {
        BlockNoteBlock(node: "bulletListItem", props: Self.paragraphProps, runs: [InlineRun(text)], id: id)
    }
}
