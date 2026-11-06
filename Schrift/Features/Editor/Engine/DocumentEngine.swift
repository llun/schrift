import Foundation

/// The headless document engine (B6a): the layer a native editor sits on.
///
/// **It borrows the replica; it never owns it.** The `YDoc` belongs to
/// `DocumentCollaborationManager` on the main actor (the one-owner rule), and
/// the engine only reads and writes it through the writer. When the owner
/// destroys the replica — a fail-safe, a suspend teardown — `YDoc.onDestroy`
/// fires and the engine detaches: its hooks are cleared, buffered patches are
/// dropped, and every later call is a no-op. Nothing here can touch a destroyed
/// store.
///
/// **Buffering.** `YDoc.afterTransaction` runs inside the transaction's
/// observer phase, where a text delta is valid and the store is pre-gc/pre-merge.
/// The engine only *buffers* there. Delivery happens at `YDoc.afterAllTransactions`
/// — the outermost cleanup has finished, `doc.transaction` is nil, and a surface
/// that opens a transaction from `applyPatch` is queued and drained by the same
/// `transact` call, exactly as yjs does. A surface therefore never sees a patch
/// built from a half-cleaned store, and never runs mid-cleanup.
///
/// **Local intents emit patches too.** The engine does not suppress the patch
/// for the edit it just made: the same transaction may also carry a format
/// cleanup or a split's new block, and a surface that skipped it would drift.
/// A surface that already applied the keystroke itself reconciles; see
/// `EditorSurface`.
@MainActor
final class DocumentEngine {
    private let doc: YDoc
    private let writer: BlockNoteWriter
    private var builder: PatchBuilder
    private var buffered: [BlockPatch] = []
    private let previousAfterTransaction: ((YTransaction) -> Void)?
    private(set) var isDetached = false

    /// The surface patches are delivered to. Weak: the surface owns the engine,
    /// not the other way round.
    weak var surface: EditorSurface?

    /// Blocks projected into snapshots since the engine was created — the
    /// O(touched blocks) test seam.
    var projectedBlockCount: Int { builder.projectedBlocks }
    /// Changed types classified since the engine was created.
    var visitedTypeCount: Int { builder.visitedTypes }

    init(doc: YDoc, surface: EditorSurface? = nil) {
        self.doc = doc
        self.surface = surface
        self.writer = BlockNoteWriter(doc: doc)
        self.builder = PatchBuilder(doc: doc)
        self.previousAfterTransaction = doc.afterTransaction
        let previous = doc.afterTransaction
        doc.afterTransaction = { [weak self] transaction in
            previous?(transaction)
            self?.record(transaction)
        }
        doc.afterAllTransactions = { [weak self] in self?.flush() }
        doc.onDestroy = { [weak self] in self?.detach() }
    }

    // MARK: - Intents (UI → model)

    /// Replaces a block-relative UTF-16 range. `marks` is the complete mark set
    /// the replacement carries, or `nil` to inherit the marks at the range.
    @discardableResult
    func replaceText(block: String, range: Range<Int>, with text: String, marks: [TextMark]? = nil) throws -> Data {
        try writer.replaceText(
            block: block, range: range, with: text,
            marks: marks.map { YTextAttributes($0.map { ($0.key, $0.valueJSON) }) })
    }

    /// Applies marks over a block-relative range. A `"null"` value removes the
    /// mark, matching BlockNote's style commands.
    @discardableResult
    func formatRange(block: String, range: Range<Int>, marks: [TextMark]) throws -> Data {
        try writer.formatRange(
            block: block, range: range, attributes: YTextAttributes(marks.map { ($0.key, $0.valueJSON) }))
    }

    @discardableResult
    func splitBlock(block: String, at offset: Int, newID: String) throws -> Data {
        try writer.splitBlock(block: block, at: offset, newID: newID)
    }

    @discardableResult
    func joinBlocks(block: String) throws -> Data {
        try writer.joinBlocks(block: block)
    }

    @discardableResult
    func setBlockType(block: String, to node: String, props: [(key: String, value: YAnyValue)] = []) throws -> Data {
        try writer.setBlockType(block: block, to: node, props: props)
    }

    // MARK: - Remote updates (owner → model)

    /// Applies a peer's update. The owner may equally call
    /// `doc.applyUpdate(_:origin: .remote)` itself: the hook buffers either way
    /// and `afterAllTransactions` delivers.
    func applyRemoteUpdate(_ data: Data) throws {
        guard !isDetached else { return }
        try doc.applyUpdate(try YUpdateDecoder.decode(data), origin: .remote)
    }

    // MARK: - Change signal

    private func record(_ transaction: YTransaction) {
        guard !isDetached else { return }
        let patch = builder.build(transaction)
        guard !patch.isEmpty else { return }
        buffered.append(patch)
    }

    private func flush() {
        guard !isDetached, !buffered.isEmpty else { return }
        let patches = buffered
        buffered = []
        for patch in patches { surface?.applyPatch(patch) }
    }

    // MARK: - Teardown

    /// Detaches from the replica. Called by `YDoc.destroy()` through
    /// `onDestroy`, and safe to call directly. Idempotent; after it the engine
    /// holds no hook into the store and delivers nothing.
    func detach() {
        guard !isDetached else { return }
        isDetached = true
        buffered = []
        doc.afterTransaction = previousAfterTransaction
        doc.afterAllTransactions = nil
        doc.onDestroy = nil
    }
}
