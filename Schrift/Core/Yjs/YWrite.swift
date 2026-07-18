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
        _ contents: [YContent]
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
                parentSub: nil,  // list children carry no parentSub (only `mapSet` does)
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
            _ = try insertAfter(transaction, into: parentType, after: nil, contents)
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
        _ = try insertAfter(transaction, into: parentType, after: n, contents)
    }

    /// Delete `length` countable units starting at visible index `index` from
    /// `parentType`'s children, splitting the boundary items clean. yjs
    /// `typeListDelete` (@5543).
    ///
    /// Two passes over the child list, mirroring yjs exactly:
    ///
    /// 1. **Find start** (yjs @5554-5561) — walk forward, counting `index` down over
    ///    undeleted *countable* items until it lands inside one, splitting that item
    ///    at the boundary so the deletion begins between two whole items.
    /// 2. **Delete** (yjs @5563-5572) — from there, delete undeleted items until
    ///    `length` countable units are gone, splitting the trailing boundary item so
    ///    only the in-range prefix is removed. `YItem.delete` marks the item deleted,
    ///    shrinks the parent length, records the range on `transaction.deleteSet`, and
    ///    tears down its content sub-tree — never re-implement it here.
    ///
    /// Two deliberate, behavior-preserving refinements over a literal transliteration,
    /// both to make the primitive trap-safe and robust without changing what it does
    /// for the types `typeListDelete` serves:
    ///
    /// - **`min(…)` on the `idx`/`remaining` subtractions.** yjs does `index -= n.length`
    ///   over a JS number that can go harmlessly negative; Swift's `UInt` traps. In the
    ///   reachable path the subtracted amount always *equals* the item's length (when the
    ///   item was split at the boundary, it is truncated in place to exactly that many
    ///   units — the split's right half is discarded), so `min` never actually clamps; it
    ///   is underflow insurance against a malformed shape, matching how `insert` guards
    ///   the same walk.
    /// - **The delete-pass accounting is gated on `countable`.** Literal `typeListDelete`
    ///   does `length -= n.length` for *every* undeleted item (@5569). That is correct
    ///   for the types it serves — a `YArray`/`YXmlFragment` child list contains no
    ///   undeleted *non-countable* item (the only non-countable content is `ContentDeleted`,
    ///   which is `deleted`, and `ContentFormat`, which exists only in text types), so the
    ///   non-countable branch is unreachable there and the two spellings are identical.
    ///   Gating the subtraction (and the boundary split) on `countable` keeps that identity
    ///   while ensuring a `ContentFormat` — were this ever called on a text child list —
    ///   is stepped past without wrongly consuming the deletion budget (yjs's own text
    ///   delete, `deleteText` @6774, likewise only counts `ContentString`/`Type`/`Embed`).
    ///   The `delete(transaction)` call itself stays unconditional-within-`!deleted`, exactly
    ///   as yjs @5568.
    static func delete(
        _ transaction: YTransaction, from parentType: YType, at index: UInt, length: UInt
    ) throws {
        // yjs @5544: a zero-length delete is a no-op. (Also keeps the two walks below
        // from doing any work.)
        if length == 0 { return }

        var remaining = length
        var idx = index
        // yjs @5547-5552: `findMarker` returns nil with no search markers, so the walk
        // starts at `_start`.
        var n = parentType.start

        // yjs @5554-5561: compute the first item to delete. Only undeleted countable
        // items consume `idx`; a non-countable `ContentFormat` between strings is
        // skipped without decrementing the visible index.
        while let cur = n, idx > 0 {
            if !cur.deleted, cur.countable {
                if idx < cur.length {
                    // yjs @5557: split `cur` at the boundary; it is truncated in place to
                    // the left half, so `cur.length` becomes `idx` and the next line
                    // drives `idx` to exactly 0.
                    _ = try YStructStore.getItemCleanStart(
                        transaction, YID(client: cur.id.client, clock: cur.id.clock + idx))
                }
                idx -= min(idx, cur.length)  // yjs @5559 `index -= n.length`, trap-safe
            }
            n = cur.right
        }

        // yjs @5563-5572: delete undeleted items until `remaining` countable units are
        // gone, splitting the trailing boundary so only the in-range prefix goes.
        while remaining > 0, let cur = n {
            if !cur.deleted {
                if cur.countable, remaining < cur.length {
                    // yjs @5566: split the trailing boundary item at `remaining`.
                    _ = try YStructStore.getItemCleanStart(
                        transaction, YID(client: cur.id.client, clock: cur.id.clock + remaining))
                }
                cur.delete(transaction)  // yjs @5568, unconditional within `!deleted`
                if cur.countable {
                    remaining -= min(remaining, cur.length)  // yjs @5569, trap-safe
                }
            }
            n = cur.right
        }

        // yjs @5573-5575 throws `lengthExceeded` when `remaining > 0` here — the range
        // ran past the end of the child list. Fold it into the store's one
        // malformed-state signal, matching `insert`'s out-of-range guard.
        if remaining > 0 { throw YIntegrationError.unexpectedCase }
    }

    // MARK: Local map set

    /// Set map key `key` on `parentType` to `content` (typically a `.any([value])`
    /// wrapping one BlockNote prop or the `id` field). yjs `typeMapSet` (@5605).
    ///
    /// Reduced exactly as `insertAfter`'s doc-comment describes for list inserts:
    /// yjs's `typeMapSet` takes a raw JS value and classifies it (`ContentAny` for
    /// primitives, `ContentBinary`/`ContentDoc`/`ContentType` otherwise); the
    /// caller here already holds a built `YContent`, so that switch disappears.
    /// What's preserved verbatim is the rest of the line yjs runs:
    ///
    ///     new Item(createID(ownClientId, getState(doc.store, ownClientId)),
    ///       left, left && left.lastId, null, null, parent, key, content)
    ///       .integrate(transaction, 0)
    ///
    /// — the new item's `left` is the map's current value (`parent._map.get(key)`),
    /// its `origin` is that value's `lastId`, and `right`/`rightOrigin` are always
    /// nil (a map entry has no right neighbour). `YItem.integrate`'s
    /// `parentSub != nil && right == nil` branch then sets `parentType.map[key] =
    /// self` and deletes the prior value — not re-implemented here.
    static func mapSet(
        _ transaction: YTransaction, on parentType: YType, key: String, _ content: YContent
    ) throws {
        let doc = transaction.doc
        let left = parentType.map[key]
        let id = YID(client: doc.clientID, clock: doc.store.getState(doc.clientID))
        let item = YItem(
            id: id,
            left: left,
            origin: left?.lastId,  // yjs `left && left.lastId`
            right: nil,
            rightOrigin: nil,
            parent: .type(parentType),
            parentSub: key,
            content: content)
        try item.integrate(transaction, offset: 0)
    }
}
