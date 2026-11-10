import Foundation

// MARK: - Relative position

/// A position in a shared type that survives concurrent edits — yjs
/// `RelativePosition` (@2301).
///
/// A plain index is only meaningful against one snapshot: a peer inserting before
/// it shifts it, and a peer deleting the character it names destroys it. A
/// relative position instead names the *type* (by its defining item id, or by its
/// root `share` key) plus the id of one character/element, so it can be resolved
/// against any later state of the same document. That is what keeps a caret or a
/// selection stable across local and remote edits.
///
/// `assoc` decides which side of the named character the position sits on:
/// `>= 0` associates with the character *after* the meant position (position 1 in
/// `"ab"` is `b`), `< 0` with the character *before* it. The distinction is
/// load-bearing at the end of a paragraph — see
/// `createRelativePositionFromTypeIndex` and `resolve(in:)`.
///
/// The value and its codecs are pure value code: no concurrency annotations,
/// callable from any isolation domain. **`resolve(in:)` is not** — it reads the
/// live document graph (and, for an unknown `tname`, mutates `doc.share`), so it
/// runs on the replica's owner like every other doc access.
struct YRelativePosition: Equatable, Sendable {
    /// The defining item id of a **nested** type (the item whose `ContentType`
    /// holds it), or nil when the type is a root.
    var type: YID?
    /// The root type's `share` key, or nil when the type is nested.
    var tname: String?
    /// The id of the character/element this position is associated with, or nil
    /// for "the end of the type" (yjs's case 2/3 encodings).
    var item: YID?
    /// `>= 0` associates with the character after the position, `< 0` with the
    /// character before it.
    var assoc: Int

    init(type: YID? = nil, tname: String? = nil, item: YID? = nil, assoc: Int = 0) {
        self.type = type
        self.tname = tname
        self.item = item
        self.assoc = assoc
    }
}

/// A resolved position — yjs `AbsolutePosition` (@2365).
///
/// `index` is a visible (undeleted, countable) index into `type`, in the same
/// units as `YType.length` (UTF-16 code units for text, children for a list).
struct YAbsolutePosition {
    let type: YType
    let index: UInt
    let assoc: Int
}

// MARK: - Creating from an absolute index

extension YRelativePosition {
    /// Capture the position at visible index `index` of `type` — yjs
    /// `createRelativePositionFromTypeIndex` (@2421).
    ///
    /// The walk is yjs's, including its two end-of-list rules:
    ///
    /// - `assoc < 0` at index 0 has no left character, so it returns the
    ///   "beginning of the type" position (`item == nil`, resolved to index 0).
    /// - `assoc < 0` that runs off the end returns the **last available id**
    ///   (`t.lastId`), not the end-of-type position — so a left-associated
    ///   position at `index == length` stays *before* text a peer later appends.
    ///   The `assoc >= 0` counterpart returns `item == nil`, which resolves to
    ///   `type.length` and therefore *follows* the appended text. That asymmetry
    ///   is the C2 end-of-paragraph fix; `YRelativePositionTests` pins it.
    ///
    /// `index` is `UInt` because it is a visible index (`YType.length` is `UInt`);
    /// an index past the end is not an error. For `assoc >= 0` the walk falls
    /// through to the end-of-type position; for `assoc < 0` it returns the last
    /// available id (`t.lastId`), the same rule as `index == length`.
    static func fromTypeIndex(_ type: YType, index: UInt, assoc: Int = 0) throws -> YRelativePosition {
        var t = type.start
        var index = index
        if assoc < 0 {
            // Associated to the left character or the beginning of a type;
            // increment the index if possible.
            if index == 0 {
                return try create(type, nil, assoc)
            }
            index -= 1
        }
        while let current = t {
            if !current.deleted && current.countable {
                if current.length > index {
                    // Case 1: found the position somewhere in the linked list.
                    return try create(
                        type, YID(client: current.id.client, clock: current.id.clock + index), assoc)
                }
                index -= current.length
            }
            if current.right == nil && assoc < 0 {
                // Left-associated position: return the last available id.
                return try create(type, current.lastId, assoc)
            }
            t = current.right
        }
        return try create(type, nil, assoc)
    }

    /// yjs `createRelativePosition` (@2400) — name the type by its defining item
    /// id when nested, or by its root `share` key when it is a root.
    ///
    /// yjs reads `type.doc.share` directly and would throw a `TypeError` on a
    /// detached type; a `YType` with no doc is the same unreachable state here, so
    /// it throws `unexpectedCase` instead of trapping.
    private static func create(_ type: YType, _ item: YID?, _ assoc: Int) throws -> YRelativePosition {
        if let typeItem = type.item {
            return YRelativePosition(
                type: YID(client: typeItem.id.client, clock: typeItem.id.clock),
                tname: nil, item: item, assoc: assoc)
        }
        guard let doc = type.doc else { throw YIntegrationError.unexpectedCase }
        return YRelativePosition(type: nil, tname: try doc.findRootTypeKey(type), item: item, assoc: assoc)
    }
}

// MARK: - Resolving against a document

extension YRelativePosition {
    /// Resolve this position against `doc` — yjs
    /// `createAbsolutePositionFromRelativePosition` (@2547).
    ///
    /// Returns nil exactly where yjs does: the named item's clock is past the
    /// client's state (the item has not arrived), the item resolved to a `GC`
    /// struct, or the named type's defining item is not a `ContentType` (a
    /// collected type). A **root `tname` that does not exist is not nil**: yjs
    /// calls `doc.get(tname)`, which creates the empty root, so the position
    /// resolves to index 0 of a fresh type. Mirrored deliberately.
    ///
    /// `followUndoneDeletions` is yjs's parameter of the same name
    /// (yjs/yjs#638): `YUndoManager`'s `redoItem` sets `YItem.redone`, and
    /// `YStructStore.followRedone` follows it to the content an undo re-created.
    ///
    /// Three things a caller must know:
    ///
    /// - **An unknown `tname` creates that root permanently.** yjs's `doc.get`
    ///   inserts it into `doc.share`, and this mirrors that. A caller fed by peers
    ///   (awareness cursors) must not let `share` grow unbounded: only resolve a
    ///   `tname` that already exists, or one of the names the schema owns
    ///   (BlockNote's `document-store`).
    /// - **A throw means a malformed position, not a corrupt replica.** The only
    ///   throws are an all-nil position (an unknown decode tag, or `{}` JSON) and
    ///   an item whose parent is still an unresolved id — both impossible for a
    ///   position this core produced. A caller must drop that cursor and must
    ///   **never** latch `replicaFailSafe` for it.
    /// - **It reads (and can mutate) the live document**, so it runs on the
    ///   replica's owner like every other doc access — not from an arbitrary
    ///   isolation domain.
    func resolve(in doc: YDoc, followUndoneDeletions: Bool = true) throws -> YAbsolutePosition? {
        let store = doc.store
        if let rightID = item {
            if store.getState(rightID.client) <= rightID.clock {
                return nil
            }
            let res =
                followUndoneDeletions
                ? try YStructStore.followRedone(store, rightID)
                : try Self.getItemWithOffset(store, rightID)
            guard let right = res.item as? YItem else {
                // Struct is garbage collected.
                return nil
            }
            // yjs reads `right.parent` as an `AbstractType`; an item in the store
            // always has one (`getMissing` resolves the id before integration), so
            // the unresolved case is unreachable — yjs would throw a `TypeError`
            // there, and `unexpectedCase` is the catchable equivalent.
            guard let type = right.parentType else { throw YIntegrationError.unexpectedCase }
            var index: UInt = 0
            if type.item == nil || !(type.item?.deleted ?? false) {
                // Adjust the position based on left association if necessary.
                index = (right.deleted || !right.countable) ? 0 : res.diff + (assoc >= 0 ? 0 : 1)
                var n = right.left
                while let current = n {
                    if !current.deleted && current.countable {
                        index += current.length
                    }
                    n = current.left
                }
            }
            return YAbsolutePosition(type: type, index: index, assoc: assoc)
        }
        if let tname {
            let type = doc.get(tname)
            return YAbsolutePosition(type: type, index: assoc >= 0 ? type.length : 0, assoc: assoc)
        }
        if let typeID = type {
            if store.getState(typeID.client) <= typeID.clock {
                // Type does not exist yet.
                return nil
            }
            let res =
                followUndoneDeletions
                ? try YStructStore.followRedone(store, typeID)
                : try Self.getItemWithOffset(store, typeID)
            guard let item = res.item as? YItem, case .type(let type) = item.content else {
                // Struct is garbage collected.
                return nil
            }
            return YAbsolutePosition(type: type, index: assoc >= 0 ? type.length : 0, assoc: assoc)
        }
        throw YIntegrationError.unexpectedCase
    }

    /// yjs `getItemWithOffset` (@2521) — the struct containing `id`, plus how far
    /// into it `id` sits.
    private static func getItemWithOffset(
        _ store: YStructStore, _ id: YID
    ) throws -> (item: YStruct, diff: UInt) {
        let item = try store.getItem(id)
        return (item, id.clock - item.id.clock)
    }
}

// MARK: - Binary codec

extension YRelativePosition {
    /// yjs `encodeRelativePosition` (@2477).
    func encode() throws -> Data {
        var encoder = Lib0Encoder()
        try write(to: &encoder)
        return encoder.data
    }

    /// yjs `writeRelativePosition` (@2453).
    ///
    /// The three cases are yjs's: an item id (case 1), a root `tname` (case 2), or
    /// a nested type id (case 3). A position with none of them is yjs's
    /// `unexpectedCase` — reachable only from a hand-built value or an unknown
    /// decode tag, never from `fromTypeIndex`.
    func write(to encoder: inout Lib0Encoder) throws {
        if let item {
            encoder.writeVarUInt(0)
            writeID(&encoder, item)
        } else if let tname {
            // Case 2: found the position at the end of the list and the type is
            // stored in `y.share`.
            encoder.writeUInt8(1)
            encoder.writeVarString(tname)
        } else if let type {
            // Case 3: found the position at the end of the list and the type is
            // attached to an item.
            encoder.writeUInt8(2)
            writeID(&encoder, type)
        } else {
            throw YIntegrationError.unexpectedCase
        }
        encoder.writeVarInt(assoc)
    }

    /// yjs `decodeRelativePosition` (@2515).
    ///
    /// Like yjs, this does **not** require the buffer to be fully consumed: any
    /// trailing bytes are ignored. Being stricter here would reject bytes yjs
    /// accepts.
    static func decode(_ data: Data) throws -> YRelativePosition {
        var decoder = Lib0Decoder(data)
        return try read(from: &decoder)
    }

    /// yjs `readRelativePosition` (@2489).
    ///
    /// An **unknown kind tag is not an error**: yjs's `switch` has no `default`,
    /// so every field stays null and the assoc read still runs. The result is an
    /// unresolvable position (`resolve` throws `unexpectedCase`, `encode` throws
    /// too) — mirrored exactly rather than rejected at the decoder, because yjs
    /// accepts those bytes.
    static func read(from decoder: inout Lib0Decoder) throws -> YRelativePosition {
        var type: YID?
        var tname: String?
        var item: YID?
        switch try decoder.readVarUInt() {
        case 0:
            // Case 1: found the position somewhere in the linked list.
            item = try readID(&decoder)
        case 1:
            // Case 2: found the position at the end of the list and the type is
            // stored in `y.share`.
            tname = try decoder.readVarString()
        case 2:
            // Case 3: found the position at the end of the list and the type is
            // attached to an item.
            type = try readID(&decoder)
        default:
            break
        }
        let assoc = decoder.hasMoreData ? try decoder.readVarInt() : 0
        return YRelativePosition(type: type, tname: tname, item: item, assoc: assoc)
    }
}

/// yjs `writeID` (@2070).
private func writeID(_ encoder: inout Lib0Encoder, _ id: YID) {
    encoder.writeVarUInt(id.client)
    encoder.writeVarUInt(id.clock)
}

/// yjs `readID` (@2086).
private func readID(_ decoder: inout Lib0Decoder) throws -> YID {
    let client = try decoder.readVarUInt()
    let clock = try decoder.readVarUInt()
    return YID(client: client, clock: clock)
}

// MARK: - JSON

/// The JSON shape of a relative position — yjs `relativePositionToJSON` (@2340)
/// and `createRelativePositionFromJSON` (@2363).
///
/// A separate type from `YRelativePosition` because the JSON shape is *lossier*
/// than the value: yjs omits a falsy `tname` (so `""` becomes absent) and
/// tolerates a missing `assoc` (defaulting to 0). Keeping the two apart makes
/// those two reductions explicit instead of hiding them in a `Codable`
/// conformance on the value type.
///
/// One deliberate narrowing: an id outside `UInt` (a negative `client`/`clock`, or
/// one ≥ 2^64) throws a `DecodingError` here, where yjs would build the id and
/// then resolve the position to null. Failing at decode is the fail-safe choice —
/// the cursor is dropped either way, and no out-of-range clock reaches the store.
struct YRelativePositionJSON: Equatable, Codable, Sendable {
    var type: YID?
    var tname: String?
    var item: YID?
    /// Optional so a JSON object that omits it decodes, as yjs's
    /// `json.assoc == null ? 0 : json.assoc` allows. `relativePositionToJSON`
    /// always writes it.
    var assoc: Int?
}

extension YRelativePosition {
    /// yjs `relativePositionToJSON` (@2340).
    ///
    /// yjs guards each field with a truthiness test, so an **empty `tname` is
    /// omitted** (and therefore reads back as nil). Mirrored.
    var json: YRelativePositionJSON {
        YRelativePositionJSON(
            type: type,
            tname: tname.flatMap { $0.isEmpty ? nil : $0 },
            item: item,
            assoc: assoc)
    }

    /// yjs `createRelativePositionFromJSON` (@2363).
    init(json: YRelativePositionJSON) {
        self.init(type: json.type, tname: json.tname, item: json.item, assoc: json.assoc ?? 0)
    }
}

// MARK: - Comparison

extension YRelativePosition {
    /// yjs `compareRelativePositions` (@2609).
    ///
    /// yjs's `a === b` short-circuit is reference identity; for value types the
    /// field comparison below already covers it (two equal values compare equal).
    static func compare(_ a: YRelativePosition?, _ b: YRelativePosition?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            return true
        case (let a?, let b?):
            return a.tname == b.tname && a.item == b.item && a.type == b.type && a.assoc == b.assoc
        default:
            return false
        }
    }
}
