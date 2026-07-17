import Foundation

// MARK: - Struct refs

/// One client's decoded, not-yet-integrated structs plus a read cursor — yjs's
/// `{ i, refs }` entries in `clientsStructRefs`.
///
/// A class because the driver advances `i` through map lookups
/// (`structRefs.refs[structRefs.i++]`) and expects the advance to stick.
final class YStructRefs {
    var i: Int = 0
    var refs: [YStruct]

    init(refs: [YStruct]) {
        self.refs = refs
    }
}

extension YContent {
    /// Lift a decoded wire record into the live model.
    ///
    /// The only representation change is `.string`: `YContentRecord` keeps a Swift
    /// `String` (fine for a byte-identical re-encode), while the live model needs
    /// UTF-16 code units so `splice` can repair a broken surrogate pair — see
    /// `YContent.spliceString`.
    init(record: YContentRecord) {
        switch record {
        case .deleted(let length): self = .deleted(len: length)
        case .json(let items): self = .json(items)
        case .binary(let data): self = .binary(data)
        case .string(let s): self = .string(Array(s.utf16))
        case .embed(let json): self = .embed(json: json)
        case .format(let key, let valueJSON): self = .format(key: key, valueJSON: valueJSON)
        case .type(let typeRef): self = .type(YType(typeRef: typeRef))
        case .any(let values): self = .any(values)
        case .doc(let guid, let options): self = .doc(guid: guid, options: options)
        }
    }
}

extension YStructRefs {
    /// Build the driver's input from a decoded update — yjs `readClientsStructRefs`
    /// (@1418), minus the decoding B1 already did.
    ///
    /// Note this **creates root types**: yjs resolves a named parent with
    /// `doc.get(decoder.readString())` while reading, so a root named by any item
    /// exists in `doc.share` from here on, whether or not the item integrates.
    static func build(from update: YUpdate, doc: YDoc) throws -> [UInt: YStructRefs] {
        var clientsStructRefs: [UInt: YStructRefs] = [:]
        for block in update.blocks {
            var refs: [YStruct] = []
            refs.reserveCapacity(block.structs.count)
            for record in block.structs {
                try validate(record)
                switch record {
                case .gc(let id, let length):
                    refs.append(YGC(id: id, length: length))
                case .skip(let id, let length):
                    refs.append(YSkip(id: id, length: length))
                case .item(let item):
                    let parent: YItemParent?
                    switch item.parent {
                    case .named(let name): parent = .type(doc.get(name))
                    case .id(let id): parent = .id(id)
                    case nil: parent = nil  // copied from a neighbour at getMissing time
                    }
                    refs.append(
                        YItem(
                            id: item.id, left: nil, origin: item.origin, right: nil,
                            rightOrigin: item.rightOrigin, parent: parent,
                            parentSub: item.parentSub, content: YContent(record: item.content)))
                }
            }
            // Last block wins, exactly as yjs's `clientRefs.set(client, {i: 0, refs})`
            // (@1427) does. An update naming a client twice is malformed — a
            // well-formed one has one contiguous run per client — and appending the
            // second run instead would be worse than dropping it: the concatenation
            // can descend, and the driver stashes a client's *entire remaining run*
            // the moment one struct runs ahead of local state, so a descending run
            // strands the structs behind it in a stash that never drains.
            clientsStructRefs[block.client] = YStructRefs(refs: refs)
        }
        return clientsStructRefs
    }

    /// The store's one ingest invariant: **every struct has a non-empty clock range
    /// whose end fits in a `UInt`.** It is what makes all the clock arithmetic
    /// downstream — `lastId`, `getItemCleanEnd`, `tryMergeDeleteSet`, `addStruct`,
    /// `splitItem` — provably free of overflow and underflow, since every one of
    /// them is bounded by some struct's own `clock + length`.
    ///
    /// Both halves reject only what a real peer cannot send, and only where Swift
    /// would otherwise *trap* — a remote crash — rather than throw:
    ///
    /// - **Zero length.** yjs cannot author one: `YText.insert("")`,
    ///   `YArray.insert(0, [])` and friends no-op rather than emit an item. Its own
    ///   handling is incoherent — it integrates the degenerate item, then computes
    ///   `clock + len - 1 == -1` during cleanup and throws from `findIndexSS`. Swift
    ///   would underflow a `UInt` and trap on a 10-byte malformed frame. Rejecting up
    ///   front reaches yjs's outcome (the update is refused) through a catchable error.
    /// - **A clock range that overflows `UInt`.** Only reachable from bytes lib0
    ///   would never emit; `Lib0Decoder` accepts the full 64-bit range because its
    ///   encoder half must round-trip Swift's `UInt` (see `Lib0DecoderTests`).
    ///
    /// Deliberately **not** bounded at `Number.MAX_SAFE_INTEGER`, even though that is
    /// the largest clock JS can hold exactly: yjs's own guard sits inside
    /// `readVarUint`'s continuation branch, so a terminating varUInt slips past it and
    /// yjs simply stashes the struct as unreachably-far-ahead. Rejecting the whole
    /// update there would be *stricter than yjs* for input that cannot trap us.
    ///
    /// Reached only via malformed input; the caller turns it into `failSafe`.
    private static func validate(_ record: YStructRecord) throws {
        let (id, length): (YID, UInt) = {
            switch record {
            case .item(let item): return (item.id, item.content.length)
            case .gc(let id, let length), .skip(let id, let length): return (id, length)
            }
        }()
        guard length > 0 else { throw YIntegrationError.unexpectedCase }
        guard !id.clock.addingReportingOverflow(length).overflow else {
            throw YIntegrationError.unexpectedCase
        }
    }
}

// MARK: - The integration driver

enum YStructIntegrator {
    /// yjs `integrateStructs` (@1533) — integrate everything whose causal
    /// dependencies are satisfied, and hand back the rest.
    ///
    /// The shape is yjs's: a stack, plus a per-client cursor. When a struct names a
    /// dependency that has not arrived, it goes on the stack and the driver jumps
    /// to the reader that owns the missing client; when that reader is exhausted
    /// too, the whole stack is written off to `restStructs`. yjs notes the stack
    /// cannot cycle, so it is bounded by the number of readers.
    ///
    /// - Returns: the structs that could not be integrated, or nil if all did.
    static func integrateStructs(
        _ transaction: YTransaction, _ store: YStructStore,
        _ clientsStructRefs: inout [UInt: YStructRefs]
    ) throws -> YPendingStructs? {
        var stack: [YStruct] = []
        // Sorted ascending, but consumed from the **end** — yjs: "sort them so that
        // we take the higher id first, in case of conflicts the lower id will
        // probably not conflict with the id from the higher user".
        var clientsStructRefsIds = clientsStructRefs.keys.sorted()
        if clientsStructRefsIds.isEmpty { return nil }

        var restStructs: [UInt: [YStruct]] = [:]
        var missingSV: [UInt: UInt] = [:]

        func updateMissingSv(_ client: UInt, _ clock: UInt) {
            if let mclock = missingSV[client], mclock <= clock { return }
            missingSV[client] = clock
        }

        func getNextStructTarget() -> YStructRefs? {
            if clientsStructRefsIds.isEmpty { return nil }
            var nextStructsTarget = clientsStructRefs[clientsStructRefsIds[clientsStructRefsIds.count - 1]]
            while let target = nextStructsTarget, target.refs.count == target.i {
                clientsStructRefsIds.removeLast()
                if clientsStructRefsIds.isEmpty { return nil }
                nextStructsTarget = clientsStructRefs[clientsStructRefsIds[clientsStructRefsIds.count - 1]]
            }
            return nextStructsTarget
        }

        func addStackToRestSS() {
            for item in stack {
                let client = item.id.client
                if let inapplicableItems = clientsStructRefs[client] {
                    // Decrement because we weren't able to apply the previous operation.
                    inapplicableItems.i -= 1
                    restStructs[client] = Array(inapplicableItems.refs[inapplicableItems.i...])
                    clientsStructRefs.removeValue(forKey: client)
                    inapplicableItems.i = 0
                    inapplicableItems.refs = []
                } else {
                    // Item was the last on clientsStructRefs and the field was already
                    // cleared. Add item to restStructs and continue.
                    restStructs[client] = [item]
                }
                // Remove client from clientsStructRefsIds to prevent users from applying
                // the same update again.
                clientsStructRefsIds.removeAll { $0 == client }
            }
            stack.removeAll()
        }

        guard var curStructsTarget = getNextStructTarget() else { return nil }
        var stackHead = curStructsTarget.refs[curStructsTarget.i]
        curStructsTarget.i += 1
        // Caching the state because it is used very often.
        var state: [UInt: UInt] = [:]

        while true {
            if !(stackHead is YSkip) {
                let client = stackHead.id.client
                let localClock: UInt
                if let cached = state[client] {
                    localClock = cached
                } else {
                    localClock = store.getState(client)
                    state[client] = localClock
                }
                // Signed on purpose: a negative offset is the "this client's earlier
                // update is missing" signal.
                let offset: Int
                if localClock >= stackHead.id.clock {
                    // Bounded by the store's own size, so this always fits an Int.
                    guard let diff = Int(exactly: localClock - stackHead.id.clock) else {
                        throw YIntegrationError.unexpectedCase
                    }
                    offset = diff
                } else {
                    // Only the sign is read on this path. A wire clock is an unbounded
                    // varUInt, so computing the true (huge, negative) magnitude could
                    // overflow — JS just gets a float, Swift would trap.
                    offset = -1
                }
                if offset < 0 {
                    // Update from the same client is missing.
                    stack.append(stackHead)
                    // `clock - 1` cannot underflow: offset < 0 means clock > localClock >= 0.
                    updateMissingSv(client, stackHead.id.clock - 1)
                    // Hit a dead wall, add all items from stack to restSS.
                    addStackToRestSS()
                } else {
                    let missing = try stackHead.getMissing(transaction, store)
                    if let missing {
                        stack.append(stackHead)
                        // Get the struct reader that has the missing struct.
                        let structRefs = clientsStructRefs[missing] ?? YStructRefs(refs: [])
                        if structRefs.refs.count == structRefs.i {
                            // This update message causally depends on another update message
                            // that doesn't exist yet.
                            updateMissingSv(missing, store.getState(missing))
                            addStackToRestSS()
                        } else {
                            stackHead = structRefs.refs[structRefs.i]
                            structRefs.i += 1
                            continue
                        }
                    } else if offset == 0 || UInt(offset) < stackHead.length {
                        // All fine, apply the stackhead.
                        try stackHead.integrate(transaction, offset: offset)
                        state[stackHead.id.client] = stackHead.id.clock + stackHead.length
                    }
                    // else: entirely already applied — drop it silently, as yjs does.
                }
            }
            // Iterate to next stackHead.
            if let popped = stack.popLast() {
                stackHead = popped
            } else if curStructsTarget.i < curStructsTarget.refs.count {
                stackHead = curStructsTarget.refs[curStructsTarget.i]
                curStructsTarget.i += 1
            } else if let next = getNextStructTarget() {
                curStructsTarget = next
                stackHead = curStructsTarget.refs[curStructsTarget.i]
                curStructsTarget.i += 1
            } else {
                break  // we are done!
            }
        }

        guard !restStructs.isEmpty else { return nil }
        return YPendingStructs(missing: missingSV, refs: restStructs)
    }

    /// Merge two pending struct sets — standing in for yjs's
    /// `mergeUpdatesV2([pending.update, restStructs.update])`.
    ///
    /// The merge must be **ascending by clock per client**, which is what
    /// `mergeUpdatesV2` guarantees and what the driver quietly depends on: it walks
    /// a client's refs in order, and the first one whose clock runs ahead of local
    /// state sends the *entire remaining run* to `restStructs`. Concatenating a
    /// lower-clock run after a higher-clock one would therefore strand structs that
    /// were ready to integrate, and `missing` would never fall low enough to
    /// trigger a retry — a permanent stall.
    ///
    /// Both inputs are already ascending, so this is a merge, not a sort. Ties keep
    /// the existing run first; overlapping ranges need no special handling, since
    /// the driver's `offset` logic splits or skips whatever is already applied.
    ///
    /// Structs already in the stash are **dropped**, not appended again. A
    /// `(client, clock)` pair identifies an operation, so a struct with the same
    /// clock *and* length is literally the same op arriving twice — which a relay
    /// does routinely, and which yjs dedupes inside `mergeUpdatesV2`. Re-appending
    /// it is harmless for the resulting store (the driver's offset check drops a
    /// wholly-applied struct) but makes the stash grow without bound under
    /// redelivery. Found by the differential fuzz, which caught the stash diverging
    /// from yjs's by exactly the duplicated entries.
    static func mergePending(_ pending: YPendingStructs, _ rest: YPendingStructs) -> YPendingStructs {
        var merged = pending
        for (client, clock) in rest.missing {
            if let mclock = merged.missing[client], mclock <= clock { continue }
            merged.missing[client] = clock
        }
        for (client, newRefs) in rest.refs {
            guard let existing = merged.refs[client] else {
                merged.refs[client] = newRefs
                continue
            }
            // Only exact duplicates are dropped. A struct that merely *overlaps* one we
            // hold is a different view of the client's ops (a merged item vs the
            // incremental ones it came from) and is kept — splitting or skipping it is
            // precisely what the driver's offset handling is for.
            let held = Set(existing.map(PendingKey.init))
            let fresh = newRefs.filter { !held.contains(PendingKey($0)) }

            var out: [YStruct] = []
            out.reserveCapacity(existing.count + fresh.count)
            var a = 0
            var b = 0
            while a < existing.count && b < fresh.count {
                if fresh[b].id.clock < existing[a].id.clock {
                    out.append(fresh[b])
                    b += 1
                } else {
                    out.append(existing[a])
                    a += 1
                }
            }
            out.append(contentsOf: existing[a...])
            out.append(contentsOf: fresh[b...])
            merged.refs[client] = out
        }
        return merged
    }

    /// Identity of a stashed struct within one client's sequence.
    ///
    /// **The kind is part of the identity, and dropping it loses content.** A
    /// `(client, clock)` pair names an operation, but the same clock range can be
    /// stashed as a real `YItem` *and* as a `YSkip`: `mergeUpdates`/`diffUpdate`
    /// pad a hole in a client's block with a Skip, because a serialized update must
    /// tile its clock range with no gaps — and y-websocket/hocuspocus persistence
    /// emit exactly such merged updates. Keyed on `(clock, length)` alone, a held
    /// `YSkip(5,3)` matched the real `YItem(5,3)` arriving later and filtered it out
    /// as a redelivery: its text was lost, and the stash then stalled forever
    /// (nothing would ever supply those clocks again). Found in review, against the
    /// oracle; neither the fixtures nor the fuzz corpus contained a Skip.
    private struct PendingKey: Hashable {
        let clock: UInt
        let length: UInt
        let kind: ObjectIdentifier

        init(_ s: YStruct) {
            self.clock = s.id.clock
            self.length = s.length
            self.kind = ObjectIdentifier(type(of: s))
        }
    }
}

// MARK: - Applying an update

extension YDoc {
    /// yjs `readUpdateV2` (@1697) — apply a decoded v1 update to this replica.
    ///
    /// Structs whose dependencies have not arrived are stashed in
    /// `store.pendingStructs`; delete ranges naming absent structs go to
    /// `store.pendingDs`. When a later update supplies what was missing, the stash
    /// is replayed (the `retry` path) — which is what makes out-of-order delivery,
    /// the normal case over a relay like hocuspocus, converge.
    func applyUpdate(_ update: YUpdate) throws {
        try transact(local: false) { transaction in
            var clientsStructRefs = try YStructRefs.build(from: update, doc: self)
            try apply(transaction, refs: &clientsStructRefs, deleteSet: update.deleteSet)
        }
    }

    /// The body of `readUpdateV2`, factored out so the `retry` path can re-enter it.
    ///
    /// yjs re-enters via `applyUpdateV2(transaction.doc, update)`, whose `transact`
    /// *joins* the running transaction rather than opening another — so this is a
    /// plain recursive call, and the whole thing still settles in one cleanup.
    private func apply(
        _ transaction: YTransaction, refs: inout [UInt: YStructRefs], deleteSet: [YDeleteBlock]
    ) throws {
        let restStructs = try YStructIntegrator.integrateStructs(transaction, store, &refs)

        var retry = false
        if let pending = store.pendingStructs {
            // Check if we can apply something: a stashed dependency has arrived.
            for (client, clock) in pending.missing where clock < store.getState(client) {
                retry = true
                break
            }
            if let restStructs {
                store.pendingStructs = YStructIntegrator.mergePending(pending, restStructs)
            }
        } else {
            store.pendingStructs = restStructs
        }

        let dsRest = try YDeleteSet.readAndApply(deleteSet, transaction: transaction, store: store)
        if let pendingDs = store.pendingDs {
            // Replay the stashed ranges: structs they name may have just arrived.
            store.pendingDs = nil
            let dsRest2 = try YDeleteSet.readAndApply(
                pendingDs.asBlocks(), transaction: transaction, store: store)
            switch (dsRest, dsRest2) {
            case (.some(let a), .some(let b)): store.pendingDs = a.merging(b)
            default: store.pendingDs = dsRest ?? dsRest2
            }
        } else {
            store.pendingDs = dsRest
        }

        guard retry, let pending = store.pendingStructs else { return }
        store.pendingStructs = nil
        var pendingRefs = pending.refs.mapValues { YStructRefs(refs: $0) }
        // The stashed structs carry no delete set of their own — yjs encodes
        // `writeVarUint(0)` for them — but re-entering still gives `pendingDs`
        // another chance against whatever this pass integrates. Recursion
        // terminates: `pendingStructs` is nil on the way in, so the nested call
        // cannot set `retry`.
        try apply(transaction, refs: &pendingRefs, deleteSet: [])
    }
}

extension YDeleteSet {
    /// Re-present a delete set as the block list `readAndApply` consumes, so the
    /// stashed `pendingDs` can be replayed through the same path as a fresh one.
    ///
    /// Clients are sorted so a replay is deterministic; ranges are already sorted
    /// within a client by the time they are stashed.
    fileprivate func asBlocks() -> [YDeleteBlock] {
        clients.keys.sorted().map { client in
            YDeleteBlock(
                client: client,
                ranges: clients[client]!.map { YDeleteRange(clock: $0.clock, length: $0.len) })
        }
    }

    /// Union of two delete sets — standing in for `mergeUpdatesV2` on the pendingDs
    /// path. Ranges are appended and then normalized, exactly as
    /// `sortAndMergeDeleteSet` would do at the next cleanup.
    fileprivate func merging(_ other: YDeleteSet) -> YDeleteSet {
        var result = self
        for (client, items) in other.clients {
            result.clients[client, default: []].append(contentsOf: items)
        }
        result.sortAndMerge()
        return result
    }
}
