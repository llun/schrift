import Foundation

// MARK: - Transaction

/// One unit of change against a `YDoc` — yjs `Transaction` (@3081).
///
/// Reduced to the fields the struct store actually reads. Deliberately **not**
/// modelled: `changedParentTypes` and the observer machinery (no observers in
/// this milestone), `subdocsAdded/Removed/Loaded` (Schrift's schema has no
/// subdocuments), `origin`/`meta` (caller bookkeeping with no effect on state).
final class YTransaction {
    let doc: YDoc
    /// Ranges deleted during this transaction.
    var deleteSet = YDeleteSet()
    /// The state vector before the transaction started.
    let beforeState: [UInt: UInt]
    /// The state vector after it ended — filled in by `cleanup()`.
    var afterState: [UInt: UInt] = [:]
    /// Types whose children changed, mapped to the parentSubs that changed.
    ///
    /// Write-only in this milestone: yjs uses it to fire observers, and there are
    /// none here. It is carried because `Item.integrate`, `Item.delete`, and
    /// `YType.deleteChildren` all maintain it, and because B4's
    /// `cleanupYTextAfterTransaction` and B5's projection will read it.
    var changed: [ObjectIdentifier: Set<String?>] = [:]
    /// Structs that may have become mergeable but are not in `deleteSet` — split
    /// right-halves, and already-deleted children found by `YType.deleteChildren`.
    var mergeStructs: [YStruct] = []
    /// Whether the change originated locally. Remote updates set this false, which
    /// is what arms the client-id collision check in `cleanup()`.
    var local: Bool

    init(doc: YDoc, local: Bool) {
        self.doc = doc
        self.beforeState = doc.store.getStateVector()
        self.local = local
    }

    /// yjs `addChangedTypeToTransaction` (@3181).
    ///
    /// The condition records a type only when the change is to *pre-existing*
    /// content: a type created within this same transaction has no observers that
    /// could care.
    func addChangedType(_ type: YType, parentSub: String?) {
        let item = type.item
        if item == nil || (item!.id.clock < (beforeState[item!.id.client] ?? 0) && !item!.deleted) {
            changed[ObjectIdentifier(type), default: []].insert(parentSub)
        }
    }
}

// MARK: - Running a transaction

extension YDoc {
    /// yjs `transact` (@3434) — run `body` inside a transaction, then clean up.
    ///
    /// The nesting/re-entrancy dance is preserved: a transaction opened while one
    /// is already running joins it, and cleanup runs once, at the outermost exit,
    /// over every transaction queued in the meantime (an observer can open more —
    /// which is why yjs iterates rather than recurses over a fixed list).
    @discardableResult
    func transact<T>(local: Bool = true, _ body: (YTransaction) throws -> T) throws -> T {
        var initialCall = false
        if transaction == nil {
            initialCall = true
            let newTransaction = YTransaction(doc: self, local: local)
            transaction = newTransaction
            transactionCleanups.append(newTransaction)
        }
        guard let active = transaction else { throw YIntegrationError.unexpectedCase }

        // yjs runs cleanup from a `finally`, so it happens even when `body` throws
        // and the store is left half-mutated. `defer` would match that shape but
        // cannot rethrow, and silently swallowing a cleanup failure is exactly the
        // wrong trade here — a store that failed to merge is a store that no longer
        // matches yjs. So the outcome is captured and both errors are surfaced.
        let outcome = Result { try body(active) }
        if initialCall {
            let finishCleanup = transaction === transactionCleanups.first
            transaction = nil
            if finishCleanup {
                do {
                    try cleanupTransactions(0)
                } catch {
                    // A JS `finally` throw would *replace* the body's error; keeping the
                    // body's is strictly more informative, and both mean the same thing
                    // to the only caller — reject this update.
                    if case .success = outcome { throw error }
                }
            }
        }
        return try outcome.get()
    }

    /// yjs `cleanupTransactions` (@3282) — the half that survives without
    /// observers: normalize the delete set, snapshot the after-state, then merge.
    ///
    /// **Merging is not optional.** yjs merges on every transaction, so a store
    /// that skips it diverges structurally from yjs's after the very first update
    /// — three adjacent single-character inserts stay three items here and become
    /// one there. Everything downstream (the projection, the serializer, the
    /// oracle comparison) would then disagree.
    private func cleanupTransactions(_ i: Int) throws {
        guard i < transactionCleanups.count else { return }
        let transaction = transactionCleanups[i]
        let store = transaction.doc.store

        // Sort *before* reading the set back: yjs's `const ds = transaction.deleteSet`
        // is a reference, so `sortAndMergeDeleteSet(ds)` normalizes the very set the
        // merges below then walk. `YDeleteSet` is a value type, so taking a copy
        // first would hand `tryMergeDeleteSet` the unsorted ranges.
        transaction.deleteSet.sortAndMerge()
        transaction.afterState = store.getStateVector()

        // yjs runs observer callbacks here; there are none. `doc.gc` is off for this
        // milestone, so `tryGcDeleteSet` is skipped — B4 turns it on.
        try Self.tryMergeDeleteSet(transaction.deleteSet, store)

        // On all affected store.clients props, try to merge.
        for (client, clock) in transaction.afterState {
            let beforeClock = transaction.beforeState[client] ?? 0
            guard beforeClock != clock, let list = store.clients[client] else { continue }
            // We iterate from right to left so we can safely remove entries.
            let firstChangePos = max(try YStructStore.findIndexSS(list.structs, beforeClock), 1)
            var i = list.structs.count - 1
            while i >= firstChangePos {
                i -= 1 + Self.tryToMergeWithLefts(list, i)
            }
        }

        // Try to merge mergeStructs.
        for s in transaction.mergeStructs.reversed() {
            let client = s.id.client
            let clock = s.id.clock
            guard let list = store.clients[client] else { continue }
            let replacedStructPos = try YStructStore.findIndexSS(list.structs, clock)
            if replacedStructPos + 1 < list.structs.count {
                if Self.tryToMergeWithLefts(list, replacedStructPos + 1) > 1 {
                    continue  // no need to perform next check, both are already merged
                }
            }
            if replacedStructPos > 0 {
                _ = Self.tryToMergeWithLefts(list, replacedStructPos)
            }
        }

        if !transaction.local, transaction.afterState[clientID] != transaction.beforeState[clientID] {
            // yjs logs and re-rolls: another client is using our id, so every struct
            // we mint from here would collide. The roadmap requires a fresh random
            // clientID per session anyway; this is the safety net if one collides
            // mid-session.
            clientID = YDoc.generateClientID()
        }

        if transactionCleanups.count <= i + 1 {
            transactionCleanups = []
        } else {
            try cleanupTransactions(i + 1)
        }
    }

    // MARK: Merging

    /// yjs `tryToMergeWithLefts` (@3193) — merge `structs[pos]` leftwards as far as
    /// it will go, removing the absorbed structs. Returns how many were absorbed.
    static func tryToMergeWithLefts(_ list: YStructList, _ pos: Int) -> Int {
        guard pos > 0, pos < list.structs.count else { return 0 }
        var right = list.structs[pos]
        var left = list.structs[pos - 1]
        var i = pos
        // yjs's `for (; i > 0; right = left, left = structs[--i - 1])`: the update
        // clause runs only after a successful merge (`continue`), never after the
        // `break`.
        while i > 0 {
            guard left.deleted == right.deleted, type(of: left) == type(of: right),
                left.mergeWith(right)
            else { break }
            if let rightItem = right as? YItem, let sub = rightItem.parentSub,
                let parentType = rightItem.parentType, parentType.map[sub] === rightItem,
                // `type(of:)` above already proved left is an Item whenever right is.
                let leftItem = left as? YItem
            {
                // `right` is about to be forgotten; hand its map slot to `left`.
                parentType.map[sub] = leftItem
            }
            right = left
            i -= 1
            // `structs[--i - 1]` reads out of bounds at i == 0, where JS yields
            // undefined and the loop condition then ends it — so the value is never
            // used. Hold the previous one rather than index out of range.
            if i - 1 >= 0 { left = list.structs[i - 1] }
        }
        let merged = pos - i
        if merged > 0 {
            // Remove all merged structs from the array (`splice(pos + 1 - merged, merged)`).
            list.structs.removeSubrange((pos + 1 - merged)...pos)
        }
        return merged
    }

    /// yjs `tryMergeDeleteSet` (@3248) — try to merge deleted/gc'd items, right to
    /// left, so no merge target is missed. Reads `ds`; it mutates only the store.
    static func tryMergeDeleteSet(_ ds: YDeleteSet, _ store: YStructStore) throws {
        for (client, deleteItems) in ds.clients {
            guard let list = store.clients[client] else { continue }
            for deleteItem in deleteItems.reversed() {
                // Start with merging the item next to the last deleted item.
                let lastIndex = try YStructStore.findIndexSS(
                    list.structs, deleteItem.clock + deleteItem.len - 1)
                var si = min(list.structs.count - 1, 1 + lastIndex)
                while si > 0, si < list.structs.count, list.structs[si].id.clock >= deleteItem.clock {
                    si -= 1 + tryToMergeWithLefts(list, si)
                }
            }
        }
    }

    /// A fresh random client id — yjs `generateNewClientId` (`random.uint32()`).
    static func generateClientID() -> UInt {
        UInt(UInt32.random(in: UInt32.min...UInt32.max))
    }
}
