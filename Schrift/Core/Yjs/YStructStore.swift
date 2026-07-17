import Foundation

// MARK: - Per-client struct list

/// One client's structs, in ascending clock order, as a **reference**.
///
/// yjs keeps each client's structs in a JS array and hands that array around
/// freely (`const structs = store.clients.get(client)`), then splices into it —
/// mutating the one array the store holds. A Swift `[YStruct]` is a value, so the
/// same code would splice into a copy and silently lose the split. This box
/// restores the reference semantics every helper below assumes.
///
/// Read-only helpers still take a plain `[YStruct]`; only the ones that yjs
/// splices into take the list itself.
final class YStructList {
    var structs: [YStruct] = []

    init(_ structs: [YStruct] = []) {
        self.structs = structs
    }
}

// MARK: - Struct store

/// The set of all known structs, grouped by client — yjs `StructStore` (@2821).
///
/// A `final class` because yjs's store is a single mutable object reachable from
/// every struct via `transaction.doc.store`, and the integration algorithm wires
/// items to each other by identity.
final class YStructStore {
    /// client → that client's structs, contiguous and ascending by clock.
    var clients: [UInt: YStructList] = [:]

    /// Structs that arrived before their causal dependencies and are waiting for
    /// them — yjs `pendingStructs` (`{ missing, update }`).
    ///
    /// yjs stores the leftovers as a **V2-encoded update**; Schrift keeps the
    /// decoded refs instead. The V2 codec is, in yjs, purely an internal container
    /// for this and `pendingDs` — Schrift's wire is v1 end to end (y-protocols and
    /// the docs server both speak v1), so porting UpdateEncoderV2 +
    /// mergeUpdatesV2 + diffUpdateV2 would add a large codec with no wire
    /// consumer. Nothing here is ever transmitted, so this is an internal
    /// representation choice, not a protocol deviation.
    ///
    /// The one yjs behavior that *does* observe pendingStructs on the wire —
    /// `encodeStateAsUpdate` folding them in via `diffUpdateV2` — is exactly what
    /// the roadmap's top safety rule forbids anyway: a replica with pending
    /// structs must never be snapshotted back to the server. See
    /// `docs/architecture.md`, "Pending structs and delete sets".
    var pendingStructs: YPendingStructs?

    /// Delete ranges naming structs that have not arrived yet — yjs `pendingDs`
    /// (a V2 update there; a plain delete set here, for the same reason).
    var pendingDs: YDeleteSet?

    init() {}

    // MARK: State

    /// yjs `getState` (@2865) — the next unused clock for `client`.
    func getState(_ client: UInt) -> UInt {
        guard let list = clients[client], let last = list.structs.last else { return 0 }
        return last.id.clock + last.length
    }

    /// yjs `getStateVector` (@2848).
    func getStateVector() -> [UInt: UInt] {
        var sm: [UInt: UInt] = [:]
        for (client, list) in clients {
            guard let last = list.structs.last else { continue }
            sm[client] = last.id.clock + last.length
        }
        return sm
    }

    // MARK: Adding

    /// yjs `addStruct` (@2881) — append a struct to its client's list.
    ///
    /// The contiguity check is yjs's: a client's structs must tile its clock range
    /// with no gap and no overlap. yjs throws `unexpectedCase` on a violation, and
    /// so do we — reaching it means the integration driver let a struct through
    /// out of order, which would corrupt every later binary search.
    func addStruct(_ s: YStruct) throws {
        if let list = clients[s.id.client] {
            guard let last = list.structs.last else { throw YIntegrationError.unexpectedCase }
            guard last.id.clock + last.length == s.id.clock else {
                throw YIntegrationError.unexpectedCase
            }
            list.structs.append(s)
        } else {
            clients[s.id.client] = YStructList([s])
        }
    }

    // MARK: Searching

    /// yjs `findIndexSS` (@2904) — binary search for the struct whose clock range
    /// contains `clock`.
    ///
    /// The initial `midindex` is yjs's *pivot*: a proportional guess that often
    /// hits on the first probe. It is float arithmetic in JS, so it is float
    /// arithmetic here — an integer pivot would probe different slots. (The pivot
    /// only picks a starting point; the surrounding search is correct regardless,
    /// so this cannot change the *answer* — but transliterating it keeps the two
    /// implementations line-comparable.)
    ///
    /// yjs's contract is "always check state before looking for a struct", so a
    /// miss is `unexpectedCase` rather than nil.
    static func findIndexSS(_ structs: [YStruct], _ clock: UInt) throws -> Int {
        guard !structs.isEmpty else { throw YIntegrationError.unexpectedCase }
        var left = 0
        var right = structs.count - 1
        var mid = structs[right]
        var midclock = mid.id.clock
        if midclock == clock { return right }

        // `math.floor((clock / (midclock + mid.length - 1)) * right)`. In JS a zero
        // denominator yields Infinity/NaN and the subsequent `structs[NaN]` throws;
        // Swift would trap converting that to Int, so clamp into range instead and
        // let the search below do the work. Same outcome, no trap.
        var midindex = pivotIndex(clock: clock, midclock: midclock, midLength: mid.length, right: right)
        while left <= right {
            guard midindex >= 0, midindex < structs.count else {
                throw YIntegrationError.unexpectedCase
            }
            mid = structs[midindex]
            midclock = mid.id.clock
            if midclock <= clock {
                if clock < midclock + mid.length { return midindex }
                left = midindex + 1
            } else {
                right = midindex - 1
            }
            midindex = (left + right) / 2
        }
        // yjs: "the case of not finding a struct is unexpected".
        throw YIntegrationError.unexpectedCase
    }

    /// The proportional first probe of `findIndexSS`, isolated so its float
    /// arithmetic — and the degenerate denominators JS tolerates — are testable.
    static func pivotIndex(clock: UInt, midclock: UInt, midLength: UInt, right: Int) -> Int {
        // Computed entirely in Double, as in JS: `midclock + midLength - 1` is 0 for
        // a single struct at clock 0 (and would underflow as UInt), and JS's own
        // `- 1` happens in floating point too.
        let denominator = Double(midclock) + Double(midLength) - 1
        let pivot = ((Double(clock) / denominator) * Double(right)).rounded(.down)
        // NaN (0/0) and ±Infinity are exactly the cases JS turns into a throwing
        // `structs[NaN]`; clamping keeps the probe in bounds and the search
        // converges — or throws `unexpectedCase` — from there, reaching the same
        // outcome without crashing. Clamp in Double space: `Int(pivot)` on an
        // out-of-range Double traps.
        guard pivot.isFinite else { return 0 }
        if pivot <= 0 { return 0 }
        if pivot >= Double(right) { return right }
        return Int(pivot)
    }

    /// yjs `find`/`getItem` (@2944) — the struct containing `id`.
    func getItem(_ id: YID) throws -> YStruct {
        guard let list = clients[id.client] else { throw YIntegrationError.unexpectedCase }
        return list.structs[try Self.findIndexSS(list.structs, id.clock)]
    }

    /// yjs `findIndexCleanStart` (@2965) — the index of the struct *starting* at
    /// `clock`, splitting one open if the clock lands inside it.
    static func findIndexCleanStart(
        _ transaction: YTransaction, _ list: YStructList, _ clock: UInt
    ) throws -> Int {
        let index = try findIndexSS(list.structs, clock)
        let s = list.structs[index]
        if s.id.clock < clock, let item = s as? YItem {
            let right = try splitItem(transaction, leftItem: item, diff: clock - s.id.clock)
            list.structs.insert(right, at: index + 1)
            return index + 1
        }
        return index
    }

    /// yjs `iterateStructs` (yjs.cjs @3040) — call `f` on every struct overlapping
    /// `[clockStart, clockStart+len)`, splitting the boundary structs clean.
    ///
    /// Note yjs's `cleanupYTextAfterTransaction` passes a `len` that overshoots the
    /// client's last clock (it passes the after-state, not after minus before); the
    /// `index < structs.count` bound stops the walk at the array end and the overshoot
    /// merely skips the (never-reached) end split — transliterated as written, not
    /// "fixed".
    static func iterateStructs(
        _ transaction: YTransaction, _ list: YStructList, clockStart: UInt, len: UInt,
        _ f: (YStruct) throws -> Void
    ) throws {
        if len == 0 { return }
        // yjs computes `clockStart + len` in JS floating point, where the
        // `cleanupYTextAfterTransaction` overshoot (`len == afterClock`, so
        // `clockStart + len` can exceed `UInt.max`) is a large-but-finite value that
        // every real clock still compares below. Swift's `UInt + UInt` traps on
        // overflow — a remote crash on a crafted near-`UInt.max` state. Saturate to
        // `UInt.max` instead: `clockEnd` is only compared (`clockEnd < s.id.clock +
        // s.length`, `structs[i].id.clock < clockEnd`) and every real clock end is
        // `<= UInt.max` (`YStructIntegrator.validate`), so clamping preserves yjs's
        // harmless-overshoot semantics without trapping.
        let sum = clockStart.addingReportingOverflow(len)
        let clockEnd = sum.overflow ? UInt.max : sum.partialValue
        var index = try findIndexCleanStart(transaction, list, clockStart)
        repeat {
            let s = list.structs[index]
            index += 1
            if clockEnd < s.id.clock + s.length {
                _ = try findIndexCleanStart(transaction, list, clockEnd)
            }
            try f(s)
        } while index < list.structs.count && list.structs[index].id.clock < clockEnd
    }

    /// yjs `getItemCleanStart` (@2985).
    static func getItemCleanStart(_ transaction: YTransaction, _ id: YID) throws -> YStruct {
        guard let list = transaction.doc.store.clients[id.client] else {
            throw YIntegrationError.unexpectedCase
        }
        return list.structs[try findIndexCleanStart(transaction, list, id.clock)]
    }

    /// yjs `getItemCleanEnd` (@3001) — the struct *ending* at `id.clock`,
    /// splitting one open if the clock lands before its end.
    ///
    /// Note this returns the **left** half (yjs returns `struct`, the one it found,
    /// not the freshly inserted right half) — the opposite of `getItemCleanStart`.
    static func getItemCleanEnd(
        _ transaction: YTransaction, _ store: YStructStore, _ id: YID
    ) throws -> YStruct {
        guard let list = store.clients[id.client] else { throw YIntegrationError.unexpectedCase }
        let index = try findIndexSS(list.structs, id.clock)
        let s = list.structs[index]
        // yjs writes `id.clock !== struct.id.clock + struct.length - 1`. Reassociated
        // to keep the `- 1` off a UInt: algebraically identical here, and it cannot
        // underflow even if the ingest invariant (`YStructIntegrator.validate`:
        // length >= 1) is ever weakened.
        if id.clock + 1 != s.id.clock + s.length, let item = s as? YItem {
            let right = try splitItem(transaction, leftItem: item, diff: id.clock - s.id.clock + 1)
            list.structs.insert(right, at: index + 1)
        }
        return s
    }

    /// yjs `replaceStruct` (@3024).
    func replaceStruct(_ s: YStruct, with newStruct: YStruct) throws {
        guard let list = clients[s.id.client] else { throw YIntegrationError.unexpectedCase }
        list.structs[try Self.findIndexSS(list.structs, s.id.clock)] = newStruct
    }

    // MARK: Splitting

    /// yjs `splitItem` (@9610) — cut `leftItem` at `diff`, returning the new right
    /// half already wired into the linked list.
    ///
    /// It does **not** insert the right half into the store's array: every caller
    /// splices it in at the index it already knows (`findIndexCleanStart`,
    /// `getItemCleanEnd`, `readAndApply`), exactly as in yjs.
    static func splitItem(_ transaction: YTransaction, leftItem: YItem, diff: UInt) throws -> YItem {
        let client = leftItem.id.client
        let clock = leftItem.id.clock
        var leftContent = leftItem.content
        let rightContent = try leftContent.splice(diff)
        leftItem.content = leftContent

        let rightItem = YItem(
            id: YID(client: client, clock: clock + diff),
            left: leftItem,
            origin: YID(client: client, clock: clock + diff - 1),
            right: leftItem.right,
            rightOrigin: leftItem.rightOrigin,
            parent: leftItem.parent,
            parentSub: leftItem.parentSub,
            content: rightContent)

        if leftItem.deleted { rightItem.markDeleted() }
        if leftItem.keep { rightItem.keep = true }
        if let redone = leftItem.redone {
            rightItem.redone = YID(client: redone.client, clock: redone.clock + diff)
        }
        // Update left. yjs deliberately does *not* set leftItem.rightOrigin — "it
        // will lead to problems when syncing".
        leftItem.right = rightItem
        // Update right.
        rightItem.right?.left = rightItem
        // "right is more specific."
        transaction.mergeStructs.append(rightItem)
        // Update parent._map.
        if let sub = rightItem.parentSub, rightItem.right == nil {
            rightItem.parentType?.map[sub] = rightItem
        }
        leftItem.length = diff
        return rightItem
    }
}

// MARK: - Pending structs

/// Structs held back because an update they causally depend on has not arrived —
/// yjs's `{ missing, update }`, with the decoded refs standing in for the V2
/// update (see `YStructStore.pendingStructs`).
struct YPendingStructs {
    /// client → the lowest clock we are still missing from that client.
    var missing: [UInt: UInt]
    /// client → the structs still to integrate, in wire order.
    var refs: [UInt: [YStruct]]
}
