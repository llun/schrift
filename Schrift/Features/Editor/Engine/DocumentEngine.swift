import Foundation

/// The headless document engine (B6a/B6b): the layer a native editor sits on.
///
/// **It borrows the replica; it never owns it.** The `YDoc` belongs to
/// `DocumentCollaborationManager` or a separate `NativeEditorSession` on the main actor (the one-owner rule), and
/// the engine only reads and writes it through the writer. When the owner
/// destroys the replica — a fail-safe, a suspend teardown — `YDoc.onDestroy`
/// fires and the engine detaches: its hooks are cleared, buffered patches are
/// dropped (even mid-delivery), and every later intent throws
/// `DocumentEngineError.detached`. Releasing the engine detaches it too. Nothing
/// here can touch a destroyed store.
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
///
/// **Remote updates are the owner's.** The engine never applies a peer's
/// update: `DocumentCollaborationManager` owns the replica and calls
/// `doc.applyUpdate(_:origin: .remote)`. The engine observes the resulting
/// transaction like any other and patches the surface.
///
/// **Single consumer of the delivery hooks.** `afterAllTransactions` and
/// `onDestroy` are single-slot, so the engine asserts it is their only
/// consumer; `afterTransaction` is chained and restored on detach.
@MainActor
final class DocumentEngine {
    private let doc: YDoc
    private let writer: BlockNoteWriter
    private var builder: PatchBuilder
    private enum SurfaceEvent {
        case patch(BlockPatch)
        case compositionEnded(UInt)
    }
    private var buffered: [SurfaceEvent] = []
    private var selection: RelativeEditorSelection?
    private var composition: CompositionQueue?
    private var isDeferringComposition = false
    /// Retained through pending rebuilds and chained relative restarts. Raw
    /// surface offsets stay locked until the final deferral-complete signal.
    private var deferredBlockIDs: Set<String> = []
    /// A reset freezes every block. Unlike the queue, this survives logical
    /// composition end and stays latched until final deferral completion.
    private var isWholeListDeferred = false
    private var compositionGeneration: UInt = 0
    private var isFlushing = false
    private let previousAfterTransaction: ((YTransaction) -> Void)?
    private(set) var isDetached = false
    /// True between `compositionBegan` and its commit/cancel. The surface stays
    /// frozen until the final deferral-complete signal.
    var isComposing: Bool { composition != nil }
    private(set) var revision: UInt64
    private var nativeCommand: NativeEditCommand?
    private var nativeEmission = 0
    private var holdingDurableRemote = false
    private(set) var nativeWriteFailed = false
    private(set) var nativeSnapshotCount = 0
    /// The update whose persistence failed, kept only for diagnostics and tests.
    /// Authoring and delivery are frozen (`nativeWriteFailed`); nothing retries,
    /// sends or journals it. Recovery reopens from the durable store instead.
    private(set) var unconfirmedNativeUpdate: Data?
    /// Installed by a durable replica owner: every revision must be a journal
    /// entry, so an unjournaled transaction freezes the engine (instead of
    /// drifting `revision` from `manifest.revision`) and then calls this.
    var onUnjournaledTransaction: (() -> Void)?

    /// The surface patches are delivered to. Weak: the surface owns the engine,
    /// not the other way round. A patch delivered while it is `nil` is lost and
    /// there is no catch-up, so attach the surface before the first transaction
    /// and keep it for the engine's lifetime.
    weak var surface: EditorSurface?

    /// Blocks projected into snapshots since the engine was created — the
    /// O(touched blocks) test seam.
    var projectedBlockCount: Int { builder.projectedBlocks }
    /// Changed types classified since the engine was created.
    var visitedTypeCount: Int { builder.visitedTypes }
    /// Index entries visited while emitting since the engine was created — the
    /// O(touched) emit-loop seam.
    var visitedEntryCount: Int { builder.visitedEntries }

    /// A settled per-block projection through the same canonical identity
    /// index used for writing. Native echoes must not scan all container IDs.
    func nativeSnapshot(for blockID: String) -> BlockSnapshot? {
        guard !isDetached, !nativeWriteFailed, builder.index.isCanonical,
            let entry = builder.index.entries[blockID]
        else { return nil }
        nativeSnapshotCount += 1
        return BlockSnapshot(YBlockProjection.projectBlock(entry.containerItem))
    }

    init(doc: YDoc, surface: EditorSurface? = nil, revision: UInt64 = 0) {
        self.doc = doc
        self.revision = revision
        self.surface = surface
        self.writer = BlockNoteWriter(doc: doc)
        self.builder = PatchBuilder(doc: doc)
        assert(
            doc.afterAllTransactions == nil && doc.onDestroy == nil,
            "DocumentEngine is the single consumer of afterAllTransactions/onDestroy")
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

    // Input offsets are replica coordinates. Deferred blocks reject local
    // input with .composingBlock through final rebuild/completion delivery.

    /// UIKit delegates refuse their default mutation and use this command path.
    /// Buffer echoes until the incremental bytes are durable, then reconcile
    /// exactly once into canonical storage. There is no provisional UIKit edit.
    @discardableResult
    func replaceText(_ command: NativeEditCommand, persist: (Data) throws -> Void) throws -> Data {
        try requireCompositionBoundary()
        try requireEditableBlock(command.blockID)
        guard nativeCommand == nil, !holdingDurableRemote, !isFlushing, composition == nil,
            revision == command.baseRevision, revision < UInt64.max
        else { throw DocumentEngineError.staleNativeCommand }
        guard case .replace(let range, let replacement) = command.kind else {
            throw DocumentEngineError.unsupportedNativeInput
        }
        // An empty text-capable element has no XmlText yet; the writer creates
        // one on the first insertion. An element with inline nodes is not empty
        // and stays refused.
        guard builder.index.isCanonical, let entry = builder.index.entries[command.blockID],
            entry.isProjectable, !YBlockProjection.projectBlock(entry.containerItem).fidelity.isOpaque,
            entry.isSimpleContainer, let element = entry.element,
            case .xmlElement(let node)? = element.typeRef, BlockNoteWriter.propSchemas[node] != nil,
            entry.isSimpleText || element.length == 0,
            !replacement.unicodeScalars.contains(where: {
                CharacterSet.newlines.contains($0) || $0.value == 0xfffc
            })
        else { throw DocumentEngineError.unsupportedNativeInput }
        let target = try writer.indexedTarget(entry.containerItem, id: command.blockID)
        let units = entry.runs.flatMap { Array($0.text.utf16) }
        func validBoundary(_ offset: Int) -> Bool {
            guard offset >= 0, offset <= units.count else { return false }
            return offset == 0 || offset == units.count
                || !(0xd800...0xdbff).contains(units[offset - 1]) || !(0xdc00...0xdfff).contains(units[offset])
        }
        guard entry.textType.map({ $0.length == UInt(units.count) }) ?? units.isEmpty,
            validBoundary(range.lowerBound), validBoundary(range.upperBound)
        else { throw DocumentEngineError.unsupportedNativeInput }
        nativeCommand = command
        nativeEmission = 0
        do {
            let update = try writer.replaceText(
                in: target, range: NSRange(location: range.lowerBound, length: range.count),
                with: replacement)
            unconfirmedNativeUpdate = update
            try persist(update)
            revision += 1
            unconfirmedNativeUpdate = nil
            nativeCommand = nil
            flush()
            return update
        } catch {
            // Transactions have no rollback. Stop *all* authoring and delivery
            // rather than retry against a graph whose bytes were not confirmed.
            nativeCommand = nil
            nativeWriteFailed = true
            buffered = []
            throw error
        }
    }

    /// One durable structural command: Return or boundary Backspace. The same
    /// journal-before-publication barrier as `replaceText`: the writer's
    /// incremental bytes are persisted before the surface sees the patch, and
    /// the command's own echo is stamped so the surface reconciles once (and
    /// the durable owner's unjournaled-transaction guard does not fire).
    ///
    /// The keyboard-level choices follow BlockNote 0.56 before its block
    /// commands run (see `BlockNoteWriter`): Return on an empty list item
    /// resets it to a paragraph in place; Backspace at the start of a heading
    /// or list item resets it to a paragraph; only a paragraph joins the block
    /// above. Every refusal is validated before `nativeCommand` is set, so an
    /// unsupported shape (opaque, placeholder, inline nodes, nested children,
    /// code, the first block) throws `.unsupportedNativeInput` and never
    /// freezes the engine. Returns the caret the surface should place.
    @discardableResult
    func applyStructural(
        _ command: NativeEditCommand, persist: (Data) throws -> Void
    ) throws -> EditorPosition {
        try requireCompositionBoundary()
        try requireEditableBlock(command.blockID)
        guard nativeCommand == nil, !holdingDurableRemote, !isFlushing, composition == nil,
            revision == command.baseRevision, revision < UInt64.max
        else { throw DocumentEngineError.staleNativeCommand }
        let (node, units) = try structuralTarget(command.blockID)
        let write: () throws -> Data
        // Resolved after the write, against the post-write index.
        let caret: () -> EditorPosition
        func start(_ id: String) -> EditorPosition { EditorPosition(blockID: id, offset: 0, assoc: -1) }
        switch command.kind {
        case .replace:
            throw DocumentEngineError.unsupportedNativeInput
        case .split(let offset, let newID):
            guard !newID.isEmpty, builder.index.entries[newID] == nil, offset >= 0, offset <= units.count,
                offset == 0 || offset == units.count || !(0xd800...0xdbff).contains(units[offset - 1])
                    || !(0xdc00...0xdfff).contains(units[offset])
            else { throw DocumentEngineError.unsupportedNativeInput }
            if Self.listItemNodes.contains(node), units.isEmpty {
                // No block is created, so `newID` stays unused: one model id.
                write = { try self.writer.setBlockType(block: command.blockID, to: "paragraph") }
                caret = { start(command.blockID) }
            } else {
                write = { try self.writer.splitBlock(block: command.blockID, at: offset, newID: newID) }
                // At the start of non-empty text the writer inserts the empty
                // block above, so the caret stays with the text, under the old id.
                caret = { start(offset == 0 && !units.isEmpty ? command.blockID : newID) }
            }
        case .join:
            if node != "paragraph" {
                write = { try self.writer.setBlockType(block: command.blockID, to: "paragraph") }
                caret = { start(command.blockID) }
                break
            }
            guard let position = builder.index.position[command.blockID], position > 0 else {
                throw DocumentEngineError.unsupportedNativeInput
            }
            let previousID = builder.index.order[position - 1]
            // The destination is written too: it must be typeable and unlocked.
            try requireEditableBlock(previousID)
            let aboveLength = try structuralTarget(previousID).units.count
            write = { try self.writer.joinBlocks(block: command.blockID) }
            // An empty block above with the same type and props is removed
            // instead and the source keeps its id: the caret is its start.
            caret = {
                self.builder.index.entries[previousID] != nil
                    ? EditorPosition(blockID: previousID, offset: aboveLength, assoc: -1) : start(command.blockID)
            }
        }
        nativeCommand = command
        nativeEmission = 0
        do {
            let update = try write()
            let position = caret()
            unconfirmedNativeUpdate = update
            try persist(update)
            revision += 1
            unconfirmedNativeUpdate = nil
            nativeCommand = nil
            flush()
            return position
        } catch {
            // Transactions have no rollback. Stop all authoring and delivery
            // rather than retry against a graph whose bytes were not confirmed.
            nativeCommand = nil
            nativeWriteFailed = true
            buffered = []
            throw error
        }
    }

    private static let listItemNodes: Set<String> = ["bulletListItem", "numberedListItem", "checkListItem"]

    /// A block a structural command may address: a writable simple text, or an
    /// empty text-capable element the writer gives an XmlText on first insert.
    /// Inline nodes, nested children, opaque/scrubbed content and code stay refused.
    private func structuralTarget(_ blockID: String) throws -> (node: String, units: [UInt16]) {
        guard builder.index.isCanonical, let entry = builder.index.entries[blockID],
            entry.isProjectable, !YBlockProjection.projectBlock(entry.containerItem).fidelity.isOpaque,
            entry.isSimpleContainer, let element = entry.element,
            case .xmlElement(let node)? = element.typeRef,
            BlockNoteWriter.propSchemas[node] != nil, node != "codeBlock",
            entry.isSimpleText || element.length == 0
        else { throw DocumentEngineError.unsupportedNativeInput }
        let units = entry.runs.flatMap { Array($0.text.utf16) }
        guard entry.textType.map({ $0.length == UInt(units.count) }) ?? units.isEmpty else {
            throw DocumentEngineError.unsupportedNativeInput
        }
        return (node, units)
    }

    /// The owner applies remote bytes; the engine only holds delivery until
    /// their journal entry is durable. One accepted update advances the shared
    /// revision even when Yjs replay is an idempotent no-op.
    ///
    /// Remote data is accepted **during** a composition: the composing block's
    /// changes are deferred by the queue and every other block's patch is
    /// buffered by the surface until reconciliation. Only local commands are
    /// refused while text is marked.
    func durablyIntegrateRemote(
        update: Data, apply: () throws -> Void, persist: (UInt64) throws -> Void
    ) throws {
        try requireCompositionBoundary()
        guard nativeCommand == nil, !holdingDurableRemote, !isFlushing, revision < UInt64.max else {
            throw DocumentEngineError.insideTransaction
        }
        holdingDurableRemote = true
        do {
            unconfirmedNativeUpdate = update
            try apply()
            try persist(revision)
            revision += 1
            holdingDurableRemote = false
            unconfirmedNativeUpdate = nil
            flush()
        } catch {
            holdingDurableRemote = false
            nativeWriteFailed = true
            buffered = []
            throw error
        }
    }

    /// Replaces a block-relative UTF-16 range. `marks` is the complete mark set
    /// the replacement carries, or `nil` to inherit the marks at the range.
    @discardableResult
    func replaceText(block: String, range: Range<Int>, with text: String, marks: [TextMark]? = nil) throws -> Data {
        try requireEditableBlock(block)
        return try writer.replaceText(
            block: block, range: range, with: text,
            marks: marks.map { YTextAttributes($0.map { ($0.key, $0.valueJSON) }) })
    }

    /// Applies marks over a block-relative range. A `"null"` value removes the
    /// mark, matching BlockNote's style commands.
    @discardableResult
    func formatRange(block: String, range: Range<Int>, marks: [TextMark]) throws -> Data {
        try requireEditableBlock(block)
        return try writer.formatRange(
            block: block, range: range, attributes: YTextAttributes(marks.map { ($0.key, $0.valueJSON) }))
    }

    @discardableResult
    func splitBlock(block: String, at offset: Int, newID: String) throws -> Data {
        try requireEditableBlock(block)
        return try writer.splitBlock(block: block, at: offset, newID: newID)
    }

    @discardableResult
    func joinBlocks(block: String) throws -> Data {
        try requireEditableBlock(block)
        if !deferredBlockIDs.isEmpty {
            // A join writes both the source and the previous sibling's last
            // descendant. Check their outermost indexed blocks as well, so a
            // nested destination cannot bypass a composing ancestor's lock.
            let target = try writer.find(block)
            if let source = builder.index.blockID(for: target.container) { try requireEditableBlock(source) }
            var previous = target.item.left
            while previous?.deleted == true { previous = previous?.left }
            if let previous, case .type(let type) = previous.content,
                let destination = builder.index.blockID(for: type)
            {
                try requireEditableBlock(destination)
            }
        }
        return try writer.joinBlocks(block: block)
    }

    @discardableResult
    func setBlockType(block: String, to node: String, props: [(key: String, value: YAnyValue)] = []) throws -> Data {
        try requireEditableBlock(block)
        return try writer.setBlockType(block: block, to: node, props: props)
    }

    // MARK: - Selection and composition

    /// Captures both endpoints atomically. Unsupported/opaque blocks and
    /// out-of-bounds offsets throw without replacing the previous selection.
    func setSelection(_ selection: EditorSelection?) throws {
        try requireAttached()
        if let selection {
            try requireEditableBlock(selection.anchor.blockID)
            try requireEditableBlock(selection.head.blockID)
        }
        self.selection = try selection.map { try RelativeEditorSelection($0, index: builder.index) }
    }

    /// Resolves against the current replica, not the possibly deferred surface.
    /// A removed/replaced/non-addressable text invalidates the selection.
    func currentSelection() throws -> EditorSelection? {
        try requireAttached()
        return selection?.resolve(in: doc, index: builder.index)
    }

    /// Captures an insertion anchor, normally the current selection's head.
    /// An explicit offset lets a surface begin composition before reporting its
    /// selection. The composed string is an insertion, not a replacement range.
    /// `assoc` defaults to left affinity so a peer append stays after an IME
    /// begun at end-of-text. With no explicit offset the head's affinity wins.
    /// Explicit offsets into deferred blocks throw `.composingBlock`; a restart
    /// from the existing relative selection is allowed without `at:`.
    func compositionBegan(blockID: String, at offset: Int? = nil, assoc: Int = -1) throws {
        try requireCompositionBoundary()
        if offset != nil { try requireEditableBlock(blockID) }
        guard composition == nil else { throw DocumentEngineError.compositionAlreadyActive }
        let position: EditorPosition
        if let offset {
            position = EditorPosition(blockID: blockID, offset: offset, assoc: assoc)
        } else {
            guard let head = try currentSelection()?.head, head.blockID == blockID else {
                throw DocumentEngineError.invalidPosition
            }
            position = head
        }
        try beginComposition(blockID: blockID, range: position.offset..<position.offset, assoc: position.assoc)
    }

    /// Captures both endpoints of a same-block replacement range before UIKit
    /// owns the marked text. The commit replaces exactly that span, so a
    /// selected-text composition writes once instead of inserting beside it.
    func compositionBegan(blockID: String, replacing range: Range<Int>) throws {
        try requireCompositionBoundary()
        try requireEditableBlock(blockID)
        guard composition == nil else { throw DocumentEngineError.compositionAlreadyActive }
        try beginComposition(blockID: blockID, range: range, assoc: -1)
    }

    private func beginComposition(blockID: String, range: Range<Int>, assoc: Int) throws {
        let captured = try RelativeEditorRange(blockID: blockID, range: range, assoc: assoc, index: builder.index)
        // Selection can address any projectable single text; composing also
        // requires a block the writer supports.
        guard let element = builder.index.entries[blockID]?.element,
            case .xmlElement(let node)? = element.typeRef, BlockNoteWriter.propSchemas[node] != nil
        else { throw DocumentEngineError.invalidPosition }
        composition = CompositionQueue(range: captured)
        compositionGeneration &+= 1
        deferredBlockIDs.insert(blockID)
        // A previous composition may have ended logically inside applyPatch,
        // with its completion event still queued. Keep deferral continuous.
        if !isDeferringComposition {
            isDeferringComposition = true
            surface?.setCompositionDeferred(true)
        }
    }

    /// Writes once at the resolved anchor through the existing local-user
    /// writer. A deleted, replaced, or opaque target drops the write and returns
    /// the empty update. Discarded deltas (including the write's own) are replaced
    /// by one current snapshot; callers can broadcast the returned update.
    @discardableResult
    func compositionCommitted(text: String) throws -> Data {
        switch try commitComposition(text: text, persist: nil) {
        case .committed(let update): return update
        case .orphaned: return Data([0, 0])
        }
    }

    /// The durable commit: the same single write as one `NativeEditCommand`
    /// (`commandID`, the current revision, the resolved replica range), but patch
    /// delivery stays held until `persist` has journaled the incremental bytes.
    /// A target that was deleted or replaced is reported as `.orphaned` and
    /// never redirected into a new text under the same block id.
    @discardableResult
    func compositionCommitted(
        text: String, commandID: UUID, persist: (NativeEditCommand, Data) throws -> Void
    ) throws -> CompositionCommitResult {
        try withoutActuallyEscaping(persist) { try commitComposition(text: text, commandID: commandID, persist: $0) }
    }

    private func commitComposition(
        text: String, commandID: UUID = UUID(), persist: ((NativeEditCommand, Data) throws -> Void)?
    ) throws -> CompositionCommitResult {
        try requireCompositionBoundary()
        guard let composing = composition else { throw DocumentEngineError.compositionNotActive }
        guard let range = composing.range.resolve(in: doc, index: builder.index) else {
            finishComposition(origin: .other)
            return .orphaned
        }
        let blockID = composing.blockID
        // One identified command, so the write's own echo is stamped and the
        // durable owner's unjournaled-transaction guard does not fire.
        let command = NativeEditCommand(
            id: commandID, baseRevision: revision, blockID: blockID, range: range, replacement: text)
        nativeCommand = command
        nativeEmission = 0
        let update: Data
        do {
            update = try writer.transaction { _ in
                try writer.replaceText(block: blockID, range: range, with: text)
                // Capture before cleanup/observers can edit or replace the text.
                // Refresh only this entry in a temporary index: an empty element
                // can now have the XmlText the writer just created. A failed
                // capture propagates through the same error/rebuild path as a
                // writer failure; it is never silently converted to nil.
                var captureIndex = builder.index
                captureIndex.refresh(blockID)
                let caret = EditorPosition(
                    blockID: blockID, offset: range.lowerBound + text.utf16.count, assoc: -1)
                selection = try RelativeEditorSelection(
                    EditorSelection(anchor: caret, head: caret), index: captureIndex)
            }
        } catch {
            nativeCommand = nil
            if !isDetached { finishComposition(origin: .other) }
            throw error
        }
        guard !isDetached else {
            nativeCommand = nil
            return .committed(update)
        }
        unconfirmedNativeUpdate = update
        do {
            try persist?(command, update)
        } catch {
            // Transactions have no rollback. Stop all authoring and delivery,
            // drop the provisional display and keep the unconfirmed bytes only
            // for diagnostics; nothing retries against the mutated graph.
            nativeCommand = nil
            nativeWriteFailed = true
            buffered = []
            composition = nil
            if isDeferringComposition {
                isDeferringComposition = false
                deferredBlockIDs = []
                isWholeListDeferred = false
                surface?.setCompositionDeferred(false)
            }
            throw error
        }
        revision += 1
        unconfirmedNativeUpdate = nil
        nativeCommand = nil
        // The snapshot also contains discarded peer changes, so an optimistic
        // surface must apply it even when it already displayed the marked text.
        finishComposition(origin: .other)
        return .committed(update)
    }

    /// No write. The caret returns to the resolved start of the replaced span,
    /// so a cancelled composition leaves the selection where it began.
    func compositionCancelled() throws {
        try requireCompositionBoundary()
        guard let composing = composition else { throw DocumentEngineError.compositionNotActive }
        if let range = composing.range.resolve(in: doc, index: builder.index) {
            let caret = EditorPosition(blockID: composing.blockID, offset: range.lowerBound, assoc: -1)
            selection = try RelativeEditorSelection(EditorSelection(anchor: caret, head: caret), index: builder.index)
        }
        finishComposition(origin: .other)
    }

    private func finishComposition(origin: BlockPatchOrigin) {
        guard let composing = composition else { return }
        let change: BlockChange
        if !composing.requiresReset, builder.index.isCanonical,
            let entry = builder.index.entries[composing.blockID]
        {
            change = .replaceBlock(
                blockID: entry.id, block: BlockSnapshot(YBlockProjection.projectBlock(entry.containerItem)))
        } else {
            change = .reset(YBlockProjection.project(doc).blocks.map(BlockSnapshot.init))
        }
        composition = nil
        buffered.append(.patch(BlockPatch([change], origin: origin)))
        buffered.append(.compositionEnded(compositionGeneration))
        flush()
    }

    /// Intents after detach are a documented error, not a silent no-op: the
    /// replica is gone, so there is nothing to write and a caller that still
    /// holds the engine has a lifecycle bug.
    private func requireAttached() throws {
        guard !isDetached else { throw DocumentEngineError.detached }
    }

    /// Observer hooks can have no open transaction while cleanup is still
    /// pending. Composition transitions must wait for both phases to finish;
    /// applyPatch runs from afterAllTransactions after the cleanup list is cleared.
    private func requireCompositionBoundary() throws {
        try requireAttached()
        guard !nativeWriteFailed else { throw DocumentEngineError.nativeWriteFailed }
        guard nativeCommand == nil, !holdingDurableRemote,
            doc.transaction == nil, doc.transactionCleanups.isEmpty
        else {
            throw DocumentEngineError.insideTransaction
        }
    }

    private func requireEditableBlock(_ blockID: String) throws {
        try requireAttached()
        guard !nativeWriteFailed else { throw DocumentEngineError.nativeWriteFailed }
        guard nativeCommand == nil, !holdingDurableRemote else { throw DocumentEngineError.insideTransaction }
        guard !isWholeListDeferred, !deferredBlockIDs.contains(blockID) else {
            throw DocumentEngineError.composingBlock
        }
    }

    // MARK: - Change signal

    private func record(_ transaction: YTransaction) {
        guard !isDetached else { return }
        var patch = builder.build(transaction)
        if let command = nativeCommand, patch.origin == .localUser {
            patch.nativeCommand = NativePatchStamp(
                commandID: command.id, baseRevision: command.baseRevision, emission: nativeEmission)
            nativeEmission += 1
        } else if nativeCommand == nil && !holdingDurableRemote && !patch.isEmpty {
            if let onUnjournaledTransaction {
                // No rollback exists for the transaction; freeze like a failed append.
                nativeWriteFailed = true
                buffered = []
                onUnjournaledTransaction()
                return
            }
            revision &+= 1
        }
        patch = filterForComposition(patch)
        guard !patch.isEmpty else { return }
        buffered.append(.patch(patch))
    }

    /// Both recording and reentrant delivery can discover a structural reset.
    /// Latch its input lock before dropping the patch, even if completion later
    /// clears or replaces the queue before the reset reaches the surface.
    private func filterForComposition(_ patch: BlockPatch) -> BlockPatch {
        guard var queue = composition else { return patch }
        let filtered = queue.filter(patch)
        composition = queue
        if queue.requiresReset { isWholeListDeferred = true }
        return filtered
    }

    /// Delivers buffered patches in order. A surface may open a transaction
    /// from `applyPatch` (a UIKit text view does); that transaction's
    /// `afterAllTransactions` re-enters here, sees `isFlushing`, and leaves its
    /// patch in the queue for this outermost loop to drain — never mid-delivery.
    private func flush() {
        guard !isDetached, !isFlushing, nativeCommand == nil, !holdingDurableRemote, !nativeWriteFailed else { return }
        isFlushing = true
        defer { isFlushing = false }
        while !buffered.isEmpty {
            let patches = buffered
            buffered = []
            for event in patches {
                // A surface may detach the engine (or destroy the replica,
                // which detaches it) from `applyPatch`: drop the rest.
                guard !isDetached else { return }
                switch event {
                case .patch(var patch):
                    // A previous delivery can begin composition reentrantly.
                    patch = filterForComposition(patch)
                    if !patch.isEmpty { surface?.applyPatch(patch) }
                case .compositionEnded(let generation):
                    guard generation == compositionGeneration else { continue }
                    isDeferringComposition = false
                    deferredBlockIDs = []
                    isWholeListDeferred = false
                    surface?.setCompositionDeferred(false)
                }
            }
        }
    }

    // MARK: - Teardown

    /// Detaches from the replica. Called by `YDoc.destroy()` through
    /// `onDestroy`, and safe to call directly. Idempotent; after it the engine
    /// holds no hook into the store, delivers nothing, and every intent throws
    /// `DocumentEngineError.detached`.
    /// An engine released without `detach()` (an editor screen closing while
    /// the replica lingers) must not leave its hooks on the replica.
    isolated deinit {
        detach()
    }

    func detach() {
        guard !isDetached else { return }
        isDetached = true
        buffered = []
        let wasComposing = isDeferringComposition
        isDeferringComposition = false
        deferredBlockIDs = []
        isWholeListDeferred = false
        composition = nil
        selection = nil
        doc.afterTransaction = previousAfterTransaction
        doc.afterAllTransactions = nil
        doc.onDestroy = nil
        if wasComposing { surface?.setCompositionDeferred(false) }
    }
}

/// The outcome of a composition commit. `.orphaned` means the captured target
/// was deleted or replaced: nothing was written, and the caller keeps the text
/// for explicit recovery rather than redirecting it into another block.
enum CompositionCommitResult: Equatable {
    case committed(Data)
    case orphaned
}

/// The engine's lifecycle errors.
enum DocumentEngineError: Error, Equatable {
    case staleNativeCommand, unsupportedNativeInput, nativeWriteFailed
    /// The replica was destroyed (or the engine detached); intents are refused.
    case detached
    case invalidPosition
    case compositionAlreadyActive
    case compositionNotActive
    /// Surface offsets may be stale until final rebuild/completion delivery.
    case composingBlock
    /// Composition transitions require a transaction boundary after all cleanup.
    case insideTransaction
}
