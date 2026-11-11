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
///
/// **Isolation (PR08a).** No actor annotation: the engine, like the replica it
/// borrows, is confined to whichever isolation domain creates it (today the
/// main actor; an actor in PR08b). It is not `Sendable` and never crosses
/// domains; only its value outputs (`BlockPatch`, `EditorSelection`, …) do.
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
    /// The relative selection when the command now armed began (nil outside
    /// one): the native history stores it with the step it captures (PR07b).
    private(set) var selectionBeforeCommand: RelativeEditorSelection?
    /// Every transaction recorded while a history step runs; nil otherwise.
    private var stepTransactions: [YTransaction]?

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
        return BlockSnapshot(builder.nativeSnapshot(entry))
    }

    /// The tree projection of one indexed block, with its handle. Nil when
    /// the index is not canonical or does not hold the id.
    func nativeBlock(_ blockID: String) -> NativeBlockSnapshot? {
        guard !isDetached, builder.index.isCanonical, let entry = builder.index.entries[blockID] else { return nil }
        return builder.nativeSnapshot(entry)
    }

    init(doc: YDoc, surface: EditorSurface? = nil, revision: UInt64 = 0) {
        self.doc = doc
        self.revision = revision
        self.surface = surface
        self.writer = BlockNoteWriter(doc: doc, schemas: BlockNoteWriter.nativePropSchemas)
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
        guard case .replace(let range, let replacement, let marks) = command.kind else {
            throw DocumentEngineError.unsupportedNativeInput
        }
        // An empty text-capable element has no XmlText yet; the writer creates
        // one on the first insertion. An element with inline nodes is not empty
        // and stays refused.
        guard builder.index.isCanonical, let entry = builder.index.entries[command.blockID],
            entry.isProjectable,
            !builder.nativeSnapshot(entry).block.fidelity.isOpaque,
            entry.isSimpleContainer, let element = entry.element,
            case .xmlElement(let node)? = element.typeRef, writer.schemas[node] != nil,
            entry.isSimpleText || element.length == 0,
            // A code block keeps "\n" as a source line break (BlockNote's Enter
            // there); in prose a newline is a block break, a range command.
            !replacement.unicodeScalars.contains(where: {
                $0.value == 0xfffc || (CharacterSet.newlines.contains($0) && !(node == "codeBlock" && $0 == "\n"))
            }),
            marks?.allSatisfy({ Self.isMarkValue($0) && $0.valueJSON != "null" }) != false
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
        selectionBeforeCommand = selection
        defer { selectionBeforeCommand = nil }
        do {
            let update = try writer.replaceText(
                in: target, range: range,
                with: replacement,
                marks: marks.map { YTextAttributes($0.map { ($0.key, $0.valueJSON) }) })
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

    /// One durable structural command: Return, boundary Backspace or a range
    /// replacement (`.range`: typing, deleting, pasting or dictating over a
    /// selection that may span blocks, newlines splitting blocks). The same
    /// journal-before-publication barrier as `replaceText`: the writer's
    /// incremental bytes are persisted before the surface sees the patch, and
    /// the command's own echo is stamped so the surface reconciles once (and
    /// the durable owner's unjournaled-transaction guard does not fire).
    ///
    /// The keyboard-level choices follow BlockNote 0.56 before its block
    /// commands run (see `BlockNoteWriter`): Return on an empty list item
    /// resets it to a paragraph in place; Backspace at the start of a heading
    /// or list item resets it to a paragraph; only a paragraph joins the block
    /// above. Tree rules (PR06a): Return in an empty nested block outdents it,
    /// Backspace at a nested paragraph's start merges into the block above (a
    /// first child into its parent) and outdents only when it cannot, and `.indent`/
    /// `.outdent` are `sinkListItem`/`liftListItem`. Every refusal is validated
    /// before `nativeCommand` is set, so an unsupported shape (opaque,
    /// placeholder, inline nodes, a child that cannot move, code, the first
    /// block, such a block anywhere in a range) throws
    /// `.unsupportedNativeInput` and never freezes the engine. Returns the
    /// caret the surface should place.
    @discardableResult
    func applyStructural(
        _ command: NativeEditCommand, persist: (Data) throws -> Void
    ) throws -> EditorPosition {
        let (write, caret) = try prepareStructural(command)
        nativeCommand = command
        nativeEmission = 0
        selectionBeforeCommand = selection
        defer { selectionBeforeCommand = nil }
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
            nativeCommand = nil
            // The writer validates before its transaction, and every transaction
            // stamps an emission: a writer refusal with none wrote nothing (for
            // example a malformed or duplicate id elsewhere that `find` walks).
            if nativeEmission == 0, error is BlockNoteWriter.Error {
                throw DocumentEngineError.unsupportedNativeInput
            }
            // Transactions have no rollback. Stop all authoring and delivery
            // rather than retry against a graph whose bytes were not confirmed.
            nativeWriteFailed = true
            buffered = []
            throw error
        }
    }

    /// One durable step of the native history (PR07b: `.undo`/`.redo`). `step`
    /// runs the step's own transaction, whose origin is neither `.localUser` nor
    /// `.remote` (so its patch is `.other`, which every surface applies), and
    /// returns whether anything changed. The same journal-before-publication
    /// barrier as `applyStructural`: the step's incremental bytes are persisted
    /// before the surface sees its patch, and the armed command keeps the durable
    /// owner's unjournaled-transaction guard quiet. Refused before `step` runs
    /// while composing or until a composition's rebuild is delivered, after a
    /// failed write, or with a stale revision. Returns false when nothing changed
    /// (nothing is journaled then).
    @discardableResult
    func applyHistoryStep(
        _ command: NativeEditCommand, step: () throws -> Bool, persist: (Data) throws -> Void
    ) throws -> Bool {
        try requireCompositionBoundary()
        guard composition == nil, !isDeferringComposition, deferredBlockIDs.isEmpty, !isWholeListDeferred else {
            throw DocumentEngineError.composingBlock
        }
        guard !isFlushing, revision == command.baseRevision, revision < UInt64.max else {
            throw DocumentEngineError.staleNativeCommand
        }
        guard command.kind == .undo || command.kind == .redo else { throw DocumentEngineError.unsupportedNativeInput }
        nativeCommand = command
        nativeEmission = 0
        selectionBeforeCommand = selection
        stepTransactions = []
        defer {
            selectionBeforeCommand = nil
            stepTransactions = nil
        }
        do {
            let changed = try step()
            let updates = try (stepTransactions ?? []).compactMap { try YTransactionEncoder.encodeUpdate($0) }
            // One step is one transaction, and a change always has bytes:
            // anything else cannot be journaled as one entry.
            guard updates.count <= 1, changed == !updates.isEmpty else {
                throw DocumentEngineError.unsupportedNativeInput
            }
            if let update = updates.first {
                unconfirmedNativeUpdate = update
                try persist(update)
                revision += 1
                unconfirmedNativeUpdate = nil
            }
            nativeCommand = nil
            flush()
            return changed
        } catch {
            // The step's transaction may have run: no rollback, so freeze as a
            // failed append does rather than retry against an unconfirmed graph.
            nativeCommand = nil
            nativeWriteFailed = true
            buffered = []
            throw error
        }
    }

    /// Replaces the relative selection with one captured earlier on this
    /// replica (a history step restoring the selection its step stored), with
    /// no validation: it resolves, or not, like any relative selection.
    func restoreSelection(_ selection: RelativeEditorSelection?) {
        guard !isDetached else { return }
        self.selection = selection
    }

    /// Whether `applyStructural` would accept `command` now: the same
    /// validation, nothing armed or written. The block menu's enabled state.
    func canApplyStructural(_ command: NativeEditCommand) -> Bool {
        (try? prepareStructural(command)) != nil
    }

    private typealias PreparedCommand = (write: () throws -> Data, caret: () -> EditorPosition)

    private func prepareStructural(_ command: NativeEditCommand) throws -> PreparedCommand {
        try requireCompositionBoundary()
        try requireEditableBlock(command.blockID)
        guard nativeCommand == nil, !holdingDurableRemote, !isFlushing, composition == nil,
            revision == command.baseRevision, revision < UInt64.max
        else { throw DocumentEngineError.staleNativeCommand }
        switch command.kind {
        case .moveUp, .moveDown, .duplicate, .deleteBlock, .insertBlock, .insertSubtrees:
            do {
                return try prepareBlockCommand(command)
            } catch BlockNoteSubtreePayload.Error.tooLarge {
                // Only a paste reports its size; a grown subtree refuses like any unsupported shape.
                if case .insertSubtrees = command.kind { throw DocumentEngineError.payloadTooLarge }
                throw DocumentEngineError.unsupportedNativeInput
            } catch is BlockNoteWriter.Error, is BlockNoteSubtreePayload.Error {
                throw DocumentEngineError.unsupportedNativeInput
            }
        default: break
        }
        // A prop edit (a code block's language) is the one command code accepts.
        let isPropEdit = if case .props = command.kind { true } else { false }
        let (node, units) = try structuralTarget(command.blockID, allowCode: isPropEdit)
        let write: () throws -> Data
        // Resolved after the write, against the post-write index.
        let caret: () -> EditorPosition
        func start(_ id: String) -> EditorPosition { EditorPosition(blockID: id, offset: 0, assoc: -1) }
        switch command.kind {
        case .replace:
            throw DocumentEngineError.unsupportedNativeInput
        case .split(let offset, let newID, let open):
            guard !newID.isEmpty, builder.index.entries[newID] == nil, Self.isBoundary(offset, in: units) else {
                throw DocumentEngineError.unsupportedNativeInput
            }
            let toggle = isToggle(command.blockID)
            if Self.listItemNodes.contains(node) || toggle, units.isEmpty {
                // `emptyEnterResets`: a list item or toggle list item becomes a
                // paragraph, a toggle heading a heading (`resetsTo`), children
                // kept. No block is created, so `newID` stays unused.
                write = { try self.resetOnBackspaceOrEnter(command.blockID, node: node) }
                caret = { start(command.blockID) }
            } else if units.isEmpty, try outdentsOnEmptyReturn(command.blockID, open: open) {
                // BlockNote's next Enter rule: an empty nested block outdents
                // (its parent's `emptyChildEnter` is "outdent"). One command.
                write = try lift(command.blockID)
                caret = { start(command.blockID) }
            } else {
                // A toggle keeps its children (closed: `splitKeepsChildren`;
                // open: the text goes into a new first child), so none move.
                if !toggle { try requireMovableChildren(command.blockID) }
                let toggleOpen = toggle ? open.contains(command.blockID) : nil
                write = {
                    try self.writer.splitBlock(block: command.blockID, at: offset, newID: newID, toggleOpen: toggleOpen)
                }
                // At the start of non-empty text the writer inserts the empty
                // block above, so the caret stays with the text, under the old id.
                caret = { start(offset == 0 && !units.isEmpty ? command.blockID : newID) }
            }
        case .join:
            if node != "paragraph" {
                write = { try self.resetOnBackspaceOrEnter(command.blockID, node: node) }
                caret = { start(command.blockID) }
                break
            }
            // BlockNote's `mergeBlocksCommand`: into the block above (the
            // previous sibling's last descendant, or a first child's parent).
            // A nested block outdents only when that merge cannot happen.
            let index = builder.index
            guard let entry = index.entries[command.blockID], let position = index.position[command.blockID],
                position > 0
            else { throw DocumentEngineError.unsupportedNativeInput }
            let previousID = index.order[position - 1]
            let firstChild =
                entry.depth > 0 && index.groupOrder[ObjectIdentifier(entry.group)]?.first == command.blockID
            // The destination is written too: it must be unlocked.
            try requireEditableBlock(previousID)
            let aboveLength: Int
            do {
                aboveLength = try structuralTarget(previousID).units.count
                try requireMovableChildren(command.blockID)
            } catch DocumentEngineError.unsupportedNativeInput where entry.depth > 0 {
                write = try lift(command.blockID)
                caret = { start(command.blockID) }
                break
            }
            if firstChild {
                write = { try self.writer.mergeIntoParent(block: command.blockID) }
                caret = { EditorPosition(blockID: previousID, offset: aboveLength, assoc: -1) }
                break
            }
            write = { try self.writer.joinBlocks(block: command.blockID) }
            // An empty block above with the same type and props is removed
            // instead and the source keeps its id: the caret is its start.
            caret = {
                self.builder.index.entries[previousID] != nil
                    ? EditorPosition(blockID: previousID, offset: aboveLength, assoc: -1) : start(command.blockID)
            }
        case .indent:
            // `sinkListItem`: under the previous sibling, which must be a
            // readable block of the same group; the moved subtree must stay
            // within `maxNestingDepth`.
            let index = builder.index
            guard let entry = index.entries[command.blockID],
                let siblings = index.groupOrder[ObjectIdentifier(entry.group)],
                let at = siblings.firstIndex(of: command.blockID), at > 0,
                let previous = index.entries[siblings[at - 1]], previous.isSimpleContainer,
                !builder.nativeSnapshot(previous).block.fidelity.isOpaque
            else { throw DocumentEngineError.unsupportedNativeInput }
            try requireEditableBlock(previous.id)
            let deepest = try requireMovable(command.blockID, including: { $0 > entry.depth })
            guard deepest <= BlockNoteWriter.maxNestingDepth else { throw DocumentEngineError.unsupportedNativeInput }
            let item = entry.containerItem
            let offset = try caretOffset(in: command.blockID)
            write = { try self.writer.sinkListItem(in: try self.writer.indexedTarget(item, id: command.blockID)) }
            caret = { EditorPosition(blockID: command.blockID, offset: offset, assoc: -1) }
        case .outdent:
            let offset = try caretOffset(in: command.blockID)
            write = try lift(command.blockID)
            caret = { EditorPosition(blockID: command.blockID, offset: offset, assoc: -1) }
        case .range(let range):
            // Every block the range touches is validated before arming: an
            // opaque block, a placeholder, code, nested children, inline nodes
            // or a toggle heading anywhere refuses the whole command.
            let index = builder.index
            guard let lower = index.position[command.blockID], let upper = index.position[range.endBlockID],
                lower <= upper, let group = index.entries[command.blockID]?.group
            else { throw DocumentEngineError.unsupportedNativeInput }
            var endUnits = units
            // A toggle's split depends on its view state: a range touching one is refused.
            guard !isToggle(command.blockID) else { throw DocumentEngineError.unsupportedNativeInput }
            for position in stride(from: lower + 1, through: upper, by: 1) {
                // Siblings of one group only: a range across depths, or over a
                // block with children it would delete, waits for subtree commands.
                guard index.entries[index.order[position]]?.group === group else {
                    throw DocumentEngineError.unsupportedNativeInput
                }
                try requireEditableBlock(index.order[position])
                endUnits = try structuralTarget(index.order[position]).units
                guard !isToggle(index.order[position]) else { throw DocumentEngineError.unsupportedNativeInput }
            }
            let lines = NativeRangeCommand.lines(of: range.replacement)
            let ids = range.newBlockIDs
            guard Self.isBoundary(range.startOffset, in: units), Self.isBoundary(range.endOffset, in: endUnits),
                lower < upper || range.startOffset < range.endOffset
                    || (range.startOffset == range.endOffset && !range.replacement.isEmpty),
                // "\n" is the only separator; the coordinator normalizes line breaks.
                !range.replacement.unicodeScalars.contains(where: {
                    $0.value == 0xfffc || ($0 != "\n" && CharacterSet.newlines.contains($0))
                }),
                ids.count == lines.count - 1, Set(ids).count == ids.count,
                ids.allSatisfy({ !$0.isEmpty && index.entries[$0] == nil }),
                let first = index.entries[command.blockID]?.containerItem,
                let last = index.entries[range.endBlockID]?.containerItem
            else { throw DocumentEngineError.unsupportedNativeInput }
            write = {
                try self.writer.replaceRange(
                    from: try self.writer.indexedTarget(first, id: command.blockID), at: range.startOffset,
                    to: try self.writer.indexedTarget(last, id: range.endBlockID), at: range.endOffset,
                    lines: lines, newIDs: ids)
            }
            caret = {
                guard let id = ids.last, let line = lines.last else {
                    return EditorPosition(
                        blockID: command.blockID, offset: range.startOffset + lines[0].utf16.count, assoc: -1)
                }
                return EditorPosition(blockID: id, offset: line.utf16.count, assoc: -1)
            }
        case .marks(let marks):
            // A mark change over a range that may span blocks. Every block with
            // text in the range is validated before arming, as `.range` does;
            // an end at the next block's start touches nothing there. Only the
            // named attributes change ("null" removes), so the text is never
            // touched and the patch is marks-only.
            let index = builder.index
            guard let lower = index.position[command.blockID], let upper = index.position[marks.endBlockID],
                lower <= upper, !marks.attributes.isEmpty,
                marks.attributes.allSatisfy({ Self.isMarkValue($0) })
            else { throw DocumentEngineError.unsupportedNativeInput }
            var segments: [(item: YItem, id: String, range: Range<Int>)] = []
            for position in lower...upper {
                let id = index.order[position]
                if position == upper, position > lower, marks.endOffset == 0 { break }
                if position > lower { try requireEditableBlock(id) }
                let blockUnits = position == lower ? units : try structuralTarget(id).units
                let start = position == lower ? marks.startOffset : 0
                let end = position == upper ? marks.endOffset : blockUnits.count
                guard Self.isBoundary(start, in: blockUnits), Self.isBoundary(end, in: blockUnits), start <= end,
                    let item = index.entries[id]?.containerItem
                else { throw DocumentEngineError.unsupportedNativeInput }
                if start < end { segments.append((item, id, start..<end)) }
            }
            guard !segments.isEmpty else { throw DocumentEngineError.unsupportedNativeInput }
            let attributes = YTextAttributes(marks.attributes.map { ($0.key, $0.valueJSON) })
            write = {
                try self.writer.transaction { _ in
                    for segment in segments {
                        let target = try self.writer.indexedTarget(segment.item, id: segment.id)
                        try self.writer.formatRange(in: target, range: segment.range, attributes: attributes)
                    }
                }
            }
            // The surface keeps the selection; this is its start.
            caret = { EditorPosition(blockID: command.blockID, offset: marks.startOffset, assoc: -1) }
        case .props(let props):
            // Its own intent, never a type change: every key must be one this
            // block type edits, with a valid value, before arming.
            guard !props.isEmpty, Set(props.map(\.key)).count == props.count,
                props.allSatisfy({ Self.isPropEdit($0, on: node) }),
                let item = builder.index.entries[command.blockID]?.containerItem
            else { throw DocumentEngineError.unsupportedNativeInput }
            write = {
                try self.writer.setBlockProps(
                    in: try self.writer.indexedTarget(item, id: command.blockID),
                    props: props.map { ($0.key, $0.value) })
            }
            caret = { start(command.blockID) }
        case .blockType(let type, let props, let removing):
            // The slash menu: a paragraph becomes one of its block types, the
            // "/query" removed in the same transaction (BlockNote clears the
            // query, then `updateBlock`s the now-empty block).
            guard node == "paragraph", Self.slashTypes.contains(type),
                props.allSatisfy({
                    ["level", "isToggleable"].contains($0.key) && type == "heading" && Self.isPropEdit($0, on: type)
                }),
                Self.isBoundary(removing.lowerBound, in: units), Self.isBoundary(removing.upperBound, in: units),
                let item = builder.index.entries[command.blockID]?.containerItem
            else { throw DocumentEngineError.unsupportedNativeInput }
            write = {
                try self.writer.transaction { _ in
                    let target = try self.writer.indexedTarget(item, id: command.blockID)
                    if !removing.isEmpty {
                        try self.writer.replaceText(
                            in: target, range: removing, with: "")
                    }
                    try self.writer.setBlockType(in: target, to: type, props: props.map { ($0.key, $0.value) })
                }
            }
            caret = { EditorPosition(blockID: command.blockID, offset: removing.lowerBound, assoc: -1) }
        case .moveUp, .moveDown, .duplicate, .deleteBlock, .insertBlock, .insertSubtrees:
            throw DocumentEngineError.unsupportedNativeInput  // prepared above
        case .undo, .redo:
            throw DocumentEngineError.unsupportedNativeInput  // `applyHistoryStep`
        }
        return (write, caret)
    }

    private static let listItemNodes: Set<String> = ["bulletListItem", "numberedListItem", "checkListItem"]

    /// BlockNote's `resetsTo` (Backspace at the start, Enter in an empty block
    /// that `emptyEnterResets`): a toggle heading becomes a regular heading
    /// (one prop), anything else a paragraph. Children stay.
    private func resetOnBackspaceOrEnter(_ blockID: String, node: String) throws -> Data {
        guard node == "heading", isToggle(blockID) else {
            return try writer.setBlockType(block: blockID, to: "paragraph")
        }
        guard let item = builder.index.entries[blockID]?.containerItem else {
            throw DocumentEngineError.unsupportedNativeInput
        }
        return try writer.setBlockProps(
            in: try writer.indexedTarget(item, id: blockID), props: [("isToggleable", .bool(false))])
    }

    /// A toggle list item or toggle heading (PR06b), by its stored props.
    private func isToggle(_ blockID: String) -> Bool {
        guard let element = builder.index.entries[blockID]?.element, case .xmlElement(let node)? = element.typeRef,
            let props = YBlockProjection.props(of: element)
        else { return false }
        return BlockNoteWriter.isToggle(node: node, props: props.map { ($0.key, $0.value) })
    }

    /// `liftListItem` for a nested block, validated: its parent is unlocked,
    /// and it, its children and the siblings after it (which become its
    /// children) are all readable and unlocked, so the clone loses nothing.
    private func lift(_ blockID: String) throws -> () throws -> Data {
        guard let entry = builder.index.entries[blockID], entry.depth > 0, let parentID = entry.parentID else {
            throw DocumentEngineError.unsupportedNativeInput
        }
        try requireEditableBlock(parentID)
        _ = try requireMovable(blockID, including: { $0 >= entry.depth })
        let item = entry.containerItem
        return { try self.writer.liftListItem(in: try self.writer.indexedTarget(item, id: blockID)) }
    }

    /// Return in an empty block: BlockNote outdents a nested one unless its
    /// parent keeps empty children (an open toggle's `emptyChildEnter` is
    /// "stay", so a new child follows; a closed one's is "outdent").
    private func outdentsOnEmptyReturn(_ blockID: String, open: Set<String>) throws -> Bool {
        guard let parentID = builder.index.entries[blockID]?.parentID else { return false }
        return !isToggle(parentID) || !open.contains(parentID)
    }

    /// A split or join copies the block's children into another container:
    /// each must be readable and unlocked.
    private func requireMovableChildren(_ blockID: String) throws {
        guard let entry = builder.index.entries[blockID], entry.nestedGroup != nil else { return }
        _ = try requireMovable(blockID, including: { $0 > entry.depth })
    }

    /// Validates every block a clone-and-delete moves: `blockID` and the
    /// blocks after it in preorder whose depth `including` accepts (stopping
    /// at the first it does not). Each must be unlocked and not opaque, so its
    /// copy is a proven lossless one. Returns the deepest depth after the move
    /// would add one level (the caller's bound).
    private func requireMovable(_ blockID: String, including: (Int) -> Bool) throws -> Int {
        let index = builder.index
        guard let start = index.position[blockID], let depth = index.entries[blockID]?.depth else {
            throw DocumentEngineError.unsupportedNativeInput
        }
        var deepest = depth + 1
        var position = start
        repeat {
            guard let entry = index.entries[index.order[position]],
                !builder.nativeSnapshot(entry).block.fidelity.isOpaque
            else { throw DocumentEngineError.unsupportedNativeInput }
            try requireEditableBlock(entry.id)
            deepest = max(deepest, entry.depth + 1)
            position += 1
        } while position < index.order.count && including(index.entries[index.order[position]]?.depth ?? -1)
        return deepest
    }

    // MARK: - Block commands (PR06d)

    /// Move, duplicate, delete, insert and lossless paste for a block and its
    /// subtree, each validated before arming. A move or duplicate needs every
    /// block of the subtree readable and unlocked (`requireMovable`): the
    /// clone is a proven lossless copy. Delete (and copy, `subtreePayload`)
    /// needs a proven lossless representation instead
    /// (`BlockNoteSubtreePayload.validate`), so an opaque block that is plain
    /// BlockNote XML can be copied or deleted but never moved; anything else
    /// is refused. Moves copy every raw value and delete the original, so a
    /// peer's concurrent edit inside the moved block lands in the deleted
    /// original (as with `sinkListItem`); identity is not preserved.
    private func prepareBlockCommand(_ command: NativeEditCommand) throws -> PreparedCommand {
        let index = builder.index
        let id = command.blockID
        guard index.isCanonical, let entry = index.entries[id], let position = index.position[id],
            let siblings = index.groupOrder[ObjectIdentifier(entry.group)], let at = siblings.firstIndex(of: id)
        else { throw DocumentEngineError.unsupportedNativeInput }
        let writer = self.writer
        let item = entry.containerItem
        // The preorder position just past the block's subtree.
        var end = position + 1
        while end < index.order.count, (index.entries[index.order[end]]?.depth ?? -1) > entry.depth { end += 1 }
        func start(_ id: String) -> EditorPosition { EditorPosition(blockID: id, offset: 0, assoc: -1) }
        func isFresh(_ ids: [String]) -> Bool {
            Set(ids).count == ids.count && ids.allSatisfy { !$0.isEmpty && index.entries[$0] == nil }
        }
        switch command.kind {
        case .moveUp, .moveDown:
            // BlockNote's `getMovePlacement`: past a sibling with children
            // into its nearest child, past the group's end out beside the parent.
            let up = command.kind == .moveUp
            let deepest = try requireMovable(id, including: { $0 > entry.depth }) - 1
            let destination: (group: YType, left: YItem?, depth: Int)
            let neighbour = up ? (at > 0 ? siblings[at - 1] : nil) : (at + 1 < siblings.count ? siblings[at + 1] : nil)
            if let neighbour, let next = index.entries[neighbour] {
                if let nested = next.nestedGroup, let kids = index.groupOrder[ObjectIdentifier(nested)],
                    let last = kids.last.flatMap({ index.entries[$0] }), !kids.isEmpty
                {
                    try requireEditableBlock(neighbour)
                    destination = (nested, up ? last.containerItem : nil, next.depth + 1)
                } else {
                    destination = (entry.group, up ? next.containerItem.left : next.containerItem, entry.depth)
                }
            } else if let parentID = entry.parentID, let parent = index.entries[parentID] {
                try requireEditableBlock(parentID)
                destination = (parent.group, up ? parent.containerItem.left : parent.containerItem, parent.depth)
            } else {
                // The document's first or last root block: BlockNote does nothing.
                throw DocumentEngineError.unsupportedNativeInput
            }
            guard destination.depth + deepest - entry.depth <= BlockNoteWriter.maxNestingDepth else {
                throw DocumentEngineError.unsupportedNativeInput
            }
            let offset = try caretOffset(in: id)
            return (
                { try writer.moveBlock(item, id: id, into: destination.group, after: destination.left) },
                { EditorPosition(blockID: id, offset: offset, assoc: -1) }
            )
        case .duplicate(let newIDs):
            _ = try requireMovable(id, including: { $0 > entry.depth })
            let copy = try writer.snapshot(entry.container, block: id, depth: 0)
            _ = try BlockNoteSubtreePayload.validate([copy])
            guard newIDs.count == copy.containerCount, isFresh(newIDs) else {
                throw DocumentEngineError.unsupportedNativeInput
            }
            var ids = newIDs[...]
            let duplicate = try copy.replacingIDs(&ids)
            let offset = try caretOffset(in: id)
            return (
                { try writer.insertBlocks([duplicate], into: entry.group, after: item) },
                { EditorPosition(blockID: id, offset: offset, assoc: -1) }
            )
        case .deleteBlock:
            // The document keeps one block.
            guard entry.depth > 0 || siblings.count > 1 else { throw DocumentEngineError.unsupportedNativeInput }
            for p in position..<end { try requireEditableBlock(index.order[p]) }
            _ = try BlockNoteSubtreePayload.validate([try writer.snapshot(entry.container, block: id, depth: 0)])
            let next = end < index.order.count ? index.order[end] : nil
            let previous = position > 0 ? index.order[position - 1] : nil
            return (
                { try writer.deleteBlock(item, id: id) },
                {
                    next.map(start)
                        ?? EditorPosition(blockID: previous ?? id, offset: self.textLength(previous ?? id), assoc: -1)
                }
            )
        case .insertBlock(let newID, let before):
            guard isFresh([newID]) else { throw DocumentEngineError.unsupportedNativeInput }
            let paragraph = BlockNoteWriter.Copy.element(
                "blockContainer", [("id", .string(newID))],
                [.element("paragraph", writer.schemas["paragraph"] ?? [], [])])
            let left = before ? item.left : item
            return ({ try writer.insertBlocks([paragraph], into: entry.group, after: left) }, { start(newID) })
        case .insertSubtrees(let payload):
            // The payload is untrusted (any app's pasteboard): decoded, bounded
            // and validated here, and every container gets a fresh id.
            let copies = try BlockNoteSubtreePayload.decode(payload)
            let shape = try BlockNoteSubtreePayload.validate(copies)
            let newIDs = (0..<shape.blocks).map { _ in UUID().uuidString }
            guard let last = newIDs.last, isFresh(newIDs),
                entry.depth + shape.depth <= BlockNoteWriter.maxNestingDepth
            else { throw DocumentEngineError.unsupportedNativeInput }
            var ids = newIDs[...]
            let fresh = try copies.map { try $0.replacingIDs(&ids) }
            // ProseMirror's paste into an empty textblock replaces it.
            let replaces =
                entry.nestedGroup == nil && entry.isSimpleContainer
                && entry.element?.typeRef == .xmlElement(nodeName: "paragraph")
                && (entry.isSimpleText || entry.element?.length == 0) && entry.runs.allSatisfy { $0.text.isEmpty }
            return (
                { try writer.insertBlocks(fresh, into: entry.group, after: item, replacing: replaces ? item : nil) },
                { EditorPosition(blockID: last, offset: self.textLength(last), assoc: -1) }
            )
        default:
            throw DocumentEngineError.unsupportedNativeInput
        }
    }

    /// The UTF-16 length of an indexed block's text (0 when it has none).
    private func textLength(_ blockID: String) -> Int {
        builder.index.entries[blockID]?.runs.reduce(0) { $0 + $1.text.utf16.count } ?? 0
    }

    /// Whether the block's whole subtree has a proven lossless representation
    /// (what Copy block needs), without encoding a payload.
    func hasLosslessCopy(_ blockID: String) -> Bool {
        guard !isDetached, !nativeWriteFailed, builder.index.isCanonical,
            let entry = builder.index.entries[blockID],
            let copy = try? writer.snapshot(entry.container, block: blockID, depth: 0)
        else { return false }
        return (try? BlockNoteSubtreePayload.validate([copy])) != nil
    }

    /// The lossless transfer payload for these blocks' whole subtrees
    /// (`BlockNoteSubtreePayload`), or nil when any has no proven lossless
    /// representation. Reads only.
    func subtreePayload(_ blockIDs: [String]) -> Data? {
        guard !isDetached, !nativeWriteFailed, builder.index.isCanonical, !blockIDs.isEmpty else { return nil }
        return try? BlockNoteSubtreePayload.encode(
            blockIDs.map { id in
                guard let entry = builder.index.entries[id] else { throw DocumentEngineError.unsupportedNativeInput }
                return try writer.snapshot(entry.container, block: id, depth: 0)
            })
    }

    /// The selection head's offset when it is in `blockID`, else 0. A tree
    /// move changes no text, so the caret keeps its offset in the clone.
    private func caretOffset(in blockID: String) throws -> Int {
        guard let head = try currentSelection()?.head, head.blockID == blockID else { return 0 }
        return head.offset
    }

    /// What the slash menu converts a paragraph into (a toggle heading is a
    /// heading with `isToggleable`). Divider and media wait for later slices.
    static let slashTypes: Set<String> = [
        "paragraph", "heading", "bulletListItem", "numberedListItem", "checkListItem", "quote", "codeBlock",
        "toggleListItem",
    ]

    /// A prop a `.props` command may write on `node`, with BlockNote 0.56's
    /// value type. Anything else (an unknown key, another type's prop, a
    /// malformed value) would make the block lossy, so it is refused.
    private static func isPropEdit(_ prop: ProjectedProp, on node: String) -> Bool {
        switch (node, prop.key, prop.value) {
        case ("checkListItem", "checked", .bool): return true
        // `undefined` is BlockNote's unset start: the list counts from 1.
        case ("numberedListItem", "start", .undefined): return true
        case ("numberedListItem", "start", .int(let start)): return (1...999_999).contains(start)
        case ("heading", "level", .int(let level)): return (1...6).contains(level)
        case ("heading", "isToggleable", .bool): return true
        case ("codeBlock", "language", .string(let language)):
            return (1...64).contains(language.count)
                && !language.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
                && !language.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        case ("callout", "emoji", .string(let emoji)):
            return emoji.count == 1 && emoji.unicodeScalars.count <= 16
                && emoji.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 0x7f }
        default: return false
        }
    }

    /// A mark a command may write: a key and either "null" (removal) or a JSON
    /// object, with a readable href for a link. Anything else would make the
    /// block unprojectable after the write.
    private static func isMarkValue(_ mark: TextMark) -> Bool {
        guard !mark.key.isEmpty else { return false }
        if mark.valueJSON == "null" { return true }
        if mark.key == "link" { return YBlockProjection.linkHref(from: mark.valueJSON) != nil }
        return mark.valueJSON.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
            is [String: Any]
    }

    /// A UTF-16 offset in `units` that does not split a surrogate pair.
    private static func isBoundary(_ offset: Int, in units: [UInt16]) -> Bool {
        guard offset >= 0, offset <= units.count else { return false }
        return offset == 0 || offset == units.count
            || !(0xd800...0xdbff).contains(units[offset - 1]) || !(0xdc00...0xdfff).contains(units[offset])
    }

    /// A block a structural command may address: a writable simple text, or an
    /// empty text-capable element the writer gives an XmlText on first insert,
    /// at any depth. Inline nodes, opaque/scrubbed content and code stay refused.
    private func structuralTarget(_ blockID: String, allowCode: Bool = false) throws -> (node: String, units: [UInt16])
    {
        guard builder.index.isCanonical, let entry = builder.index.entries[blockID],
            entry.isProjectable,
            !builder.nativeSnapshot(entry).block.fidelity.isOpaque,
            entry.isSimpleContainer, let element = entry.element,
            case .xmlElement(let node)? = element.typeRef,
            writer.schemas[node] != nil, allowCode || node != "codeBlock",
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
            // A join writes the source and the previous sibling's last
            // descendant, the block before it in preorder; its children move
            // into its place.
            let index = builder.index
            if let position = index.position[block], let depth = index.entries[block]?.depth {
                if position > 0 { try requireEditableBlock(index.order[position - 1]) }
                var next = position + 1
                while next < index.order.count, let entry = index.entries[index.order[next]], entry.depth > depth {
                    try requireEditableBlock(entry.id)
                    next += 1
                }
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

    /// `currentSelection` endpoint by endpoint, so a surface can fall back from
    /// one whose block disappeared to the one that survived. Nil when there is
    /// no selection.
    func currentSelectionEndpoints() throws -> (anchor: EditorPosition?, head: EditorPosition?)? {
        try requireAttached()
        return selection.map {
            ($0.anchor.resolve(in: doc, index: builder.index), $0.head.resolve(in: doc, index: builder.index))
        }
    }

    // MARK: - Awareness (PR10)

    /// The selection as y-prosemirror's cursor field: the relative positions
    /// captured when it was set, direction kept. Never writes the replica.
    func awarenessCursor() -> AwarenessCursor? {
        guard !isDetached, let selection else { return nil }
        return AwarenessCursor(anchor: selection.anchor.relative.json, head: selection.head.relative.json)
    }

    /// `position` as a relative position a peer could publish (tests and the
    /// UI test host's fake peer).
    func awarenessPosition(_ position: EditorPosition) -> YRelativePositionJSON? {
        guard !isDetached else { return nil }
        return (try? RelativeEditorPosition(position, index: builder.index))?.relative.json
    }

    /// Where a peer's published position lands, or nil when it cannot be shown.
    /// The position is untrusted wire data: a root name that does not exist is
    /// never resolved (yjs's `doc.get` would create it), a malformed position
    /// is nil (never `replicaFailSafe`), and nothing here writes the replica.
    /// Text inside a block's own `XmlText` is a caret place; anything else in
    /// a block (inline nodes, a table cell, a column, a preview) is the block.
    func peerPlace(_ json: YRelativePositionJSON) -> PeerCursorPlace? {
        guard !isDetached else { return nil }
        let relative = YRelativePosition(json: json)
        if relative.item == nil, let tname = relative.tname, doc.share[tname] == nil { return nil }
        guard let absolute = try? relative.resolve(in: doc), absolute.type.item?.deleted != true,
            let index = Int(exactly: absolute.index), let blockID = builder.index.blockID(for: absolute.type),
            let entry = builder.index.entries[blockID]
        else { return nil }
        let length = entry.textType.flatMap { Int(exactly: $0.length) } ?? 0
        if entry.isProjectable, let text = entry.textType, absolute.type === text {
            return .text(EditorPosition(blockID: blockID, offset: min(index, length), assoc: absolute.assoc))
        }
        // Between the content element's children (y-prosemirror's position in
        // an empty paragraph, or before/after its text).
        if entry.isProjectable, entry.isSimpleContainer, let element = entry.element, absolute.type === element,
            entry.textType != nil || element.length == 0
        {
            return .text(EditorPosition(blockID: blockID, offset: index == 0 ? 0 : length, assoc: absolute.assoc))
        }
        return .block(blockID)
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
            case .xmlElement(let node)? = element.typeRef, writer.schemas[node] != nil
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
        case .committed(let update, _): return update
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
        selectionBeforeCommand = selection
        defer { selectionBeforeCommand = nil }
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
            return .committed(update, foldsOtherChanges: true)
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
        // It is the commit's echo: stamped with its command.
        let folds = composition?.foldsOtherChanges ?? true
        finishComposition(
            origin: .other,
            echo: NativePatchStamp(commandID: command.id, baseRevision: command.baseRevision, emission: nativeEmission))
        return .committed(update, foldsOtherChanges: folds || isWholeListDeferred)
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

    private func finishComposition(origin: BlockPatchOrigin, echo: NativePatchStamp? = nil) {
        guard let composing = composition else { return }
        let change: BlockChange
        if !composing.requiresReset, builder.index.isCanonical,
            let entry = builder.index.entries[composing.blockID]
        {
            change = .replaceBlock(blockID: entry.id, block: BlockSnapshot(builder.nativeSnapshot(entry)))
        } else {
            change = .reset(
                NativeBlockProjection.project(doc, generation: builder.index.generation).blocks.map(BlockSnapshot.init))
        }
        composition = nil
        buffered.append(.patch(BlockPatch([change], origin: origin, nativeCommand: echo)))
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
        stepTransactions?.append(transaction)
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
    // detach() reaches the surface through a `@preconcurrency` conformance; the last
    // strong reference must drop on the surface's domain (main today; PR08b's actor
    // must detach explicitly before the engine leaves it).
    deinit {
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
enum CompositionCommitResult: Equatable, Sendable {
    /// `foldsOtherChanges`: the final rebuild also carries changes the
    /// composition discarded (or a reset), not only the composed text.
    case committed(Data, foldsOtherChanges: Bool)
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
    /// A paste payload past `BlockNoteSubtreePayload`'s bounds (bytes, blocks or
    /// structs). A malformed one is `.unsupportedNativeInput`.
    case payloadTooLarge
}
