import Synchronization
import UIKit
import XCTest

@testable import Schrift

/// A value the replica session's journal (off the main actor) and the test
/// both read and write.
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: sending Value) { mutex = Mutex(value) }
    var value: Value {
        get { mutex.withLock { $0 } }
        set { mutex.withLock { $0 = newValue } }
    }
    func update(_ body: (inout Value) -> Void) { mutex.withLock { body(&$0) } }
}

extension NativeEditorSession {
    /// Tests only: reads the live engine on the replica session, in mailbox
    /// order (after everything posted before). Nil once it closed.
    func engine<T: Sendable>(_ body: @escaping @Sendable (DocumentEngine) -> T) async -> T? {
        guard let replica else { return nil }
        return await withCheckedContinuation { (done: CheckedContinuation<T?, Never>) in
            replica.mailbox.post(.inspect({ engine, _, _ in done.resume(returning: engine.map(body)) }))
        }
    }

    /// The same for an optional result, flattened.
    func engine<T: Sendable>(_ body: @escaping @Sendable (DocumentEngine) -> T?) async -> T? {
        guard let replica else { return nil }
        return await withCheckedContinuation { (done: CheckedContinuation<T?, Never>) in
            replica.mailbox.post(.inspect({ engine, _, _ in done.resume(returning: engine.flatMap(body)) }))
        }
    }

    /// Tests only: the replica itself, for byte-level checks.
    func replicaDoc<T: Sendable>(_ body: @escaping @Sendable (YDoc) -> T) async -> T? {
        guard let replica else { return nil }
        return await withCheckedContinuation { (done: CheckedContinuation<T?, Never>) in
            replica.mailbox.post(.inspect({ _, doc, _ in done.resume(returning: doc.map(body)) }))
        }
    }

    /// Tests only: the session's shared undo history (nil before typing).
    func history<T: Sendable>(_ body: @escaping @Sendable (ReplicaHistory) -> T) async -> T? {
        guard let replica else { return nil }
        return await withCheckedContinuation { (done: CheckedContinuation<T?, Never>) in
            replica.mailbox.post(.inspect({ _, _, history in done.resume(returning: history.map(body)) }))
        }
    }

    /// Settles, then runs `action` and settles again: true when it was taken
    /// and nothing it posted was refused, stale twice, invalidated or failed
    /// (barriers answer asynchronously since PR08b).
    func run(_ action: () -> Bool) async -> Bool {
        input?.resetOutcome()
        let taken = action()
        await settle()
        return taken && input?.lastOutcome != false
    }
}

/// The PR04b harness: a real `NativeTextView` over a restored durable replica
/// (so the unjournaled-transaction freeze is armed), every local command
/// journaled through `ReplicaStore.append` on the replica session, and a
/// private pasteboard. No sleeps: `settle` waits for the session's drain marker.
@MainActor
class NativeEditingTestCase: DocumentEngineTestCase {
    final class WriteLog: Sendable {
        private let state = Locked<(commands: [NativeEditCommand], blocks: [[BlockSnapshot]])>(([], []))
        var commands: [NativeEditCommand] { state.value.commands }
        /// The surface's blocks when each command was journaled (read on the
        /// main thread while the session waits in the append).
        var blocksAtPersist: [[BlockSnapshot]] { state.value.blocks }
        func record(_ command: NativeEditCommand, blocks: [BlockSnapshot]) {
            state.update {
                $0.commands.append(command)
                $0.blocks.append(blocks)
            }
        }
    }

    /// The display's blocks, read from the session's thread (the journal
    /// closure) while the main thread is free: what the surface showed when a
    /// command was being journaled.
    nonisolated static func displayedBlocks(_ session: NativeEditorSession?) -> [BlockSnapshot] {
        guard let session else { return [] }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { session.surface.blocks } }
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

        /// Everything posted so far is handled and shown.
        func settle() async { await session.settle() }

        /// `action`'s eventual outcome (see `NativeEditorSession.run`).
        func run(_ action: () -> Bool) async -> Bool { await session.run(action) }

        /// Reads the live engine on the replica session, after everything posted.
        func engine<T: Sendable>(_ body: @escaping @Sendable (DocumentEngine) -> T) async -> T? {
            await session.engine(body)
        }

        func engine<T: Sendable>(_ body: @escaping @Sendable (DocumentEngine) -> T?) async -> T? {
            await session.engine(body)
        }

        func close() async {
            await session.close().value
            UIPasteboard.remove(withName: pasteboard.name)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func makeHarness(
        _ blocks: [BlockNoteBlock] = seedBlocks(),
        interrupt: (@Sendable (ReplicaStore.Operation, ReplicaStore.Boundary) throws -> Void)? = nil,
        hooks: DocumentReplicaSession.Hooks = .init()
    ) async throws -> Harness {
        try await makeHarness(
            state: BlockNoteYjs.encode(blocks, clientID: Self.seedClientID), interrupt: interrupt, hooks: hooks)
    }

    /// The same harness over any checkpoint, for shapes the block encoder
    /// cannot spell (tables, column lists).
    func makeHarness(
        state: Data, interrupt: (@Sendable (ReplicaStore.Operation, ReplicaStore.Boundary) throws -> Void)? = nil,
        hooks: DocumentReplicaSession.Hooks = .init()
    ) async throws -> Harness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scope = ReplicaScope(
            serverOrigin: "https://example.test", ownerUserID: UUID(), org: "docs", documentID: UUID())
        let store = ReplicaStore(directory: directory, interrupt: interrupt)
        _ = try store.create(for: scope, checkpoint: state)
        let restored = try await NativeEditorSession.restore(store: store, scope: scope, hooks: hooks)
        let session = try XCTUnwrap(restored)
        let log = WriteLog()
        session.enableTyping(persist: { [weak session] command, update in
            log.record(command, blocks: Self.displayedBlocks(session))
            try store.append(
                update, for: scope, commandID: command.id, baseRevision: command.baseRevision, origin: .local)
        })
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
    ) async throws {
        await harness.settle()
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
        let failed = await harness.engine { $0.nativeWriteFailed }
        XCTAssertEqual(failed, false, file: file, line: line)
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

/// Every patch the replica session delivered to a view session, in order
/// (what a recording `EditorSurface` saw before PR08b moved the engine off the
/// main actor). One per session: it takes `onDelivery`.
@MainActor
final class PatchLog {
    private(set) var patches: [BlockPatch] = []
    private(set) var deliveries: [ReplicaDelivery] = []

    init(_ session: NativeEditorSession) {
        session.onDelivery = { [weak self] delivery in
            self?.deliveries.append(delivery)
            for case .patch(let patch, _) in delivery.events { self?.patches.append(patch) }
        }
    }

    var kinds: Set<String> {
        Set(
            patches.flatMap(\.changes).map {
                switch $0 {
                case .text: "text"
                case .props: "props"
                case .insert: "insert"
                case .remove: "remove"
                case .replaceBlock: "replaceBlock"
                case .reset: "reset"
                }
            })
    }

    var didReset: Bool {
        patches.contains { $0.changes.contains { if case .reset = $0 { true } else { false } } }
    }
}

/// `XCTUnwrap` with a plain argument, so the value may be awaited in place
/// (XCTest's autoclosures cannot contain `await`).
func unwrapped<T>(_ value: T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, message, file: file, line: line)
}
