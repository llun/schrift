import Foundation

// MARK: - Local list insert

/// The first local mutation primitive (B6): mint local `YItem`s and integrate them
/// as consecutive list children of a `YType`.
///
/// A reduction of yjs 13.6.31's `typeListInsertGenericsAfter` (@5404) and
/// `typeListInsertGenerics` (@5470) to Schrift's needs:
///
/// - **We already hold built `YContent`.** yjs's `typeListInsertGenericsAfter`
///   takes a JS value array and *classifies* each element — batching runs of
///   primitives into a single `ContentAny` (`packJsonContent`), and minting
///   `ContentBinary`/`ContentDoc`/`ContentType` for the rest. The caller here has
///   already decided the content boundaries, so each `YContent` becomes exactly one
///   item; the classification switch and the json-batching disappear.
/// - **No search markers.** `YType._searchMarker` is always nil in this store (see
///   `YType`), so `findMarker`/`updateMarkerChanges` reduce to no-ops and are
///   dropped, exactly as they compile away for an unmarked type in yjs.
///
/// What is preserved verbatim: `right` is captured **once** (before the loop) from
/// the reference item, each item's `origin`/`rightOrigin` are `left?.lastId` /
/// `right?.id`, each `id` re-reads `getState` (so it advances as the previous item
/// integrates), and every item is integrated through `YItem.integrate(offset: 0)`,
/// which recomputes the actual links. Transaction cleanup merges adjacent
/// same-client items — this must not do so itself.
///
/// Pure value code with no concurrency annotations, but it **mutates** the live
/// replica graph, so it must run inside an open transaction owned by the replica's
/// single owner (`YDoc.transact`). See `CLAUDE.md`, "The Yjs CRDT core".
enum YWrite {

    /// Insert `contents` as consecutive list children immediately after `left`
    /// (nil = at the head), returning the last item minted (nil if `contents` was
    /// empty). yjs `typeListInsertGenericsAfter` (@5404).
    @discardableResult
    static func insertAfter(
        _ transaction: YTransaction, into parentType: YType, after left: YItem?,
        parentSub: String?, _ contents: [YContent]
    ) throws -> YItem? {
        // yjs @5405-5409: `left` walks forward as items are minted; `right` and the
        // client id/store are captured once. `right` is `referenceItem.right` (or the
        // type's head when there is no reference item) — never re-read from the moving
        // `left`, so a whole batch chains between the original `left` and `right`.
        let doc = transaction.doc
        let store = doc.store
        var left = left
        let right = left == nil ? parentType.start : left?.right

        // yjs @5421-5456 forEach, reduced: no json batching, no per-constructor
        // classification — each pre-built `YContent` is one item. yjs @5416 is the
        // Item constructor + `integrate(transaction, 0)` this mirrors.
        for content in contents {
            let id = YID(client: doc.clientID, clock: store.getState(doc.clientID))
            let item = YItem(
                id: id,
                left: left,
                origin: left?.lastId,  // yjs `left && left.lastId`
                right: right,
                rightOrigin: right?.id,  // yjs `right && right.id`
                parent: .type(parentType),
                parentSub: parentSub,
                content: content)
            try item.integrate(transaction, offset: 0)
            left = item
        }
        return left
    }

    /// Insert `contents` as consecutive list children starting at countable visible
    /// index `index`. yjs `typeListInsertGenerics` (@5470), minus search markers.
    static func insert(
        _ transaction: YTransaction, into parentType: YType, at index: UInt,
        _ contents: [YContent]
    ) throws {
        // yjs @5471: reject an index past the visible length. Without this a too-large
        // index falls through the position walk with `n == nil` and silently inserts
        // at the head instead of erroring — corruption, not a caught mistake. yjs
        // raises a distinct `Length exceeded!`; Schrift folds it into the store's one
        // malformed-state signal.
        guard index <= parentType.length else { throw YIntegrationError.unexpectedCase }

        // yjs @5474-5479: `index === 0` inserts at the head. (`updateMarkerChanges` is
        // a no-op with no markers.)
        if index == 0 {
            _ = try insertAfter(transaction, into: parentType, after: nil, parentSub: nil, contents)
            return
        }

        // yjs @5480-5504: walk the child list, counting down `index` over undeleted
        // countable items, until it lands inside one — splitting that item clean at
        // the boundary so the insert falls exactly between two items. `findMarker`
        // (@5481) returns nil with no markers, so the walk starts at `_start`.
        var remaining = index
        var n = parentType.start
        while let cur = n {
            if !cur.deleted, cur.countable {
                if remaining <= cur.length {
                    if remaining < cur.length {
                        // yjs @5498: `getItemCleanStart(transaction, createID(n.id.client,
                        // n.id.clock + index))` — split `cur` at the boundary. The right
                        // half is discarded here; `cur` is truncated in place to the left
                        // half, so `n` still names the item the insert goes after.
                        _ = try YStructStore.getItemCleanStart(
                            transaction, YID(client: cur.id.client, clock: cur.id.clock + remaining))
                    }
                    break
                }
                remaining -= cur.length
            }
            n = cur.right
        }

        // yjs @5508. The length guard above guarantees the walk broke at a real item,
        // so `n` is non-nil here for every in-range index.
        _ = try insertAfter(transaction, into: parentType, after: n, parentSub: nil, contents)
    }
}
