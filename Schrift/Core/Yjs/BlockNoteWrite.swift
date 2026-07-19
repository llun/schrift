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
/// replica's single owner (`YDoc.transact`). See `CLAUDE.md`, "The Yjs CRDT core".
enum BlockNoteWrite {
    /// The BlockNote fragment root — one `document-store` XmlFragment.
    static let fragmentField = BlockNoteYjs.fragmentField

    /// Diff `old` → `new` BlockNote blocks, apply the difference as local ops inside
    /// one local transaction against `doc`, and return the incremental v1 update
    /// (only structs/clocks minted by this transaction). `old == []` ⇒ from-empty,
    /// whose bytes equal `BlockNoteYjs.encode(new, clientID: doc.clientID)`.
    ///
    /// Throws `YIntegrationError` if integration or encoding hits a malformed state;
    /// the caller (the collaboration session, C2) turns that into `failSafe`.
    static func applyEdit(old: [BlockNoteBlock], new: [BlockNoteBlock], to doc: YDoc) throws -> Data {
        // Snapshot the state vector *before* the transaction so the returned update
        // is a diff of exactly what this edit minted. From-empty ⇒ empty vector ⇒
        // full snapshot, which is what makes the bytes equal the golden encoder.
        let before = doc.store.getStateVector()
        try doc.transact(local: true) { tx in
            let root = doc.get(fragmentField)
            let group = try ensureBlockGroup(tx, root: root)
            try applyBlocks(tx, group: group, old: old, new: new)
        }
        return try YStateEncoder.encodeStateAsUpdate(doc, since: before)
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
    /// 5. the `id` as `.any([.string(id)])` map entry **on the container**.
    ///
    /// Steps 2–4 are shared verbatim with `reconcileBlock`'s kind-change branch via
    /// `insertContentElement`.
    private static func insertBlock(
        _ tx: YTransaction, group: YType, after left: YItem?, _ block: BlockNoteBlock
    ) throws -> YItem? {
        let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
        let last = try YWrite.insertAfter(tx, into: group, after: left, [.type(container)])
        try insertContentElement(tx, into: container, block)
        // The `id` lives on the container, minted after its content element for byte
        // parity with `BlockNoteYjs.encode`.
        try YWrite.mapSet(tx, on: container, key: "id", .any([.string(block.id)]))
        return last
    }

    /// Build a block's content element as the **head** child of `container`
    /// (`after: nil`): the content `element` (nodeName = `block.node`), then — for a
    /// text block — its `xmlText` child and run pieces, then the block's props as
    /// `.any([value])` map entries **on the element** (a leaf `image` still carries
    /// its props). Shared verbatim by `insertBlock` (into a fresh container) and
    /// `reconcileBlock`'s kind-change branch (into the surviving container, after
    /// the old element was deleted).
    ///
    /// The mint order — element, text, run pieces, props — is load-bearing: it is
    /// what the from-empty byte-identity anchor (`BlockNoteWriteTests`) pins against
    /// `BlockNoteYjs.encode`. Do not reorder.
    private static func insertContentElement(
        _ tx: YTransaction, into container: YType, _ block: BlockNoteBlock
    ) throws {
        let element = YType(typeRef: .xmlElement(nodeName: block.node))
        try YWrite.insertAfter(tx, into: container, after: nil, [.type(element)])

        if block.hasTextChild {
            let text = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: element, after: nil, [.type(text)])
            let pieces = InlineContent.pieces(for: block.runs)
            try YWrite.insertAfter(tx, into: text, after: nil, pieces.map(content(of:)))
        }

        for prop in block.props {
            try YWrite.mapSet(tx, on: element, key: prop.key, .any([prop.value]))
        }
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

    /// The `xmlText` child of a content element — its first undeleted list child
    /// whose content is an `xmlText` type. nil for a leaf element (`divider`,
    /// `image`) or a malformed shape.
    private static func xmlTextType(of element: YType) -> YType? {
        for child in liveListChildren(of: element) {
            if case .type(let type) = child.content, type.typeRef == .xmlText { return type }
        }
        return nil
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
    ///   container and its `id`.
    /// - **survivor moved**: v1 rebuilds it whole (delete + re-insert after `left`).
    ///   Reorders are rare and snapshot-covered, so this trades minimality for
    ///   simplicity; `keptSurvivors` decides which survivors are in place vs moved.
    ///
    /// `old == []` ⇒ every block is an insert appended in order, which is the
    /// from-empty path the byte-identity anchor pins — unchanged by this diff.
    private static func applyBlocks(
        _ tx: YTransaction, group: YType, old: [BlockNoteBlock], new: [BlockNoteBlock]
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
                if keptIDs.contains(block.id) {
                    try reconcileBlock(tx, container: container, old: existing, new: block)
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
    private static func reconcileBlock(
        _ tx: YTransaction, container: YItem, old: BlockNoteBlock, new: BlockNoteBlock
    ) throws {
        guard case .type(let containerType) = container.content,
            let elementItem = contentElementItem(of: containerType),
            case .type(let element) = elementItem.content
        else {
            // A survivor the projection matched always has a live content element;
            // reaching here means a malformed replica, which is a caught error, not a
            // trap (clocks are peer-influenced — see `CLAUDE.md`).
            throw YIntegrationError.unexpectedCase
        }

        if old.node != new.node {
            elementItem.delete(tx)
            try insertContentElement(tx, into: containerType, new)
            return
        }

        // Same node: reconcile props, then text, on the existing element.
        let oldProps = Dictionary(old.props.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        for prop in new.props where oldProps[prop.key] != prop.value {
            try YWrite.mapSet(tx, on: element, key: prop.key, .any([prop.value]))
        }

        if old.runs != new.runs, let textType = xmlTextType(of: element),
            let change = TextSpanDiff.diff(old: old.runs, new: new.runs)
        {
            let lower = UInt(change.deleteRange.lowerBound)
            try YWrite.delete(tx, from: textType, at: lower, length: UInt(change.deleteRange.count))
            try YWrite.insert(tx, into: textType, at: lower, change.insertPieces.map(content(of:)))
        }
    }
}
