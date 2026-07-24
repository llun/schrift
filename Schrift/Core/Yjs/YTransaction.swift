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
    /// Types whose children changed, mapped to the changed type and the parentSubs
    /// that changed.
    ///
    /// yjs's `changed` is `Map<AbstractType, Set>` keyed by the type object; we key
    /// by identity but keep the `YType` reference, because B4's observer phase reads
    /// each changed type's `_hasFormatting`. `Item.integrate`, `Item.delete`, and
    /// `YType.deleteChildren` all maintain it (the last removes by `ObjectIdentifier`);
    /// B5's projection will read the subs.
    var changed: [ObjectIdentifier: (type: YType, subs: Set<String?>)] = [:]
    /// yjs `_needFormattingCleanup` — armed by the observer phase when a *remote*
    /// transaction touches a formatted text (`!local && _hasFormatting`), consumed by
    /// `cleanupYTextAfterTransaction` at the end of the same observer phase.
    var needFormattingCleanup = false
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
            let oid = ObjectIdentifier(type)
            var entry = changed[oid] ?? (type: type, subs: [])
            entry.subs.insert(parentSub)
            changed[oid] = entry
        }
    }

    // MARK: - Deep-nesting recursion guard

    /// The maximum `ContentType` nesting depth the delete and gc cascades descend
    /// before the whole update is refused.
    ///
    /// `YItem.delete → ContentType.delete → YType.deleteChildren → YItem.delete`
    /// and `YItem.gc → ContentType.gc → YItem.gc` each recurse once per nested
    /// `ContentType` level, consuming native stack proportional to the replica's
    /// live type-nesting depth — a depth a single crafted inbound update fully
    /// controls (~7 wire bytes per level). Past a few thousand levels that
    /// recursion overruns the thread's guard page and raises `EXC_BAD_ACCESS`: a
    /// *machine fault*, not a Swift error, so it bypasses
    /// `DocumentCollaborationManager.applyReplicaUpdate`'s fail-safe `catch` and
    /// crashes the app.
    ///
    /// yjs refuses the same input: at deep nesting `Item.delete`/`ContentType.delete`
    /// throw V8's catchable `RangeError: Maximum call stack size exceeded`, the
    /// update is rejected, and the process survives. This cap makes Schrift do the
    /// same — refuse through a *thrown* `YIntegrationError.recursionLimitExceeded`
    /// the manager fail-safes on.
    ///
    /// **The value is chosen for the *device* main-thread stack, not the
    /// simulator's.** `applyReplicaUpdate` runs on `@MainActor`, so this recursion
    /// is on the main thread — ~1 MB on a real iOS device, but the iOS Simulator
    /// inherits the macOS host's far larger (~8 MB) main-thread stack. On the
    /// simulator the fault floor measured >5000 levels (the deep repro crashed
    /// around 20k); extrapolated to a ~1 MB device stack that is roughly 8× lower.
    /// Each nesting level costs ~3 native frames on the delete path (`YItem.delete
    /// → YContent.delete → YType.deleteChildren`) and ~2 on gc, so 256 levels is
    /// ≲800 frames — safely inside 1 MB even in a Debug build — while still ~25×
    /// above realistic content (a normal document nests only a handful of type
    /// levels; even an absurd 100-visual-indent document is ~200 levels, and a
    /// document that *does* exceed 256 simply falls back to classic REST editing,
    /// losing live collaboration but no data). It is deliberately conservative:
    /// **the exact device-safe ceiling is owed a real-device, Release-build
    /// measurement before the `schrift.liveCollaboration` flag is defaulted on** —
    /// a *simulator* Release measurement would not expose the device stack.
    /// See CLAUDE.md "Malformed input must throw, never trap".
    static let maxTypeNestingDepth = 256

    /// Current depth of the in-progress delete cascade (`YItem.delete`). The gc
    /// cascade threads its depth as a parameter instead, because `YItem.gc` is
    /// already `throws`; `YItem.delete` is a non-throwing override and so signals
    /// refusal via this counter + the `recursionLimitExceeded` flag.
    private var deleteRecursionDepth = 0

    /// Set when a delete cascade in this transaction hit `maxTypeNestingDepth` and
    /// stopped descending. `cleanupTransactions` converts it into a thrown
    /// `.recursionLimitExceeded`, so the partially-marked store is discarded
    /// wholesale (the manager destroys the replica and latches `failSafe`) and is
    /// never observed.
    var recursionLimitExceeded = false

    /// Enter one delete-cascade level. Returns `false` (without entering) when
    /// descending further would exceed `maxTypeNestingDepth`; the caller then flags
    /// the transaction and stops descending. Pair with `exitDeleteRecursion()`.
    func enterDeleteRecursion() -> Bool {
        guard deleteRecursionDepth < YTransaction.maxTypeNestingDepth else { return false }
        deleteRecursionDepth += 1
        return true
    }

    /// Leave one delete-cascade level.
    func exitDeleteRecursion() {
        deleteRecursionDepth -= 1
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

    /// yjs `cleanupTransactions` (@3282) — normalize the delete set, snapshot the
    /// after-state, run the observer phase (`try`), then gc + merge + recurse
    /// (`finally`).
    ///
    /// **Merging is not optional.** yjs merges on every transaction, so a store
    /// that skips it diverges structurally from yjs's after the very first update
    /// — three adjacent single-character inserts stay three items here and become
    /// one there. Everything downstream (the projection, the serializer, the
    /// oracle comparison) would then disagree.
    ///
    /// yjs's try/finally is preserved: the observer phase (which may throw on
    /// malformed input) is captured in a `Result`, the finally-equivalent runs
    /// unconditionally, and the observer error is surfaced last. When both halves
    /// throw, the observer error wins — the same deliberate choice `transact` makes
    /// (a JS `finally` throw replaces the body's, but both mean "reject this update"
    /// to the only caller, and the body's is more informative).
    private func cleanupTransactions(_ i: Int) throws {
        guard i < transactionCleanups.count else { return }
        let transaction = transactionCleanups[i]
        let store = transaction.doc.store

        // A delete cascade in this transaction hit `maxTypeNestingDepth` and
        // stopped descending — `YItem.delete` is a non-throwing override, so it
        // flags the transaction rather than throwing. This is the single universal
        // chokepoint: every delete (wire `readAndApply`, local
        // `BlockNoteWrite.applyEdit`, and the nested `YTextCleanup` transacts) runs
        // inside some transaction, and every transaction — top-level or
        // cleanup-spawned — is drained here exactly once. Refuse the whole update
        // now, before gc/merge trust the half-marked store. yjs's own deep
        // recursion throws a catchable `RangeError` on the same input; the caller
        // (`applyReplicaUpdate`) destroys and fail-safes this replica.
        if transaction.recursionLimitExceeded {
            throw YIntegrationError.recursionLimitExceeded
        }

        // yjs `try` block.
        let observerOutcome = Result {
            // Sort *before* reading the set back: yjs's `const ds = transaction.deleteSet`
            // is a reference, so `sortAndMergeDeleteSet(ds)` normalizes the very set the
            // merges below then walk. `YDeleteSet` is a value type, so taking a copy
            // first would hand `tryMergeDeleteSet` the unsorted ranges.
            transaction.deleteSet.sortAndMerge()
            transaction.afterState = store.getStateVector()

            // yjs dispatches each changed type's `_callObserver`. Schrift has no user
            // observers, so this reduces to `YText._callObserver`'s one store-visible
            // effect: on a *remote* change to a formatted text, arm the cleanup. yjs
            // skips a type whose owning item is deleted.
            for (_, entry) in transaction.changed {
                let type = entry.type
                guard type.item == nil || !(type.item!.deleted) else { continue }
                if !transaction.local, type._hasFormatting {
                    transaction.needFormattingCleanup = true
                }
            }
            // The last observer callback: run the formatting cleanup if armed. It opens
            // a nested local transaction (queued into `transactionCleanups` and drained
            // by the recursion below), deleting formatting items a concurrent edit
            // rendered redundant.
            if transaction.needFormattingCleanup {
                try YTextCleanup.cleanupYTextAfterTransaction(transaction)
            }
        }

        // yjs `finally` block — runs even when the observer phase threw.
        do {
            // B4 gc: a deleted item's content becomes a `ContentDeleted` tombstone (and
            // a deleted type's children `GC` structs) *before* the merge coalesces
            // adjacent tombstones. gc off ⇒ skipped, matching the gc:false fixtures.
            if transaction.doc.gc {
                try Self.tryGcDeleteSet(transaction.deleteSet, store)
            }
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
        } catch {
            // Surface the finally-block error only when the observer phase succeeded;
            // otherwise the observer error (rethrown just below) wins. See the doc
            // comment above and `transact`.
            if case .success = observerOutcome { throw error }
        }
        try observerOutcome.get()
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

    /// yjs `tryGcDeleteSet` (yjs.cjs @3221) — gc every deleted, non-kept `Item`
    /// inside each delete range, right to left.
    ///
    /// yjs's `gcFilter` defaults to `() => true` (gc everything); the replica has
    /// no undo manager, so there is nothing to keep alive and the filter is that
    /// default — the only gate is `deleted && !keep`. `gc(store, parentGCd: false)`
    /// replaces content in place (no `replaceStruct`), so the iterated array's
    /// indices do not shift for top-level items; a same-client child that is
    /// replaced by a `GC` (same id + length) is simply skipped when the loop reaches
    /// it (`as? YItem` fails), exactly as in yjs.
    static func tryGcDeleteSet(_ ds: YDeleteSet, _ store: YStructStore) throws {
        for (client, deleteItems) in ds.clients {
            guard let list = store.clients[client] else { continue }
            for deleteItem in deleteItems.reversed() {
                let endDeleteItemClock = deleteItem.clock + deleteItem.len
                var si = try YStructStore.findIndexSS(list.structs, deleteItem.clock)
                while si < list.structs.count {
                    let s = list.structs[si]
                    if endDeleteItemClock <= s.id.clock { break }
                    if let item = s as? YItem, item.deleted, !item.keep {
                        try item.gc(store, parentGCd: false)
                    }
                    si += 1
                }
            }
        }
    }

    /// yjs `tryMergeDeleteSet` (@3248) — try to merge deleted/gc'd items, right to
    /// left, so no merge target is missed. Reads `ds`; it mutates only the store.
    static func tryMergeDeleteSet(_ ds: YDeleteSet, _ store: YStructStore) throws {
        for (client, deleteItems) in ds.clients {
            guard let list = store.clients[client] else { continue }
            for deleteItem in deleteItems.reversed() {
                // Start with merging the item next to the last deleted item.
                //
                // `clock + len - 1` cannot underflow: every range in a transaction's
                // delete set is a struct's own range (`Item.delete`,
                // `ContentDeleted.integrate`) or a coalescing of them, and
                // `YStructIntegrator.validate` refuses a struct with length 0 at
                // ingest. Without that invariant a zero-length struct at clock 0 traps
                // here — where yjs computes -1 and throws catchably from findIndexSS.
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
