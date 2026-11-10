import Foundation

// MARK: - Transaction

/// The origin bookkeeping values Schrift currently needs from yjs transactions.
enum YTransactionOrigin: Hashable {
    case localUser
    case remote
    /// A `YUndoManager`'s own undo/redo transactions — yjs passes the manager itself
    /// as the origin (@3574). Identity only; see `YUndoManager.origin`.
    case undoManager(ObjectIdentifier)
}

/// One `changedParentTypes` entry — yjs's `Map<AbstractType, Array<YEvent>>` pair,
/// kept as an ordered array so iteration is deterministic.
struct YChangedParentType {
    let type: YType
    var events: [YEvent]
}

/// One unit of change against a `YDoc` — yjs `Transaction` (@3081).
///
/// Reduced to the fields the struct store and the change signal actually read.
/// Deliberately **not** modelled: `subdocsAdded/Removed/Loaded` (Schrift's schema
/// has no subdocuments), `meta` (caller bookkeeping with no effect on state), and
/// the `ObservableV2` listener sets behind `observe`/`observeDeep` (no consumer
/// yet). The optional `origin` is retained as caller bookkeeping, matching yjs
/// `Transaction`.
final class YTransaction {
    let doc: YDoc
    /// yjs `Transaction.origin` (@3128); caller bookkeeping, not encoded state.
    let origin: YTransactionOrigin?
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
    /// by identity but keep the `YType` reference, because the observer phase reads
    /// each changed type's `_hasFormatting`. `Item.integrate`, `Item.delete`, and
    /// `YType.deleteChildren` all maintain it (the last removes by `ObjectIdentifier`);
    /// B5's projection will read the subs.
    var changed: [ObjectIdentifier: (type: YType, subs: Set<String?>)] = [:]
    /// The order types were first added to `changed` — yjs's `Map` insertion order.
    ///
    /// A Swift `Dictionary` iterates unpredictably, and the observer phase must run
    /// in yjs's order: the events it records at a shared ancestor are compared in
    /// that order, so a different order is a different `changedParentTypes`.
    ///
    /// **Slots, not a packed array.** `removeChangedType` must drop a type in O(1)
    /// (yjs's `Map.delete`); a packed array would need a linear scan per removal,
    /// and a remote update touching N types would then cost O(N²) — an algorithmic
    /// DoS any peer can trigger. A removed type's slot is nil'd, and a re-added type
    /// appends a fresh slot, so it moves to the end exactly as a JS `Map`
    /// delete-then-set does. The dispatch loop skips nil slots.
    private(set) var changedOrder: [ObjectIdentifier?] = []
    /// `changedOrder` slot per type — the O(1) half of the pair above.
    private var changedOrderIndex: [ObjectIdentifier: Int] = [:]
    /// yjs `changedParentTypes` (@3120) — every type an event was raised on, mapped
    /// to the events raised there. `callTypeObservers` records the event at the
    /// changed type and at every ancestor up to the root, so a consumer can find
    /// the enclosing `blockContainer` from an edited `XmlText`.
    ///
    /// yjs keys a `Map` by type; the array keeps yjs's insertion order (the order
    /// `_callObserver` ran), which is what a consumer sees. Lookup is by identity,
    /// through `changedParentTypeIndex` — a linear scan per event per ancestor would
    /// make a remote update touching N types O(N²).
    ///
    /// **Only populated while `doc.afterTransaction` or an observer is set.** It
    /// exists for those alone, so a replica with neither builds no events and
    /// leaves this empty (see `YType.callObserver`); the B4 formatting-cleanup arming is independent
    /// of it and still runs.
    private(set) var changedParentTypes: [YChangedParentType] = []
    /// `changedParentTypes` index per type — the O(1) half of the pair above.
    private var changedParentTypeIndex: [ObjectIdentifier: Int] = [:]
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

    init(doc: YDoc, local: Bool, origin: YTransactionOrigin? = nil) {
        self.doc = doc
        self.beforeState = doc.store.getStateVector()
        self.local = local
        self.origin = origin
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
            if changed[oid] == nil {
                changedOrderIndex[oid] = changedOrder.count
                changedOrder.append(oid)
            }
            var entry = changed[oid] ?? (type: type, subs: [])
            entry.subs.insert(parentSub)
            changed[oid] = entry
        }
    }

    /// yjs `transaction.changed.delete(type)` (@9514) — `ContentType.delete` drops
    /// the type it just emptied, so no observer fires for it.
    ///
    /// O(1): the type's `changedOrder` slot is nil'd rather than spliced out, and a
    /// later re-add appends a new slot (yjs's `Map` delete-then-set order).
    func removeChangedType(_ type: YType) {
        let oid = ObjectIdentifier(type)
        changed.removeValue(forKey: oid)
        if let slot = changedOrderIndex.removeValue(forKey: oid) {
            changedOrder[slot] = nil
        }
    }

    /// yjs `callTypeObservers`'s `setIfUndefined(changedParentTypes, type, () =>
    /// []).push(event)` (@5035) — append the event to the type's entry, creating
    /// the entry on first sight.
    func addChangedParentType(_ type: YType, _ event: YEvent) {
        let oid = ObjectIdentifier(type)
        if let index = changedParentTypeIndex[oid] {
            changedParentTypes[index].events.append(event)
        } else {
            changedParentTypeIndex[oid] = changedParentTypes.count
            changedParentTypes.append(YChangedParentType(type: type, events: [event]))
        }
    }

    /// Drop the events once the hook has run — see `cleanupTransactions`. Clears the
    /// index with the array so the two cannot disagree.
    func clearChangedParentTypes() {
        changedParentTypes = []
        changedParentTypeIndex = [:]
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
    /// See AGENTS.md "Malformed input must throw, never trap".
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
    /// yjs `transact` (@3437) — run `body` inside a transaction, then clean up.
    ///
    /// The nesting/re-entrancy dance is preserved: a transaction opened while one
    /// is already running joins it, and cleanup runs once, at the outermost exit,
    /// over every transaction queued in the meantime (an observer can open more —
    /// which is why yjs iterates rather than recurses over a fixed list).
    @discardableResult
    func transact<T>(local: Bool = true, origin: YTransactionOrigin? = nil, _ body: (YTransaction) throws -> T) throws
        -> T
    {
        var initialCall = false
        if transaction == nil {
            initialCall = true
            let newTransaction = YTransaction(doc: self, local: local, origin: origin)
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
        transaction.doc.lastTransactionOrigin = transaction.origin
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

            // yjs @3296-3306: dispatch each changed type's `_callObserver`, in
            // `transaction.changed` insertion order, skipping a type whose owning
            // item is deleted. This is what populates `changedParentTypes` (the
            // change signal) and what arms B4's formatting cleanup — the arming
            // lives in `YType.callObserver`, mirroring `YText._callObserver`, and
            // runs whether or not a hook is set. With no hook the events are not
            // built at all, so `changedParentTypes` stays empty.
            //
            // The order is snapshotted first, as yjs builds its `fs` array before
            // running any callback. Slots a `removeChangedType` nil'd are skipped.
            let changedOrder = transaction.changedOrder
            for case let oid? in changedOrder {
                guard let entry = transaction.changed[oid] else { continue }
                let type = entry.type
                guard type.item == nil || !(type.item!.deleted) else { continue }
                type.callObserver(transaction, entry.subs)
            }

            // yjs @3337: `doc.emit('afterTransaction', [transaction, doc])`,
            // pushed by the deep-observer closure so it runs after every
            // `_callObserver` and before the formatting cleanup. This is the
            // change signal: `changedParentTypes` is complete and the store is
            // still pre-gc/pre-merge, so a coalesced run of typing still reads as
            // inserts. A nil hook runs nothing. Then the registered observers
            // (`YUndoManager`), in registration order, as yjs's `emit` runs every
            // `'afterTransaction'` listener; a throw is an observer-phase error.
            transaction.doc.afterTransaction?(transaction)
            for (_, observer) in transaction.doc.afterTransactionObservers {
                try observer(transaction)
            }

            // Drop the events now that the hook has run. yjs keeps
            // `changedParentTypes` on the transaction and lets the tracing GC
            // collect the `Transaction ⇄ YEvent` cycle; ARC would keep the
            // transaction — and through `changed`, the whole type graph — alive
            // for the lifetime of the process. The events are only meaningful
            // during the hook anyway: their deltas read the pre-gc/pre-merge
            // store, so a consumer that stashes one would read a stale delta.
            transaction.clearChangedParentTypes()

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

            // yjs @3388-3392: emit `'update'` for every transaction with content,
            // after gc/merge and the client-id re-roll, before the next queued
            // cleanup. This is what lets a provider broadcast the formatting-cleanup
            // transaction (origin nil) that the observer phase just opened. A nil
            // hook runs nothing. An encode failure is swallowed, never thrown out of
            // cleanup: the event is a best-effort broadcast mirror, and a store with
            // pending structs/deletes (which the encoder refuses) emits nothing.
            // The listener encodes lazily, so origins it ignores cost nothing.
            if let onUpdate = transaction.doc.onUpdate {
                onUpdate(transaction.origin) { try? YTransactionEncoder.encodeUpdate(transaction, duringCleanup: true) }
            }

            if transactionCleanups.count <= i + 1 {
                transactionCleanups = []
                // yjs `Doc`'s `'afterAllTransactions'`: the outermost cleanup is
                // done and `doc.transaction` is nil. A listener may open a
                // transaction here (the engine's surface does); it is queued and
                // drained by the enclosing `transact` loop, exactly as in yjs.
                transaction.doc.afterAllTransactions?()
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
    /// yjs's `gcFilter` defaults to `() => true` (gc everything) and Schrift has no
    /// other filter, so the only gate is `deleted && !keep`: `keep` is what
    /// `YUndoManager` sets on deletions its stacks can still restore.
    /// `gc(store, parentGCd: false)` replaces content in place (no `replaceStruct`), so the iterated array's
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
