import Foundation

// MARK: - Encoding the live store (Yjs v1)

/// Serializes the live struct store as a Yjs v1 update / state vector — the write
/// side of the `YDoc` facade (B3). Transliterates yjs 13.6.31's
/// `writeStateAsUpdate`/`writeClientsStructs`/`writeStructs` and the structs'
/// `write(encoder, offset)` methods; reuses `YUpdateReencoder`'s delete-set and
/// state-vector writers (offset-free, already fuzz-pinned).
///
/// **Deliberate narrowing vs yjs:** `encodeStateAsUpdate` throws while
/// `pendingStructs`/`pendingDs` are non-nil. yjs folds pending state into the
/// output via `diffUpdateV2` + `mergeUpdates`; Schrift keeps pending as decoded
/// refs (no V2 codec) and the roadmap forbids snapshotting a pending replica
/// anyway (`docs/architecture.md`, "Pending structs and delete sets").
enum YStateEncoder {

    /// yjs `encodeStateAsUpdateV2` (@1907) minus the pending fold-in, over the v1
    /// encoder. `since` is the target state vector: only structs/clocks past it
    /// are written. Empty `since` ⇒ the full snapshot.
    static func encodeStateAsUpdate(_ doc: YDoc, since: [UInt: UInt] = [:]) throws -> Data {
        guard doc.store.pendingStructs == nil, doc.store.pendingDs == nil else {
            throw YIntegrationError.unexpectedCase
        }
        var e = Lib0Encoder()
        try writeClientsStructs(&e, doc.store, since)
        YUpdateReencoder.encodeDeleteSet(&e, deleteBlocks(YDeleteSet.from(store: doc.store)))
        return e.data
    }

    /// yjs `writeStateVector` (@1405) — entries sorted by client, descending.
    static func encodeStateVector(_ doc: YDoc) -> Data {
        let sm = doc.store.getStateVector()
        let entries = sm.keys.sorted(by: >).map { YStateVectorEntry(client: $0, clock: sm[$0]!) }
        return YUpdateReencoder.encodeStateVector(entries)
    }

    // MARK: - Struct blocks

    /// yjs `writeClientsStructs` (@1387): keep `since` entries with new structs,
    /// add store clients absent from `since` at clock 0, then write blocks with
    /// **higher client ids first** ("This heavily improves the conflict
    /// algorithm").
    private static func writeClientsStructs(
        _ e: inout Lib0Encoder, _ store: YStructStore, _ since: [UInt: UInt]
    ) throws {
        var sm: [UInt: UInt] = [:]
        for (client, clock) in since where store.getState(client) > clock {
            sm[client] = clock
        }
        for (client, _) in store.getStateVector() where since[client] == nil {
            sm[client] = 0
        }
        e.writeVarUInt(UInt(sm.count))
        for (client, clock) in sm.sorted(by: { $0.key > $1.key }) {
            // A client in `sm` passed `getState > clock`, so its list exists.
            guard let list = store.clients[client] else { throw YIntegrationError.unexpectedCase }
            try writeStructs(&e, list.structs, client: client, clock: clock)
        }
    }

    /// yjs `writeStructs` (@1360): the first struct is written with an offset so a
    /// diff starts exactly at `clock`; the rest follow whole.
    private static func writeStructs(
        _ e: inout Lib0Encoder, _ structs: [YStruct], client: UInt, clock: UInt
    ) throws {
        // "make sure the first id exists" — unreachable in a settled gc-off store
        // (every client tiles from clock 0), transliterated regardless.
        let clock = max(clock, structs[0].id.clock)
        let start = try YStructStore.findIndexSS(structs, clock)
        e.writeVarUInt(UInt(structs.count - start))
        e.writeVarUInt(client)
        e.writeVarUInt(clock)
        let first = structs[start]
        try write(first, &e, offset: clock - first.id.clock)
        for i in (start + 1)..<structs.count {
            try write(structs[i], &e, offset: 0)
        }
    }

    /// Dispatch to the struct's `write(encoder, offset)` — yjs `GC.write` (@8532),
    /// `Skip.write` (@10285; unreachable from a settled store, kept for parity),
    /// `Item.write` (@10180).
    private static func write(_ s: YStruct, _ e: inout Lib0Encoder, offset: UInt) throws {
        if let item = s as? YItem {
            try writeItem(item, &e, offset: offset)
        } else if s is YGC {
            e.writeUInt8(0)
            e.writeVarUInt(s.length - offset)
        } else if s is YSkip {
            e.writeUInt8(10)
            e.writeVarUInt(s.length - offset)
        } else {
            throw YIntegrationError.unexpectedCase
        }
    }

    /// yjs `Item.write` (@10180). The info byte is **derived** here — never from
    /// `YItem.info`, which holds runtime flags (keep/countable/deleted/marker),
    /// not the wire byte. On `offset > 0` the origin is substituted with the id
    /// of the unit just before the cut — the line that makes diffs work.
    private static func writeItem(_ item: YItem, _ e: inout Lib0Encoder, offset: UInt) throws {
        let origin: YID? =
            offset > 0
            ? YID(client: item.id.client, clock: item.id.clock + offset - 1)
            : item.origin
        let rightOrigin = item.rightOrigin
        let parentSub = item.parentSub
        var info: UInt8 = item.content.ref & 0x1F
        if origin != nil { info |= 0x80 }
        if rightOrigin != nil { info |= 0x40 }
        if parentSub != nil { info |= 0x20 }
        e.writeUInt8(info)
        if let origin {
            e.writeVarUInt(origin.client)
            e.writeVarUInt(origin.clock)
        }
        if let rightOrigin {
            e.writeVarUInt(rightOrigin.client)
            e.writeVarUInt(rightOrigin.clock)
        }
        if origin == nil, rightOrigin == nil {
            switch item.parent {
            case .type(let parent):
                if let parentItem = parent.item {
                    e.writeVarUInt(0)
                    e.writeVarUInt(parentItem.id.client)
                    e.writeVarUInt(parentItem.id.clock)
                } else {
                    // A root type — named in `doc.share`. yjs `findRootTypeKey`.
                    guard let doc = parent.doc else { throw YIntegrationError.unexpectedCase }
                    e.writeVarUInt(1)
                    e.writeVarString(try doc.findRootTypeKey(parent))
                }
            case .id(let id):
                // yjs's "this edge case was added by differential updates".
                e.writeVarUInt(0)
                e.writeVarUInt(id.client)
                e.writeVarUInt(id.clock)
            case nil:
                // An integrated item always has a parent; yjs `error.unexpectedCase()`.
                throw YIntegrationError.unexpectedCase
            }
            if let parentSub { e.writeVarString(parentSub) }
        }
        try writeContent(item.content, &e, offset: offset)
    }

    // MARK: - Content

    /// The per-kind `content.write(encoder, offset)` — yjs ContentDeleted @8688,
    /// ContentJSON @9120, ContentBinary @8800, ContentString @9350 (a raw
    /// `str.slice(offset)`: a lone leading surrogate becomes U+FFFD through the
    /// UTF-8 encoder, which `String(decoding:as: UTF16.self)` matches), ContentEmbed
    /// @8910, ContentFormat @8995, ContentType @9440, ContentAny @9259,
    /// ContentDoc @8590. Internal (not private) so a per-content payload can be
    /// encoded in isolation for testing, not only as part of a whole struct.
    static func writeContent(_ content: YContent, _ e: inout Lib0Encoder, offset: UInt = 0) throws {
        switch content {
        case .deleted(let len):
            guard offset <= len else { throw YIntegrationError.unexpectedCase }
            e.writeVarUInt(len - offset)
        case .json(let items):
            guard let o = Int(exactly: offset), o <= items.count else {
                throw YIntegrationError.unexpectedCase
            }
            e.writeVarUInt(UInt(items.count - o))
            for item in items[o...] { e.writeVarString(item) }
        case .binary(let data):
            e.writeVarUint8Array(data)
        case .string(let units):
            guard let o = Int(exactly: offset), o <= units.count else {
                throw YIntegrationError.unexpectedCase
            }
            e.writeVarString(String(decoding: units[o...], as: UTF16.self))
        case .embed(let json):
            e.writeVarString(json)
        case .format(let key, let valueJSON):
            e.writeVarString(key)
            e.writeVarString(valueJSON)
        case .type(let type):
            switch type.typeRef {
            case .array: e.writeVarUInt(0)
            case .map: e.writeVarUInt(1)
            case .text: e.writeVarUInt(2)
            case .xmlElement(let nodeName):
                e.writeVarUInt(3)
                e.writeVarString(nodeName)
            case .xmlFragment: e.writeVarUInt(4)
            case .xmlHook(let key):
                e.writeVarUInt(5)
                e.writeVarString(key)
            case .xmlText: e.writeVarUInt(6)
            case nil:
                // Only roots lack a typeRef, and a root never sits inside ContentType.
                throw YIntegrationError.unexpectedCase
            }
        case .any(let values):
            guard let o = Int(exactly: offset), o <= values.count else {
                throw YIntegrationError.unexpectedCase
            }
            e.writeVarUInt(UInt(values.count - o))
            for value in values[o...] { e.writeAny(value) }
        case .doc(let guid, let options):
            e.writeVarString(guid)
            e.writeAny(options)
        }
    }

    // MARK: - Delete set

    /// yjs `writeDeleteSet` (@285) client order: **descending**. Do not confuse
    /// with the ingest-side ascending `asBlocks()` in `YStructIntegration.swift` —
    /// the difference is silent until a two-client comparison.
    static func deleteBlocks(_ ds: YDeleteSet) -> [YDeleteBlock] {
        ds.clients.keys.sorted(by: >).map { client in
            YDeleteBlock(
                client: client,
                ranges: ds.clients[client]!.map { YDeleteRange(clock: $0.clock, length: $0.len) })
        }
    }
}
