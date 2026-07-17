import Foundation

// MARK: - Delete set

/// One contiguous deleted clock range within a single client's sequence — yjs
/// `DeleteItem` (yjs.cjs @79).
struct YDeleteItem: Equatable, Sendable {
    var clock: UInt
    var len: UInt
}

/// The set of deleted id ranges, grouped by client — yjs `DeleteSet` (@103).
///
/// Client iteration order is deliberately unconstrained: yjs walks a JS `Map` in
/// insertion order, but every consumer here is per-client and the clients'
/// ranges are disjoint, so no result depends on that order. The one place order
/// *is* observable — writing a delete set to the wire — sorts clients explicitly
/// (yjs `writeDeleteSet` @285, descending), which is B3's concern.
struct YDeleteSet {
    var clients: [UInt: [YDeleteItem]] = [:]

    /// The order clients were first added — yjs's `Map` insertion order. Swift's
    /// `Dictionary` iterates unpredictably, but `cleanupYTextAfterTransaction`'s
    /// contextless-vs-full-cleanup routing is order-*sensitive* across clients (yjs
    /// is not confluent there: a format-owning client processed first suppresses the
    /// other clients' contextless cleanups). Iterating in insertion order reproduces
    /// yjs's result. Every other consumer (gc, merge, encode) is per-client and
    /// order-independent, so it ignores this.
    private(set) var clientInsertionOrder: [UInt] = []

    /// yjs `addToDeleteSet` (@238) — append a range, without sorting or merging.
    /// `sortAndMerge()` normalizes the whole set once, at transaction cleanup.
    mutating func add(client: UInt, clock: UInt, length: UInt) {
        if clients[client] == nil { clientInsertionOrder.append(client) }
        clients[client, default: []].append(YDeleteItem(clock: clock, len: length))
    }

    /// Client keys in yjs `Map` insertion order: the recorded order first, then any
    /// client present in `clients` but not recorded (a set built by direct
    /// assignment, e.g. `from(store:)`) appended in ascending order so iteration is
    /// still total and deterministic.
    var orderedClients: [UInt] {
        var seen = Set<UInt>()
        var result: [UInt] = []
        for client in clientInsertionOrder where clients[client] != nil && seen.insert(client).inserted {
            result.append(client)
        }
        for client in clients.keys.sorted() where seen.insert(client).inserted {
            result.append(client)
        }
        return result
    }

    var isEmpty: Bool { clients.isEmpty }

    /// yjs `sortAndMergeDeleteSet` (@179): sort each client's ranges by clock and
    /// coalesce overlapping/adjacent ones in place.
    ///
    /// yjs's `Array.sort` is stable, Swift's is not — which is immaterial here:
    /// two ranges sharing a clock merge to `max(left.len, right.len)` either way,
    /// so the coalesced output is identical whichever order they land in.
    mutating func sortAndMerge() {
        for (client, var dels) in clients {
            dels.sort { $0.clock < $1.clock }
            var j = 1
            var i = 1
            while i < dels.count {
                let left = dels[j - 1]
                let right = dels[i]
                if left.clock + left.len >= right.clock {
                    // `math.max(left.len, right.clock + right.len - left.clock)`, with
                    // the subtraction reassociated: the sort guarantees
                    // `right.clock >= left.clock`, so this cannot underflow.
                    dels[j - 1] = YDeleteItem(
                        clock: left.clock,
                        len: max(left.len, (right.clock - left.clock) + right.len))
                } else {
                    if j < i { dels[j] = right }
                    j += 1
                }
                i += 1
            }
            dels.removeSubrange(j...)  // yjs `dels.length = j`
            clients[client] = dels
        }
    }

    /// yjs `findIndexDS` (@141) — binary search for the range containing `clock`,
    /// or nil. Unlike `findIndexSS` this legitimately misses, so it returns nil
    /// rather than throwing.
    static func findIndex(_ dis: [YDeleteItem], _ clock: UInt) -> Int? {
        var left = 0
        var right = dis.count - 1
        while left <= right {
            let midindex = (left + right) / 2
            let mid = dis[midindex]
            if mid.clock <= clock {
                if clock < mid.clock + mid.len { return midindex }
                left = midindex + 1
            } else {
                right = midindex - 1
            }
        }
        return nil
    }

    /// yjs `isDeleted` (@168).
    func isDeleted(_ id: YID) -> Bool {
        guard let dis = clients[id.client] else { return false }
        return Self.findIndex(dis, id.clock) != nil
    }

    /// yjs `createDeleteSetFromStructStore` (@251) — the delete set implied by the
    /// store's own `deleted` flags, coalescing runs of adjacent deleted structs.
    static func from(store: YStructStore) -> YDeleteSet {
        var ds = YDeleteSet()
        for (client, list) in store.clients {
            let structs = list.structs
            var dsitems: [YDeleteItem] = []
            var i = 0
            while i < structs.count {
                let s = structs[i]
                if s.deleted {
                    let clock = s.id.clock
                    var len = s.length
                    // Coalesce the following deleted run. Transliterates yjs's
                    // `for (let next = structs[i+1]; i+1 < structs.length && next.deleted; next = structs[++i + 1])`.
                    while i + 1 < structs.count, structs[i + 1].deleted {
                        len += structs[i + 1].length
                        i += 1
                    }
                    dsitems.append(YDeleteItem(clock: clock, len: len))
                }
                i += 1
            }
            if !dsitems.isEmpty { ds.clients[client] = dsitems }
        }
        return ds
    }
}

// MARK: - Applying a delete set from an update

extension YDeleteSet {
    /// yjs `readAndApplyDeleteSet` (@341): apply an update's delete set to the
    /// store, splitting items at the range edges so exactly the deleted span is
    /// marked, and returning the ranges that **could not** be applied yet because
    /// the structs they name have not arrived.
    ///
    /// yjs returns those leftovers as a V2-encoded update to stash in
    /// `store.pendingDs`. Schrift keeps them as a `YDeleteSet` instead: the V2
    /// codec exists in yjs purely as an internal container for this and
    /// `pendingStructs`, and Schrift's wire is v1 end to end (y-protocols and the
    /// docs server both speak v1), so porting UpdateEncoderV2 would add a large
    /// codec with no wire consumer. This is an internal representation choice, not
    /// a protocol deviation — nothing here is ever transmitted. See
    /// `docs/architecture.md`, "Pending structs and delete sets".
    ///
    /// - Returns: the unapplied ranges, or nil if everything applied.
    @discardableResult
    static func readAndApply(
        _ deleteSet: [YDeleteBlock], transaction: YTransaction, store: YStructStore
    ) throws -> YDeleteSet? {
        var unapplied = YDeleteSet()
        for block in deleteSet {
            let client = block.client
            // yjs `store.clients.get(client) || []`: an unknown client yields a
            // throwaway empty list, never one stored back. `getState` is then 0, so
            // `clock < state` is false and every range lands in `unapplied` — the
            // empty list is never touched.
            let list = store.clients[client] ?? YStructList()
            let state = store.getState(client)
            for range in block.ranges {
                let clock = range.clock
                // Both operands come straight off the wire as unbounded varUInts, so
                // this is the one addition here that a malformed update can overflow —
                // a trap, where yjs (whose lib0 refuses to decode anything above
                // 2^53-1) simply never sees such a range. A zero *length* needs no
                // guard: yjs handles it harmlessly, as `clockEnd == clock` makes the
                // scan below exit on its first test.
                let (clockEnd, overflowed) = clock.addingReportingOverflow(range.length)
                guard !overflowed else { throw YIntegrationError.unexpectedCase }
                guard clock < state else {
                    // The whole range names structs that have not arrived.
                    unapplied.add(client: client, clock: clock, length: clockEnd - clock)
                    continue
                }
                if state < clockEnd {
                    // The range's tail runs past what we hold; hold on to just the tail.
                    unapplied.add(client: client, clock: state, length: clockEnd - state)
                }
                var index = try YStructStore.findIndexSS(list.structs, clock)
                var s = list.structs[index]
                // Split the first struct open if the range starts inside it. yjs
                // `@ts-ignore`s the Item cast: `!deleted` excludes GC and Skip (both
                // report `deleted == true`), so this is always an Item.
                if !s.deleted, s.id.clock < clock {
                    guard let item = s as? YItem else { throw YIntegrationError.unexpectedCase }
                    let right = try YStructStore.splitItem(
                        transaction, leftItem: item, diff: clock - s.id.clock)
                    list.structs.insert(right, at: index + 1)
                    index += 1
                }
                while index < list.structs.count {
                    s = list.structs[index]
                    index += 1
                    guard s.id.clock < clockEnd else { break }
                    if !s.deleted {
                        // Split the last struct open if the range ends inside it.
                        if clockEnd < s.id.clock + s.length {
                            guard let item = s as? YItem else { throw YIntegrationError.unexpectedCase }
                            let right = try YStructStore.splitItem(
                                transaction, leftItem: item, diff: clockEnd - s.id.clock)
                            list.structs.insert(right, at: index)
                        }
                        s.delete(transaction)
                    }
                }
            }
        }
        return unapplied.isEmpty ? nil : unapplied
    }
}
