import Foundation

// MARK: - Yjs v1 update wire model (read side)

/// Errors from decoding a Yjs v1 update / state vector.
enum YWireError: Error, Equatable {
    case unsupportedContentRef(UInt8)
    case unsupportedTypeRef(UInt)
    /// A client block's clocks ran past `UInt.max`. Only reachable from malformed
    /// input — lib0 refuses to read a clock that large in the first place — but the
    /// arithmetic would trap rather than throw, so it is checked explicitly.
    case clockOutOfRange
}

/// A Yjs struct identity: `(clientID, clock)`. The clock is the position of the
/// struct's first unit in that client's monotonic sequence.
struct YID: Equatable, Hashable, Sendable {
    var client: UInt
    var clock: UInt
}

/// The parent an item names when it can't copy one from an origin — i.e. when
/// both origin bits in the info byte are clear (the item is the first child of
/// its parent, in that direction).
enum YParentRef: Equatable, Sendable {
    /// A named root type (`readParentInfo() == 1`, then a var string).
    case named(String)
    /// A nested type's defining item id (`readParentInfo() == 0`, then an id).
    case id(YID)
}

/// The type a `ContentType` (content ref 7) instantiates — the yjs type refs.
enum YTypeRef: Equatable, Sendable {
    case array  // 0
    case map  // 1
    case text  // 2
    case xmlElement(nodeName: String)  // 3
    case xmlFragment  // 4
    case xmlHook(key: String)  // 5
    case xmlText  // 6
}

/// An item's content payload — yjs content refs 1–9. Content that is really JSON
/// text on the wire (embed/format value/doc) is kept as its **raw var-string**,
/// re-emitted verbatim, so a round-trip never hinges on JSON canonicalization.
enum YContentRecord: Equatable, Sendable {
    case deleted(length: UInt)  // 1  ContentDeleted
    case json([String])  // 2  ContentJSON — raw per-item strings ("undefined" kept literal)
    case binary(Data)  // 3  ContentBinary
    case string(String)  // 4  ContentString
    case embed(json: String)  // 5  ContentEmbed — raw JSON text
    case format(key: String, valueJSON: String)  // 6  ContentFormat — raw JSON value text
    case type(YTypeRef)  // 7  ContentType
    case any([YAnyValue])  // 8  ContentAny
    case doc(guid: String, options: YAnyValue)  // 9  ContentDoc

    /// Content ref id (low 5 bits of the info byte).
    var ref: UInt8 {
        switch self {
        case .deleted: return 1
        case .json: return 2
        case .binary: return 3
        case .string: return 4
        case .embed: return 5
        case .format: return 6
        case .type: return 7
        case .any: return 8
        case .doc: return 9
        }
    }

    /// Logical length — how far this content advances the clock. Strings count
    /// UTF-16 code units (JS `String.length`); list contents count their items;
    /// everything else is a single unit.
    var length: UInt {
        switch self {
        case .deleted(let length): return length
        case .string(let s): return UInt(s.utf16.count)
        case .json(let items): return UInt(items.count)
        case .any(let values): return UInt(values.count)
        case .binary, .embed, .format, .type, .doc: return 1
        }
    }
}

/// One decoded item. `info` is the **raw** info byte, kept so a re-encode is
/// byte-identical: yjs sets the parentSub bit (`0x20`) even on an item that
/// inherits its parent from an origin (an overwritten map key), where the
/// parentSub string is *not* on the wire — so the bit can't be reconstructed
/// from the fields, only replayed. The conditional fields below are read/written
/// under the same info-bit tests, so replaying `info` plus the fields is exact.
struct YItemRecord: Equatable, Sendable {
    var id: YID
    var info: UInt8
    var origin: YID?  // present iff info & 0x80 (left origin)
    var rightOrigin: YID?  // present iff info & 0x40
    var parent: YParentRef?  // present iff both origin bits clear
    var parentSub: String?  // present iff (both origin bits clear) && info & 0x20
    var content: YContentRecord
}

/// A decoded struct: an item, or one of the two content-less structs.
enum YStructRecord: Equatable, Sendable {
    case item(YItemRecord)
    case gc(id: YID, length: UInt)  // content ref 0
    case skip(id: YID, length: UInt)  // content ref 10

    /// How far this struct advances the client's clock.
    var length: UInt {
        switch self {
        case .item(let item): return item.content.length
        case .gc(_, let length), .skip(_, let length): return length
        }
    }
}

/// One client's run of structs in the update, in wire order.
struct YClientBlock: Equatable, Sendable {
    var client: UInt
    var structs: [YStructRecord]
}

/// A contiguous deleted range within one client's sequence.
struct YDeleteRange: Equatable, Sendable {
    var clock: UInt
    var length: UInt
}

/// One client's delete ranges, in wire order.
struct YDeleteBlock: Equatable, Sendable {
    var client: UInt
    var ranges: [YDeleteRange]
}

/// A decoded Yjs v1 update: the client struct blocks followed by the delete set.
struct YUpdate: Equatable, Sendable {
    var blocks: [YClientBlock]
    var deleteSet: [YDeleteBlock]
}

/// One `(client, clock)` entry of a state vector.
struct YStateVectorEntry: Equatable, Sendable {
    var client: UInt
    var clock: UInt
}

// MARK: - Decoding

/// Decodes a Yjs v1 update (`Y.encodeStateAsUpdate` output) into `YUpdate`. A
/// faithful transliteration of yjs `readClientsStructRefs` + `readDeleteSet`
/// (UpdateDecoderV1); this milestone decodes and re-encodes only — it does not
/// integrate structs into a document (that is the YATA store, a later PR).
enum YUpdateDecoder {
    /// The full update: struct blocks then the delete set, from one buffer.
    static func decode(_ data: Data) throws -> YUpdate {
        var d = Lib0Decoder(data)
        let blocks = try decodeStructs(&d)
        let deleteSet = try decodeDeleteSet(&d)
        return YUpdate(blocks: blocks, deleteSet: deleteSet)
    }

    static func decodeStructs(_ d: inout Lib0Decoder) throws -> [YClientBlock] {
        let numClients = try d.readVarUInt()
        var blocks: [YClientBlock] = []
        blocks.reserveCapacity(min(Int(exactly: numClients) ?? 0, d.remainingCount))
        for _ in 0..<numClients {
            let numStructs = try d.readVarUInt()
            let client = try d.readVarUInt()
            var clock = try d.readVarUInt()
            var structs: [YStructRecord] = []
            structs.reserveCapacity(min(Int(exactly: numStructs) ?? 0, d.remainingCount))
            for _ in 0..<numStructs {
                let s = try decodeStruct(&d, client: client, clock: clock)
                // A block's clocks come off the wire unbounded, so a malformed update
                // can run this past `UInt.max` — a *trap*, i.e. a remote crash, on
                // bytes any peer can send. lib0 rejects the same input while reading
                // (`readVarUint` throws `errorIntegerOutOfRange` past 2^53-1), so
                // throwing here reaches the same outcome: the update is refused.
                let (next, overflowed) = clock.addingReportingOverflow(s.length)
                guard !overflowed else { throw YWireError.clockOutOfRange }
                clock = next
                structs.append(s)
            }
            blocks.append(YClientBlock(client: client, structs: structs))
        }
        return blocks
    }

    private static func decodeStruct(_ d: inout Lib0Decoder, client: UInt, clock: UInt) throws -> YStructRecord {
        let info = try d.readUInt8()
        let id = YID(client: client, clock: clock)
        switch info & 0x1F {  // BITS5 — the content ref
        case 0:
            return .gc(id: id, length: try d.readVarUInt())
        case 10:
            return .skip(id: id, length: try d.readVarUInt())
        default:
            let origin = (info & 0x80) != 0 ? try decodeID(&d) : nil
            let rightOrigin = (info & 0x40) != 0 ? try decodeID(&d) : nil
            var parent: YParentRef?
            var parentSub: String?
            // Parent is on the wire only when neither origin is (else it's copied).
            if (info & 0xC0) == 0 {
                parent = try d.readVarUInt() == 1 ? .named(try d.readVarString()) : .id(try decodeID(&d))
                if (info & 0x20) != 0 { parentSub = try d.readVarString() }
            }
            let content = try decodeContent(&d, ref: info & 0x1F)
            return .item(
                YItemRecord(
                    id: id, info: info, origin: origin, rightOrigin: rightOrigin,
                    parent: parent, parentSub: parentSub, content: content))
        }
    }

    private static func decodeID(_ d: inout Lib0Decoder) throws -> YID {
        YID(client: try d.readVarUInt(), clock: try d.readVarUInt())
    }

    private static func decodeContent(_ d: inout Lib0Decoder, ref: UInt8) throws -> YContentRecord {
        switch ref {
        case 1:
            return .deleted(length: try d.readVarUInt())
        case 2:
            let count = try d.readVarUInt()
            var items: [String] = []
            items.reserveCapacity(min(Int(exactly: count) ?? 0, d.remainingCount))
            for _ in 0..<count { items.append(try d.readVarString()) }
            return .json(items)
        case 3:
            return .binary(try d.readVarUint8Array())
        case 4:
            return .string(try d.readVarString())
        case 5:
            return .embed(json: try d.readVarString())
        case 6:
            return .format(key: try d.readVarString(), valueJSON: try d.readVarString())
        case 7:
            return .type(try decodeTypeRef(&d))
        case 8:
            let count = try d.readVarUInt()
            var values: [YAnyValue] = []
            values.reserveCapacity(min(Int(exactly: count) ?? 0, d.remainingCount))
            for _ in 0..<count { values.append(try d.readAny()) }
            return .any(values)
        case 9:
            return .doc(guid: try d.readVarString(), options: try d.readAny())
        default:
            throw YWireError.unsupportedContentRef(ref)
        }
    }

    private static func decodeTypeRef(_ d: inout Lib0Decoder) throws -> YTypeRef {
        let typeRef = try d.readVarUInt()
        switch typeRef {
        case 0: return .array
        case 1: return .map
        case 2: return .text
        case 3: return .xmlElement(nodeName: try d.readVarString())
        case 4: return .xmlFragment
        case 5: return .xmlHook(key: try d.readVarString())
        case 6: return .xmlText
        default: throw YWireError.unsupportedTypeRef(typeRef)
        }
    }

    static func decodeDeleteSet(_ d: inout Lib0Decoder) throws -> [YDeleteBlock] {
        let numClients = try d.readVarUInt()
        var blocks: [YDeleteBlock] = []
        blocks.reserveCapacity(min(Int(exactly: numClients) ?? 0, d.remainingCount))
        for _ in 0..<numClients {
            let client = try d.readVarUInt()
            let numRanges = try d.readVarUInt()
            var ranges: [YDeleteRange] = []
            ranges.reserveCapacity(min(Int(exactly: numRanges) ?? 0, d.remainingCount))
            for _ in 0..<numRanges {
                ranges.append(YDeleteRange(clock: try d.readVarUInt(), length: try d.readVarUInt()))
            }
            blocks.append(YDeleteBlock(client: client, ranges: ranges))
        }
        return blocks
    }

    /// Decodes a state vector (`Y.encodeStateVector` output) — just
    /// `varUint(count)` then `count × (varUint client, varUint clock)`.
    static func decodeStateVector(_ data: Data) throws -> [YStateVectorEntry] {
        var d = Lib0Decoder(data)
        let count = try d.readVarUInt()
        var entries: [YStateVectorEntry] = []
        entries.reserveCapacity(min(Int(exactly: count) ?? 0, d.remainingCount))
        for _ in 0..<count {
            entries.append(YStateVectorEntry(client: try d.readVarUInt(), clock: try d.readVarUInt()))
        }
        return entries
    }
}

// MARK: - Re-encoding (identity round-trip)

/// Re-encodes a decoded `YUpdate` back to bytes. For any update yjs produced, the
/// output is **byte-identical** to the input — the property `YUpdateDecoderTests`
/// pins against the oracle. This is the write side the CRDT store will reuse once
/// it can build a `YUpdate` from an integrated document.
enum YUpdateReencoder {
    static func encode(_ update: YUpdate) -> Data {
        var e = Lib0Encoder()
        encodeStructs(&e, update.blocks)
        encodeDeleteSet(&e, update.deleteSet)
        return e.data
    }

    static func encodeStructs(_ e: inout Lib0Encoder, _ blocks: [YClientBlock]) {
        e.writeVarUInt(UInt(blocks.count))
        for block in blocks {
            e.writeVarUInt(UInt(block.structs.count))
            e.writeVarUInt(block.client)
            e.writeVarUInt(block.structs.first?.clock ?? 0)
            for s in block.structs { encodeStruct(&e, s) }
        }
    }

    private static func encodeStruct(_ e: inout Lib0Encoder, _ s: YStructRecord) {
        switch s {
        case .gc(_, let length):
            e.writeUInt8(0)
            e.writeVarUInt(length)
        case .skip(_, let length):
            e.writeUInt8(10)
            e.writeVarUInt(length)
        case .item(let item):
            e.writeUInt8(item.info)  // replayed verbatim — see YItemRecord.info
            if let origin = item.origin { encodeID(&e, origin) }
            if let rightOrigin = item.rightOrigin { encodeID(&e, rightOrigin) }
            if (item.info & 0xC0) == 0 {
                switch item.parent {
                case .named(let key):
                    e.writeVarUInt(1)
                    e.writeVarString(key)
                case .id(let id):
                    e.writeVarUInt(0)
                    encodeID(&e, id)
                case nil:
                    break  // an item with no origins always carries a parent
                }
                if (item.info & 0x20) != 0, let sub = item.parentSub { e.writeVarString(sub) }
            }
            encodeContent(&e, item.content)
        }
    }

    private static func encodeID(_ e: inout Lib0Encoder, _ id: YID) {
        e.writeVarUInt(id.client)
        e.writeVarUInt(id.clock)
    }

    private static func encodeContent(_ e: inout Lib0Encoder, _ content: YContentRecord) {
        switch content {
        case .deleted(let length):
            e.writeVarUInt(length)
        case .json(let items):
            e.writeVarUInt(UInt(items.count))
            for item in items { e.writeVarString(item) }
        case .binary(let data):
            e.writeVarUint8Array(data)
        case .string(let s):
            e.writeVarString(s)
        case .embed(let json):
            e.writeVarString(json)
        case .format(let key, let valueJSON):
            e.writeVarString(key)
            e.writeVarString(valueJSON)
        case .type(let typeRef):
            encodeTypeRef(&e, typeRef)
        case .any(let values):
            e.writeVarUInt(UInt(values.count))
            for value in values { e.writeAny(value) }
        case .doc(let guid, let options):
            e.writeVarString(guid)
            e.writeAny(options)
        }
    }

    private static func encodeTypeRef(_ e: inout Lib0Encoder, _ typeRef: YTypeRef) {
        switch typeRef {
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
        }
    }

    static func encodeDeleteSet(_ e: inout Lib0Encoder, _ blocks: [YDeleteBlock]) {
        e.writeVarUInt(UInt(blocks.count))
        for block in blocks {
            e.writeVarUInt(block.client)
            e.writeVarUInt(UInt(block.ranges.count))
            for range in block.ranges {
                e.writeVarUInt(range.clock)
                e.writeVarUInt(range.length)
            }
        }
    }

    /// Re-encodes a state vector (identity round-trip of `decodeStateVector`).
    static func encodeStateVector(_ entries: [YStateVectorEntry]) -> Data {
        var e = Lib0Encoder()
        e.writeVarUInt(UInt(entries.count))
        for entry in entries {
            e.writeVarUInt(entry.client)
            e.writeVarUInt(entry.clock)
        }
        return e.data
    }
}

extension YStructRecord {
    /// The struct's clock (its id's clock), used to write the block's first clock.
    fileprivate var clock: UInt {
        switch self {
        case .item(let item): return item.id.clock
        case .gc(let id, _), .skip(let id, _): return id.clock
        }
    }
}
