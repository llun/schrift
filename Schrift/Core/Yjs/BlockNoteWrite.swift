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
    private static func ensureBlockGroup(_ tx: YTransaction, root: YType) throws -> YType {
        if let start = root.start, case .type(let group) = start.content { return group }
        let group = YType(typeRef: .xmlElement(nodeName: "blockGroup"))
        try YWrite.insertAfter(tx, into: root, after: nil, parentSub: nil, [.type(group)])
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
    @discardableResult
    static func insertBlock(
        _ tx: YTransaction, group: YType, after left: YItem?, _ block: BlockNoteBlock
    ) throws -> YItem? {
        let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
        let last = try YWrite.insertAfter(tx, into: group, after: left, parentSub: nil, [.type(container)])

        let element = YType(typeRef: .xmlElement(nodeName: block.node))
        try YWrite.insertAfter(tx, into: container, after: nil, parentSub: nil, [.type(element)])

        if block.hasTextChild {
            let text = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: element, after: nil, parentSub: nil, [.type(text)])
            let pieces = InlineContent.pieces(for: block.runs)
            try YWrite.insertAfter(tx, into: text, after: nil, parentSub: nil, pieces.map(content(of:)))
        }

        // Props live on the content element (a leaf `image` still carries them);
        // the `id` lives on the container. Emitted in this order for byte parity.
        for prop in block.props {
            try YWrite.mapSet(tx, on: element, key: prop.key, .any([prop.value]))
        }
        try YWrite.mapSet(tx, on: container, key: "id", .any([.string(block.id)]))

        return last
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

    // MARK: - Block-level diff

    /// Apply the `old` → `new` block difference to `group`.
    ///
    /// **Insert-only stub (Task 7).** Task 8 replaces this with the real
    /// keyed diff (reuse surviving blocks, `TextSpanDiff` for in-place text edits,
    /// delete removed blocks). For now it appends every `new` block in order, which
    /// is exactly correct for the from-empty case the byte-identity anchor pins and
    /// keeps the facade shape stable while the diff lands.
    private static func applyBlocks(
        _ tx: YTransaction, group: YType, old: [BlockNoteBlock], new: [BlockNoteBlock]
    ) throws {
        var left: YItem?
        for block in new {
            left = try insertBlock(tx, group: group, after: left, block)
        }
    }
}
