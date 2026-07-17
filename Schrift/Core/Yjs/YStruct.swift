import Foundation

// MARK: - Base struct

/// A struct in the live store — yjs `AbstractStruct` (@8456).
///
/// A class hierarchy rather than an enum because the algorithm wires structs to
/// one another **by identity** (`this.left.right = this`, `Set<Item>` membership,
/// `o !== this.right`), which only reference types provide.
///
/// The defaults here are yjs's own: `mergeWith` returns false on `AbstractStruct`,
/// while `deleted`/`getMissing`/`delete` are defined identically on `GC` and
/// `Skip` (deleted, no dependencies, deleting is a no-op). `YItem` overrides all
/// four. `YStruct` itself is never instantiated.
class YStruct {
    var id: YID
    var length: UInt

    init(id: YID, length: UInt) {
        self.id = id
        self.length = length
    }

    /// yjs: `GC`/`Skip` both `return true`; `Item` reads its info bit.
    var deleted: Bool { true }

    /// yjs `AbstractStruct.mergeWith` (@8484) — "does *not* remove right from
    /// StructStore"; the caller does that.
    func mergeWith(_ right: YStruct) -> Bool { false }

    /// yjs: the client id of a struct this one causally depends on and that has
    /// not arrived, or nil. `GC`/`Skip` never depend on anything.
    func getMissing(_ transaction: YTransaction, _ store: YStructStore) throws -> UInt? { nil }

    /// yjs: `GC.delete`/`Skip.delete` are no-ops.
    func delete(_ transaction: YTransaction) {}

    func integrate(_ transaction: YTransaction, offset: Int) throws {
        throw YIntegrationError.methodUnimplemented
    }
}

// MARK: - GC

/// A garbage-collected span — yjs `GC` (@8507). Content ref 0.
///
/// GCs exist in this milestone even though `YDoc.gc` is off: they arrive on the
/// wire from peers that *do* collect, and `YItem.integrate` mints one whenever an
/// item turns out to have no parent.
final class YGC: YStruct {
    override func mergeWith(_ right: YStruct) -> Bool {
        guard type(of: right) == YGC.self else { return false }
        length += right.length
        return true
    }

    override func integrate(_ transaction: YTransaction, offset: Int) throws {
        if offset > 0 {
            guard let o = UInt(exactly: offset), o < length else {
                throw YIntegrationError.unexpectedCase
            }
            id.clock += o
            length -= o
        }
        try transaction.doc.store.addStruct(self)
    }
}

// MARK: - Skip

/// A gap the sender knows nothing about — yjs `Skip` (@10256). Content ref 10.
///
/// Skips are never integrated: the driver tests for them explicitly
/// (`integrateStructs`: `if (stackHead.constructor !== Skip)`) and steps over
/// them, so reaching `integrate` is `unexpectedCase` — exactly as in yjs.
final class YSkip: YStruct {
    override func mergeWith(_ right: YStruct) -> Bool {
        guard type(of: right) == YSkip.self else { return false }
        length += right.length
        return true
    }

    override func integrate(_ transaction: YTransaction, offset: Int) throws {
        throw YIntegrationError.unexpectedCase
    }
}

// MARK: - Item

/// What an item names as its parent. yjs types this `AbstractType<any> | ID | null`:
/// an `ID` before integration (a nested type, to be looked up), a type once
/// resolved, and nil when it should be copied from a neighbour — or when the item
/// turns out to be garbage.
enum YItemParent {
    case type(YType)
    case id(YID)
}

/// A single YATA operation — yjs `Item` (@9775).
final class YItem: YStruct {
    /// The item originally to the left when this was created. Immutable identity
    /// for conflict resolution — not the same as `left`.
    var origin: YID?
    /// The item currently to the left.
    var left: YItem?
    /// The item currently to the right.
    var right: YItem?
    /// The item originally to the right when this was created.
    var rightOrigin: YID?
    var parent: YItemParent?
    /// The map key this item is a value for, or nil when it is a list child.
    var parentSub: String?
    /// Set by the undo manager, which this milestone does not model — always nil.
    /// `mergeWith` and `splitItem` both read it, so it is carried rather than
    /// dropped.
    var redone: YID?
    var content: YContent

    /// Runtime flags — yjs `Item.info`:
    /// bit1 `0x01` keep · bit2 `0x02` countable · bit3 `0x04` deleted · bit4 `0x08` marker.
    ///
    /// **Not** the wire info byte. `YItemRecord.info` (`YUpdateDecoder.swift`)
    /// encodes the content ref and the origin/parentSub presence bits for
    /// serialization; this one is local state. They share a name in yjs and mean
    /// different things.
    var info: UInt8

    init(
        id: YID, left: YItem?, origin: YID?, right: YItem?, rightOrigin: YID?,
        parent: YItemParent?, parentSub: String?, content: YContent
    ) {
        self.origin = origin
        self.left = left
        self.right = right
        self.rightOrigin = rightOrigin
        self.parent = parent
        self.parentSub = parentSub
        self.redone = nil
        self.content = content
        self.info = content.isCountable ? 0x02 : 0
        super.init(id: id, length: content.length)
    }

    // MARK: Flags

    var keep: Bool {
        get { info & 0x01 > 0 }
        set { if keep != newValue { info ^= 0x01 } }
    }

    var countable: Bool { info & 0x02 > 0 }

    override var deleted: Bool { info & 0x04 > 0 }

    func markDeleted() { info |= 0x04 }

    var marker: Bool {
        get { info & 0x08 > 0 }
        set { if marker != newValue { info ^= 0x08 } }
    }

    /// The parent as a resolved type, or nil if it is still an unresolved id.
    var parentType: YType? {
        if case .type(let type) = parent { return type }
        return nil
    }

    /// yjs `get lastId` (@9822) — the id of this item's final unit.
    var lastId: YID {
        length == 1 ? id : YID(client: id.client, clock: id.clock + length - 1)
    }

    // MARK: Dependencies

    /// yjs `Item.getMissing` (@9880): report the client whose update we are still
    /// waiting on, or resolve `origin`/`rightOrigin`/`parent` into live references
    /// and return nil.
    ///
    /// Note this **mutates**: on the nil path it is the step that turns wire ids
    /// into pointers, splitting neighbours open as needed. The driver calls it
    /// exactly once per struct before `integrate`.
    override func getMissing(_ transaction: YTransaction, _ store: YStructStore) throws -> UInt? {
        if let origin, origin.client != id.client, origin.clock >= store.getState(origin.client) {
            return origin.client
        }
        if let rightOrigin, rightOrigin.client != id.client,
            rightOrigin.clock >= store.getState(rightOrigin.client)
        {
            return rightOrigin.client
        }
        if case .id(let parentID) = parent, id.client != parentID.client,
            parentID.clock >= store.getState(parentID.client)
        {
            return parentID.client
        }

        // We have all missing ids, now find the items.
        //
        // yjs assigns the resolved *struct* straight into `this.left`/`this.right`
        // — untyped JS, so a `GC` lands in an `Item`-typed field transiently. Swift's
        // fields are `YItem?`, so the raw structs are held alongside: they exist only
        // for the GC test below, after which `parent = nil` makes `integrate` mint a
        // GC and never read either field again.
        var leftStruct: YStruct?
        var rightStruct: YStruct?
        if let origin {
            let resolved = try YStructStore.getItemCleanEnd(transaction, store, origin)
            leftStruct = resolved
            self.left = resolved as? YItem
            // yjs reads `.lastId`, which is undefined on a GC and poisons `origin` —
            // harmlessly, since the GC test below then routes this item to the GC
            // branch without reading it. Leaving `origin` untouched there is the same
            // unread value, minus the undefined.
            if let leftItem = resolved as? YItem { self.origin = leftItem.lastId }
        }
        if let rightOrigin {
            let resolved = try YStructStore.getItemCleanStart(transaction, rightOrigin)
            rightStruct = resolved
            self.right = resolved as? YItem
            self.rightOrigin = resolved.id  // `.id` is on every struct, GC included
        }
        if leftStruct is YGC || rightStruct is YGC {
            // A neighbour was collected, so this item is garbage too — signalled to
            // `integrate` by clearing the parent, which mints a GC instead.
            parent = nil
        } else if parent == nil {
            // Only set parent if this shouldn't be garbage collected.
            if let left {
                parent = left.parent
                parentSub = left.parentSub
            } else if let right {
                parent = right.parent
                parentSub = right.parentSub
            }
        } else if case .id(let parentID) = parent {
            let parentItem = try store.getItem(parentID)
            if let parentItem = parentItem as? YItem, case .type(let type) = parentItem.content {
                parent = .type(type)
            } else {
                // yjs: a GC'd parent means this is garbage. It also reaches here for a
                // non-ContentType parent, where `(parentItem.content).type` is undefined
                // and yjs would carry `parent = undefined` — falsy, so `integrate` takes
                // the same GC branch. Clearing the parent is that outcome, spelled out.
                parent = nil
            }
        }
        return nil
    }

    // MARK: Integration — the YATA conflict loop

    /// yjs `Item.integrate` (@9944).
    ///
    /// **This is the algorithm.** It is transliterated line for line and must stay
    /// that way: every branch below decides where a concurrent insert lands, and a
    /// "cleaner" rewrite that disagrees with yjs on one ordering silently corrupts
    /// documents that real web clients then render. See `docs/architecture.md`,
    /// "The YATA conflict loop".
    override func integrate(_ transaction: YTransaction, offset: Int) throws {
        if offset > 0 {
            guard let o = UInt(exactly: offset), o < length else {
                throw YIntegrationError.unexpectedCase
            }
            id.clock += o
            let leftStruct = try YStructStore.getItemCleanEnd(
                transaction, transaction.doc.store, YID(client: id.client, clock: id.clock - 1))
            // yjs types this `Item`. A GC here would leave `origin = undefined` and
            // then throw on `undefined.client` inside the conflict loop, so a GC is
            // `unexpectedCase` either way — thrown up front rather than several
            // frames later. (Unreachable while gc is off; B4 must revisit.)
            guard let leftItem = leftStruct as? YItem else { throw YIntegrationError.unexpectedCase }
            self.left = leftItem
            self.origin = leftItem.lastId
            // `this.content = this.content.splice(offset)`: splice truncates the
            // receiver to the already-applied left half and returns the rest, which
            // the item then adopts — discarding the left half it just made.
            var remaining = content
            self.content = try remaining.splice(o)
            self.length -= o
        }

        guard let parent else {
            // Parent is not defined. Integrate GC struct instead.
            try YGC(id: id, length: length).integrate(transaction, offset: 0)
            return
        }
        // By construction `getMissing` has resolved the parent to a type before
        // `integrate` runs; an id here means the driver skipped that step.
        guard case .type(let parentType) = parent else { throw YIntegrationError.unexpectedCase }

        if (left == nil && (right == nil || right!.left != nil))
            || (left != nil && left!.right !== right)
        {
            var left = self.left
            var o: YItem?
            // Set o to the first conflicting item.
            if let left {
                o = left.right
            } else if let parentSub {
                o = parentType.map[parentSub]
                while let current = o, current.left != nil { o = current.left }
            } else {
                o = parentType.start
            }

            var conflictingItems = Set<ObjectIdentifier>()
            var itemsBeforeOrigin = Set<ObjectIdentifier>()
            // Let c in conflictingItems, b in itemsBeforeOrigin
            // ***{origin}bbbb{this}{c,b}{c,b}{o}***
            // Note that conflictingItems is a subset of itemsBeforeOrigin
            while let current = o, current !== self.right {
                itemsBeforeOrigin.insert(ObjectIdentifier(current))
                conflictingItems.insert(ObjectIdentifier(current))
                // `compareIDs` is exactly Optional<YID> equality: nil == nil is true,
                // nil == some is false, and equal fields compare equal.
                if self.origin == current.origin {
                    // case 1
                    if current.id.client < self.id.client {
                        left = current
                        conflictingItems.removeAll()
                    } else if self.rightOrigin == current.rightOrigin {
                        // this and o are conflicting and point to the same integration
                        // points. The id decides which item comes first. Since this is to
                        // the left of o, we can break here.
                        break
                    }
                    // else, o might be integrated before an item that this conflicts
                    // with. If so, we will find it in the next iterations.
                } else if let originStruct = try current.origin.map({
                    // `getItem`, not `getItemCleanEnd` — we don't want / need to split.
                    // A GC here is simply absent from both sets, which is what JS's
                    // reference-identity `Set.has` also reports.
                    try transaction.doc.store.getItem($0)
                }), itemsBeforeOrigin.contains(ObjectIdentifier(originStruct)) {
                    // case 2
                    if !conflictingItems.contains(ObjectIdentifier(originStruct)) {
                        left = current
                        conflictingItems.removeAll()
                    }
                } else {
                    break
                }
                o = current.right
            }
            self.left = left
        }

        // Reconnect left/right + update parent map/start if necessary.
        if let left {
            let right = left.right
            self.right = right
            left.right = self
        } else {
            var r: YItem?
            if let parentSub {
                r = parentType.map[parentSub]
                while let current = r, current.left != nil { r = current.left }
            } else {
                r = parentType.start
                parentType.start = self
            }
            self.right = r
        }

        if let right {
            right.left = self
        } else if let parentSub {
            // Set as current parent value if right === null and this is parentSub.
            parentType.map[parentSub] = self
            // This is the current attribute value of parent. Delete right.
            left?.delete(transaction)
        }

        // Adjust length of parent.
        if parentSub == nil, countable, !deleted {
            parentType.length += length
        }
        try transaction.doc.store.addStruct(self)
        content.integrate(transaction, item: self)
        // Add parent to transaction.changed.
        transaction.addChangedType(parentType, parentSub: parentSub)
        if (parentType.item != nil && parentType.item!.deleted) || (parentSub != nil && right != nil) {
            // Delete if parent is deleted or if this is not the current attribute
            // value of parent.
            delete(transaction)
        }
    }

    // MARK: Merging

    /// yjs `Item.mergeWith` (@9827) — absorb the immediately following item.
    ///
    /// Every clause is load-bearing: two items merge only when they are the same
    /// client's adjacent clocks, agree on both integration points, share a delete
    /// state, and hold content that concatenates. `content.mergeWith` is last
    /// because it *mutates* — Swift's `&&` short-circuits exactly like JS's, so it
    /// runs only once every other clause has passed.
    override func mergeWith(_ right: YStruct) -> Bool {
        guard let right = right as? YItem else { return false }
        guard right.origin == lastId,
            self.right === right,
            rightOrigin == right.rightOrigin,
            id.client == right.id.client,
            id.clock + length == right.id.clock,
            deleted == right.deleted,
            redone == nil,
            right.redone == nil,
            content.ref == right.content.ref
        else { return false }

        var merged = content
        guard merged.mergeWith(right.content) else { return false }
        content = merged

        // yjs updates any search marker pointing at the forgotten item. We never
        // create markers (see YType._searchMarker), so this loop never runs — it is
        // kept so the transliteration stays line-comparable with the source.
        if let searchMarker = parentType?._searchMarker {
            for marker in searchMarker where marker.p === right {
                marker.p = self
                if !deleted, countable { marker.index -= length }
            }
        }
        if right.keep { keep = true }
        self.right = right.right
        self.right?.left = self
        length += right.length
        return true
    }

    // MARK: Deletion

    /// yjs `Item.delete` (@9908) — mark deleted, shrink the parent, record the
    /// range on the transaction, and let the content tear down its sub-tree.
    override func delete(_ transaction: YTransaction) {
        guard !deleted else { return }
        // yjs dereferences `parent` unguarded here; it is a resolved type for every
        // item that reached the store, so the optional chain is the same behavior.
        if countable, parentSub == nil {
            parentType?.length -= length
        }
        markDeleted()
        transaction.deleteSet.add(client: id.client, clock: id.clock, length: length)
        if let parentType { transaction.addChangedType(parentType, parentSub: parentSub) }
        content.delete(transaction)
    }
}
