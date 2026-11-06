import Foundation

// MARK: - Local BlockNote write path (B6)

/// Builds a whole BlockNote block as **local** `YItem`s and drives the block-level
/// diff, producing an incremental v1 update from a `YDoc` replica the caller owns.
///
/// This is the write side of the live-editing bridge (Milestone C): the editor's
/// blocks are diffed against the last-known blocks and the difference applied as
/// local operations inside one local transaction, so a real yjs peer sees exactly
/// the ops the user made — not a fresh full-document overwrite.
///
/// **The from-empty byte-identity anchor.** `applyEdit(old: [], new: blocks)` must
/// be byte-identical to `BlockNoteYjs.encode(blocks, clientID:)` — the shipping
/// golden encoder, already proven byte-for-byte against real yjs (`YjsEncoderTests`).
/// This is B6's strongest correctness gate: it proves the builder reproduces the
/// exact document shape yjs authors — item order, origins, parents, clocks —
/// because both encode the same store. To keep that guarantee, `insertBlock` mints
/// items in the **same order** `BlockNoteYjs.encode`/`emitInline` do: blockGroup
/// first, then per block the container, the content element, the `xmlText` and its
/// run pieces (if any), the props on the element, then the `id` on the container.
/// Each `YWrite` primitive mints at `store.getState(clientID)` sequentially, so
/// minting in this order makes every clock/origin/parent — and therefore the
/// encoded bytes — coincide with the golden encoder.
///
/// Pure value code (no concurrency annotations), but it **mutates** the live
/// replica graph, so every entry point runs inside an open transaction owned by the
/// replica's single owner (`YDoc.transact`). See `AGENTS.md`, "The Yjs CRDT core".
enum BlockNoteWrite {
    /// The BlockNote fragment root — one `document-store` XmlFragment.
    static let fragmentField = BlockNoteYjs.fragmentField

    /// Which in-place reconcile a surviving block uses — the split gate of plan
    /// decision 6. Insertion is shared: both paths build a new block with
    /// `insertBlock`/`insertContentElement`, so from-empty and new-block insertion
    /// stay byte-identical to the golden encoder on either path.
    enum Reconcile {
        /// The intent writer (`BlockNoteWriter`): text through `replaceText`, props
        /// and kind changes through `setBlockType`. The **live** path
        /// (`DocumentCollaborationManager.applyLocalEdit`).
        case writer
        /// The hand-authored reconcile (`TextSpanDiff` + `YWrite`): the **Docs 6
        /// incremental save** (`BlockNoteIncrementalSave`), which is not re-pointed
        /// in phase 1 and must keep its bytes.
        case legacy
    }

    /// Diff `old` → `new` BlockNote blocks, apply the difference as local ops inside
    /// one local transaction against `doc`, and return the incremental v1 update
    /// (only structs/clocks minted and ranges deleted by this transaction).
    /// `old == []` ⇒ from-empty, whose bytes equal
    /// `BlockNoteYjs.encode(new, clientID: doc.clientID)`.
    ///
    /// This is the **live** entry point: a surviving block is reconciled through
    /// `BlockNoteWriter`'s intents (see `Reconcile.writer`). `BlockNoteIncrementalSave`
    /// calls `applyEditLegacy` instead.
    ///
    /// Throws `YIntegrationError` if integration or encoding hits a malformed state;
    /// the caller (the collaboration session, C2) turns that into `failSafe`.
    ///
    /// `allowsNestedInserts` is the Docs 6 incremental save's opt-in
    /// (`BlockNoteIncrementalSave`) to write nested lists as freshly inserted subtrees.
    /// It defaults to `false`, which keeps the live (C2c) path's backstop: a nested `new`
    /// block throws there, so the live caller downgrades to classic instead of
    /// broadcasting a nested `blockGroup` the projection reads back as opaque.
    static func applyEdit(
        old: [BlockNoteBlock], new: [BlockNoteBlock], to doc: YDoc, allowsNestedInserts: Bool = false
    ) throws -> Data {
        try apply(old: old, new: new, to: doc, allowsNestedInserts: allowsNestedInserts, reconcile: .writer)
    }

    /// The **Docs 6 save** entry point: identical to `applyEdit` except that a
    /// surviving block is reconciled by the hand-authored `TextSpanDiff` + `YWrite`
    /// path, byte-for-byte as before the writer landed. Plan decision 6 keeps this
    /// path on the legacy reconcile for phase 1; its bytes are pinned by
    /// `BlockNoteIncrementalSaveTests`.
    static func applyEditLegacy(
        old: [BlockNoteBlock], new: [BlockNoteBlock], to doc: YDoc, allowsNestedInserts: Bool = false
    ) throws -> Data {
        try apply(old: old, new: new, to: doc, allowsNestedInserts: allowsNestedInserts, reconcile: .legacy)
    }

    private static func apply(
        old: [BlockNoteBlock], new: [BlockNoteBlock], to doc: YDoc, allowsNestedInserts: Bool,
        reconcile: Reconcile
    ) throws -> Data {
        // `old` is the replica's projection, which is one flat level: a nested `old`
        // block has no live counterpart to map, so refusing is a backstop (the live
        // caller downgrades to classic). A `new` block may carry children only when the
        // caller opts in (the Docs 6 save writes nested lists) — and then only as a
        // freshly *inserted* subtree, never a reconciled one (see `applyBlocks`).
        guard !old.contains(where: { !$0.children.isEmpty }) else { throw YIntegrationError.unexpectedCase }
        guard allowsNestedInserts || !new.contains(where: { !$0.children.isEmpty }) else {
            throw YIntegrationError.unexpectedCase
        }
        // Retain the existing transaction, then encode only after cleanup has
        // filled afterState and finished gc/merging (yjs's update-event timing).
        let transaction = try doc.transact(local: true, origin: .localUser) { tx in
            let root = doc.get(fragmentField)
            let group = try ensureBlockGroup(tx, root: root)
            try applyBlocks(tx, doc: doc, group: group, old: old, new: new, reconcile: reconcile)
            return tx
        }
        // Preserve the Data API: no change is the canonical empty v1 update.
        return try YTransactionEncoder.encodeUpdate(transaction) ?? Data([0, 0])
    }

    // MARK: - Block subtree builder

    /// The `blockGroup` xmlElement child of the fragment root; create it if absent
    /// (the from-empty case). yjs's BlockNote schema wraps every block in a single
    /// `blockGroup` under the root, and it is the **first** item the golden encoder
    /// mints — so it must be minted first here too.
    ///
    /// A replica seeded from the golden initial update carries the `blockGroup` as
    /// the first child of the root, but the lookup is deliberately **robust**: it
    /// scans the root's *undeleted* list children for the canonical `blockGroup`
    /// element rather than trusting `root.start`, which can name a tombstone once
    /// content has been deleted. The create branch (from-empty) is byte-identical
    /// to before — nothing but the lookup changed.
    private static func ensureBlockGroup(_ tx: YTransaction, root: YType) throws -> YType {
        for child in liveListChildren(of: root) {
            if case .type(let group) = child.content, group.typeRef == .xmlElement(nodeName: "blockGroup") {
                return group
            }
        }
        let group = YType(typeRef: .xmlElement(nodeName: "blockGroup"))
        try YWrite.insertAfter(tx, into: root, after: nil, [.type(group)])
        return group
    }

    /// Insert a fresh block subtree as a list child of `group` immediately after
    /// `left`, returning the container item minted (the new `left` for the next
    /// block). The mint order mirrors `BlockNoteYjs.encode` exactly:
    ///
    /// 1. the `blockContainer` (list child of `group`, chained after `left`);
    /// 2. the content `element` (nodeName = `block.node`, first child of container);
    /// 3. if `hasTextChild`: the `xmlText` (first child of element) and its run
    ///    pieces (`InlineContent.pieces`, the shared open/carry/close sequence);
    /// 4. the block's props as `.any([value])` map entries **on the element**;
    /// 5. if the block has children: a nested `blockGroup` as the container's list child
    ///    right after the element, then each child block inside it, recursively;
    /// 6. the `id` as `.any([.string(id)])` map entry **on the container**.
    ///
    /// Steps 2–4 are shared verbatim with `reconcileBlockLegacy`'s kind-change branch
    /// via `insertContentElement`. Step 5 mirrors `BlockNoteYjs.encode`'s `emitGroup`, whose
    /// nested group takes the element as its left origin — pinned by the from-empty anchor
    /// for a nested list (`BlockNoteWriteTests`).
    private static func insertBlock(
        _ tx: YTransaction, group: YType, after left: YItem?, _ block: BlockNoteBlock
    ) throws -> YItem? {
        let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
        let last = try YWrite.insertAfter(tx, into: group, after: left, [.type(container)])
        let element = try insertContentElement(tx, into: container, block)
        if !block.children.isEmpty {
            let childGroup = YType(typeRef: .xmlElement(nodeName: "blockGroup"))
            try YWrite.insertAfter(tx, into: container, after: element, [.type(childGroup)])
            var childLeft: YItem?
            for child in block.children {
                childLeft = try insertBlock(tx, group: childGroup, after: childLeft, child)
            }
        }
        // The `id` lives on the container, minted after its content element (and any
        // nested group) for byte parity with `BlockNoteYjs.encode`.
        try YWrite.mapSet(tx, on: container, key: "id", .any([.string(block.id)]))
        return last
    }

    /// Build a block's content element as the **head** child of `container`
    /// (`after: nil`): the content `element` (nodeName = `block.node`), then — for a
    /// text block — its `xmlText` child and run pieces, then the block's props as
    /// `.any([value])` map entries **on the element** (a leaf `image` still carries
    /// its props). Shared verbatim by `insertBlock` (into a fresh container) and
    /// `reconcileBlockLegacy`'s kind-change branch (into the surviving container,
    /// after the old element was deleted).
    ///
    /// The mint order — element, text, run pieces, props — is load-bearing: it is
    /// what the from-empty byte-identity anchor (`BlockNoteWriteTests`) pins against
    /// `BlockNoteYjs.encode`. Do not reorder. Returns the element's item, the left origin of
    /// a nested `blockGroup`.
    @discardableResult
    private static func insertContentElement(
        _ tx: YTransaction, into container: YType, _ block: BlockNoteBlock
    ) throws -> YItem {
        let element = YType(typeRef: .xmlElement(nodeName: block.node))
        guard let elementItem = try YWrite.insertAfter(tx, into: container, after: nil, [.type(element)]) else {
            throw YIntegrationError.unexpectedCase
        }

        if block.hasTextChild {
            let text = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: element, after: nil, [.type(text)])
            let pieces = InlineContent.pieces(for: block.runs)
            try YWrite.insertAfter(tx, into: text, after: nil, pieces.map(content(of:)))
        }

        for prop in block.props {
            try YWrite.mapSet(tx, on: element, key: prop.key, .any([prop.value]))
        }
        return elementItem
    }

    /// Map one `InlinePiece` (the shared inline shape) to the live `YContent` an
    /// item holds: a string becomes UTF-16 code units (JS `String.length`
    /// semantics), a format becomes a `ContentFormat` carrying its raw JSON value.
    private static func content(of piece: InlinePiece) -> YContent {
        switch piece {
        case .string(let s): return .string(Array(s.utf16))
        case .format(let key, let valueJSON): return .format(key: key, valueJSON: valueJSON)
        }
    }

    // MARK: - Live-replica accessors

    /// Undeleted list children of `type`, in list order — walk `start` via `right`,
    /// skipping tombstones. yjs list children are always countable types (a text
    /// type's non-countable `ContentFormat` items live *inside* an `xmlText`, never
    /// in these list positions), so no countable filter is needed; this matches
    /// `YBlockProjection`'s own list walk, so the containers seen here line up
    /// one-to-one with the blocks the projection produces.
    private static func liveListChildren(of type: YType) -> [YItem] {
        var result: [YItem] = []
        var item = type.start
        while let current = item {
            if !current.deleted { result.append(current) }
            item = current.right
        }
        return result
    }

    /// The content element item of a `blockContainer` — its first undeleted list
    /// child (the `paragraph`/`heading`/… element). nil only for a malformed
    /// container with no live element child.
    private static func contentElementItem(of container: YType) -> YItem? {
        liveListChildren(of: container).first
    }

    /// The `xmlText` of a content element whose only undeleted list child is that
    /// `xmlText`. nil for a leaf element (`divider`, `image`), an element with no text
    /// child, or one whose inline content is split across several children (an inline node
    /// such as the web's document link sits *between* two `xmlText`s).
    private static func soleXmlText(of element: YType) -> YType? {
        let children = liveListChildren(of: element)
        guard children.count == 1, case .type(let type) = children[0].content, type.typeRef == .xmlText else {
            return nil
        }
        return type
    }

    // MARK: - Block-level diff

    /// Apply the `old` → `new` block difference to `group` as local ops — the
    /// inverse of the read-side `liveChangeSet`, matched by `BlockNoteBlock.id`.
    ///
    /// The caller's contract is `old == the current projection of the replica`, so
    /// `group`'s undeleted `blockContainer` children align one-to-one with `old` in
    /// list order — that is how each `old` id is mapped to its live container. The
    /// diff is then:
    ///
    /// - **remove** (an `old` id gone from `new`): delete the container.
    ///   `ContentType.delete` cascades to the element, its text, runs and props, and
    ///   the `id` map entry.
    /// - **insert** (a `new` id absent from `old`): build a fresh subtree after the
    ///   running `left` (Task 7's `insertBlock`).
    /// - **survivor in place**: `reconcileBlock` applies only what changed — a kind
    ///   swap, changed/added props, or an in-place text span replace — keeping the
    ///   container and its `id`. Which reconcile does it is the split gate: the
    ///   writer's intents on the live path, the legacy splice on the Docs 6 save.
    /// - **survivor moved**: v1 rebuilds it whole (delete + re-insert after `left`).
    ///   Reorders are rare and snapshot-covered, so this trades minimality for
    ///   simplicity; `keptSurvivors` decides which survivors are in place vs moved.
    ///
    /// `old == []` ⇒ every block is an insert appended in order, which is the
    /// from-empty path the byte-identity anchor pins — unchanged by this diff.
    private static func applyBlocks(
        _ tx: YTransaction, doc: YDoc, group: YType, old: [BlockNoteBlock], new: [BlockNoteBlock],
        reconcile: Reconcile
    ) throws {
        // Map each `old` block id to its live `blockContainer` item by position.
        let containers = liveListChildren(of: group)
        var containerByID: [String: YItem] = [:]
        for (index, container) in containers.enumerated() where index < old.count {
            containerByID[old[index].id] = container
        }

        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newIDs = Set(new.map(\.id))

        // Removes first: a container whose id is gone from `new`.
        for block in old where !newIDs.contains(block.id) {
            containerByID[block.id]?.delete(tx)
        }

        // Which surviving ids keep their live position; the rest are moved (rebuilt).
        let keptIDs = keptSurvivors(old: old, new: new)

        // Walk `new` in order, threading `left` so inserts and moves land in place.
        var left: YItem?
        for block in new {
            if let existing = oldByID[block.id], let container = containerByID[block.id] {
                // A survivor whose new block has children is rebuilt, never reconciled:
                // reconciling edits the container's element only and would drop the subtree.
                if keptIDs.contains(block.id), block.children.isEmpty {
                    try reconcileBlock(
                        tx, doc: doc, container: container, old: existing, new: block, reconcile: reconcile)
                    left = container
                } else {
                    container.delete(tx)  // a moved survivor: rebuild whole after `left`
                    left = try insertBlock(tx, group: group, after: left, block)
                }
            } else {
                left = try insertBlock(tx, group: group, after: left, block)
            }
        }
    }

    /// The surviving block ids that keep their live position — a greedy common
    /// subsequence of the current order (`old`, minus removed ids) and the target
    /// order (`new`, minus inserted ids). Ids **not** returned are survivors whose
    /// relative order changed; they are re-inserted at their new position by
    /// `applyBlocks`. Greedy (not longest) is deliberate: the result is always a
    /// valid common subsequence — kept ids share the same relative order in both —
    /// so moving the complement yields the correct final order; it may just move one
    /// or two more containers than a minimal LCS would, which is immaterial for the
    /// rare reorder case.
    private static func keptSurvivors(old: [BlockNoteBlock], new: [BlockNoteBlock]) -> Set<String> {
        let oldIDs = Set(old.map(\.id))
        let newIDs = Set(new.map(\.id))
        let currentOrder = old.map(\.id).filter { newIDs.contains($0) }  // survivors, current order
        let targetOrder = new.map(\.id).filter { oldIDs.contains($0) }  // survivors, target order

        var kept: Set<String> = []
        var cursor = currentOrder.startIndex
        for id in targetOrder {
            guard let index = currentOrder[cursor...].firstIndex(of: id) else { continue }
            kept.insert(id)
            cursor = currentOrder.index(after: index)
        }
        return kept
    }

    /// Reconcile a surviving block in place, keeping its `blockContainer` and `id`.
    ///
    /// `Reconcile.writer` (the live path) hands the block to `BlockNoteWriter`'s
    /// intents; `Reconcile.legacy` (the Docs 6 save) keeps the hand-authored
    /// `TextSpanDiff` + `YWrite` reconcile below, byte-for-byte.
    ///
    /// Two kinds of survivor fall back to the legacy reconcile on the writer path:
    ///
    /// - **A block type the writer does not edit** (`quote`, `divider`, `image` —
    ///   the projection models them, so the live path can reach them, but
    ///   `BlockNoteWriter.propSchemas` has no intents for them). The alternative is
    ///   a throw, which the manager turns into a fail-safe and a permanent
    ///   downgrade to classic for the document.
    /// - **A block whose element holds an inline node** (`interlinkingLinkInline`,
    ///   mention, math, hard break). The projection folds an interlink into a run
    ///   whose text is its title while the live element counts it as one unit, so
    ///   run-space offsets don't map to live offsets; mention, math and hard break
    ///   project as opaque and never reach the live path (the fallback is defensive
    ///   for them). The legacy reconcile rebuilds the element instead of splicing,
    ///   exactly as before; for an interlink that rebuild writes a plain link mark,
    ///   a pre-existing limitation documented in docs/architecture.md.
    ///
    /// Both fallbacks are the same code the live path ran before, so they cannot
    /// change a document.
    private static func reconcileBlock(
        _ tx: YTransaction, doc: YDoc, container: YItem, old: BlockNoteBlock, new: BlockNoteBlock,
        reconcile: Reconcile
    ) throws {
        guard reconcile == .writer, BlockNoteWriter.propSchemas[old.node] != nil,
            BlockNoteWriter.propSchemas[new.node] != nil,
            case .type(let containerType) = container.content,
            let element = contentElement(of: containerType), !hasInlineNodes(of: element)
        else {
            try reconcileBlockLegacy(tx, container: container, old: old, new: new)
            return
        }
        try reconcileBlockWithWriter(doc: doc, container: container, old: old, new: new)
    }

    /// The live reconcile, authored as `BlockNoteWriter` intents inside the caller's
    /// transaction (the writer's own `transaction` sees an open transaction and
    /// returns the empty update, so the whole edit stays one transaction and one
    /// broadcast):
    ///
    /// - **props, same type** — `setBlockType` with only the props that differ
    ///   between `old` and `new`, on the existing element (BlockNote's
    ///   `updateBlock`). Reconciling against `old` rather than the live element
    ///   matters: a remote edit may have changed a prop the editor's `old` still
    ///   shows the old value for, and the editor's unchanged `new` must not write
    ///   it back.
    /// - **kind change** — `setBlockType` replaces the content element, keeping the
    ///   container, `id` and any nested group.
    /// - **text change** — `TextSpanDiff` still decides *what* changed (the minimal
    ///   visible range and the kept suffix); the writer's `replaceText` performs it,
    ///   one intent per run of the inserted span, with explicit marks so the span
    ///   never inherits a mark open at the caret.
    ///
    /// The block is resolved once (`find` is a whole-document walk) and the
    /// resolved target is passed to every intent; a kind change replaces the
    /// element, so it re-resolves before the text intents.
    private static func reconcileBlockWithWriter(
        doc: YDoc, container: YItem, old: BlockNoteBlock, new: BlockNoteBlock
    ) throws {
        // An untouched survivor writes nothing: return before the whole-document
        // `find` and the guard, so a keystroke costs O(1) per untouched block, as legacy did.
        let oldProps = Dictionary(old.props.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        let props = old.node == new.node ? new.props.filter { oldProps[$0.key] != $0.value } : new.props
        if old.node == new.node, props.isEmpty, old.runs == new.runs { return }
        // The container is the authority on the block's id: the caller's `old`/`new`
        // ids can be stale (the editor re-identifies a row after a remote structural
        // change while the replica keeps the server's id), and the legacy reconcile
        // never rewrote a survivor's id either. Addressing the live id keeps the
        // writer on the block the positional mapping already paired.
        guard case .type(let containerType) = container.content,
            let element = contentElement(of: containerType),
            let id = liveID(of: containerType)
        else { throw YIntegrationError.unexpectedCase }
        // `old` must be this block's current projection. The writer clamps a range
        // (editor safety), so a lying `old` would silently rewrite the wrong span
        // instead of failing — the legacy path threw here, and the caller's
        // fail-safe contract depends on it. Skipped for inline-node blocks, which
        // never reach this path (their run space is not the live index space).
        guard visibleLength(of: element) == TextSpanDiff.marked(old.runs).units.count else {
            throw YIntegrationError.unexpectedCase
        }
        let writer = BlockNoteWriter(doc: doc)
        var target = try writer.find(id)
        if old.node != new.node || !props.isEmpty {
            try writer.setBlockType(in: target, to: new.node, props: props)
            if old.node != new.node { target = try writer.find(id) }
        }
        guard old.runs != new.runs, let change = TextSpanDiff.diff(old: old.runs, new: new.runs) else { return }
        try writer.replaceText(
            in: target, range: NSRange(location: change.deleteRange.lowerBound, length: change.deleteRange.count),
            with: "")
        // The inserted span is `new`'s units between the common prefix and the kept
        // suffix — the same boundaries the diff chose, so a surrogate pair is never
        // split. Slicing `new`'s own runs keeps each run's mark order.
        let suffix = TextSpanDiff.marked(old.runs).units.count - change.deleteRange.upperBound
        let span = change.deleteRange.lowerBound..<(TextSpanDiff.marked(new.runs).units.count - suffix)
        var offset = span.lowerBound
        for run in runs(new.runs, range: span) {
            try writer.replaceText(
                in: target, range: NSRange(location: offset, length: 0), with: run.text,
                marks: attributes(run.marks))
            offset += run.text.utf16.count
        }
    }

    /// The container's content element, or nil when the container is malformed.
    private static func contentElement(of container: YType) -> YType? {
        guard let item = contentElementItem(of: container), case .type(let element) = item.content else {
            return nil
        }
        return element
    }

    /// Whether the element holds an inline node (anything but `xmlText`) — the
    /// shape whose run-space offsets do not map to live offsets.
    private static func hasInlineNodes(of element: YType) -> Bool {
        liveListChildren(of: element).contains { child in
            guard case .type(let type) = child.content else { return true }
            return type.typeRef != .xmlText
        }
    }

    /// The block's id from its container's `id` map entry — the live id, which a
    /// stale caller id must not override.
    private static func liveID(of container: YType) -> String? {
        guard let item = container.map["id"], !item.deleted, case .any(let values) = item.content,
            values.count == 1, case .string(let id) = values[0]
        else { return nil }
        return id
    }

    /// The element's visible (UTF-16 unit) length: each `xmlText`'s countable length,
    /// each inline element one unit — the index space `TextSpanDiff` and the writer
    /// both count in.
    private static func visibleLength(of element: YType) -> Int? {
        var total = 0
        for child in liveListChildren(of: element) {
            guard case .type(let type) = child.content else { return nil }
            if type.typeRef == .xmlText {
                guard let length = Int(exactly: type.length) else { return nil }
                total += length
            } else {
                total += 1
            }
        }
        return total
    }

    /// The runs of `runs` covering the visible (UTF-16 unit) `range`, split at the
    /// range's edges and otherwise kept as authored.
    private static func runs(_ runs: [InlineRun], range: Range<Int>) -> [InlineRun] {
        var result: [InlineRun] = []
        var position = 0
        for run in runs {
            let units = Array(run.text.utf16)
            let lower = max(position, range.lowerBound)
            let upper = min(position + units.count, range.upperBound)
            if lower < upper {
                result.append(
                    InlineRun(
                        String(decoding: units[(lower - position)..<(upper - position)], as: UTF16.self),
                        marks: run.marks))
            }
            position += units.count
        }
        return result
    }

    /// A run's marks as the writer's explicit attribute map — never nil, which
    /// would inherit whatever mark is open at the caret.
    private static func attributes(_ marks: [(key: String, valueJSON: String)]) -> YTextAttributes {
        var attributes = YTextAttributes()
        for mark in marks {
            attributes[mark.key] = YTextAttributeValue(json: mark.valueJSON, identity: YAttributeIdentity())
        }
        return attributes
    }

    /// Reconcile a surviving block in place: keep its `blockContainer` and `id`,
    /// applying only what changed.
    ///
    /// - **kind change** (`old.node != new.node`): delete the content element (its
    ///   delete cascades to the text, runs and props) and build a fresh element —
    ///   new node, text and props — as the container's new first child. The
    ///   container and its `id` stay, so the block keeps its identity.
    /// - **prop change** (same node): `mapSet` every changed or added prop on the
    ///   element (BlockNote's per-node prop schema is fixed, so props are never
    ///   removed — only re-valued).
    /// - **text change** (`old.runs != new.runs`): `TextSpanDiff.diff` yields the
    ///   minimal visible range to delete and the self-describing pieces to insert;
    ///   applied to the element's `xmlText` with `YWrite.delete` + `YWrite.insert`.
    ///   The visible (UTF-16 unit) index the diff reports is exactly the countable
    ///   index those primitives count over (formats are non-countable), and the
    ///   inserted pieces re-establish every boundary mark, so this is correct at the
    ///   document level even though it mints different items than yjs's `deleteText`.
    private static func reconcileBlockLegacy(
        _ tx: YTransaction, container: YItem, old: BlockNoteBlock, new: BlockNoteBlock
    ) throws {
        guard case .type(let containerType) = container.content,
            let elementItem = contentElementItem(of: containerType),
            case .type(let element) = elementItem.content
        else {
            // A survivor the projection matched always has a live content element;
            // reaching here means a malformed replica, which is a caught error, not a
            // trap (clocks are peer-influenced — see `AGENTS.md`).
            throw YIntegrationError.unexpectedCase
        }

        // A text change is only spliced in place when the element holds its text in exactly
        // one `xmlText`, the only shape whose visible indices are the diff's. Anything else —
        // no `xmlText` at all (y-prosemirror writes none for an empty paragraph), or several
        // — would silently drop the edit or splice it at the wrong place, so the element is
        // rebuilt instead, exactly as for a kind change. The container and `id` survive.
        let textType = soleXmlText(of: element)
        if old.node != new.node || (old.runs != new.runs && textType == nil) {
            elementItem.delete(tx)
            try insertContentElement(tx, into: containerType, new)
            return
        }

        // Same node: reconcile props, then text, on the existing element.
        let oldProps = Dictionary(old.props.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        for prop in new.props where oldProps[prop.key] != prop.value {
            try YWrite.mapSet(tx, on: element, key: prop.key, .any([prop.value]))
        }

        if old.runs != new.runs, let textType, let change = TextSpanDiff.diff(old: old.runs, new: new.runs) {
            let lower = UInt(change.deleteRange.lowerBound)
            try YWrite.delete(tx, from: textType, at: lower, length: UInt(change.deleteRange.count))
            try YWrite.insert(tx, into: textType, at: lower, change.insertPieces.map(content(of:)))
        }
    }
}
