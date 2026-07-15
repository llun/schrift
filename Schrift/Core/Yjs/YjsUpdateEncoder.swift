import Foundation

// MARK: - lib0 variable-length encoding primitives (yjs UpdateEncoderV1 wire format)

/// Byte buffer implementing the subset of lib0's binary encoding that yjs uses
/// for v1 document updates. See github.com/dmonad/lib0 `encoding.js`.
struct Lib0Encoder {
    private(set) var data = Data()

    mutating func writeUInt8(_ byte: UInt8) { data.append(byte) }

    /// Unsigned LEB128.
    mutating func writeVarUInt(_ value: UInt) {
        var v = value
        while v > 0x7F {
            data.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        data.append(UInt8(v & 0x7F))
    }

    /// lib0 signed varint: first byte carries the sign in bit 0x40 and the
    /// continuation flag in bit 0x80, leaving 6 low value bits; further bytes
    /// are 7-bit groups with a 0x80 continuation flag.
    mutating func writeVarInt(_ value: Int) {
        var num = value.magnitude
        let sign: UInt8 = value < 0 ? 0x40 : 0
        var first = UInt8(num & 0x3F) | sign
        num >>= 6
        if num > 0 { first |= 0x80 }
        data.append(first)
        while num > 0 {
            var byte = UInt8(num & 0x7F)
            num >>= 7
            if num > 0 { byte |= 0x80 }
            data.append(byte)
        }
    }

    /// varUint(utf8 byte length) followed by the UTF-8 bytes.
    mutating func writeVarString(_ string: String) {
        let bytes = Array(string.utf8)
        writeVarUInt(UInt(bytes.count))
        data.append(contentsOf: bytes)
    }

    /// varUint(byte count) followed by the raw bytes. lib0's
    /// `writeVarUint8Array`, used to length-prefix Yjs sync updates, state
    /// vectors, and awareness payloads inside a Hocuspocus frame. Additive: the
    /// document-update path never calls it, so the golden encoder bytes are
    /// unchanged.
    mutating func writeVarUint8Array(_ bytes: Data) {
        writeVarUInt(UInt(bytes.count))
        data.append(bytes)
    }
}

// MARK: - Yjs struct model (a single-client, from-scratch document update)

/// A JSON-representable attribute value stored inside a `ContentAny`.
enum YAnyValue: Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case null
    /// JS `undefined`, distinct from `null` on the wire (lib0 `writeAny` emits
    /// 127 for undefined, 126 for null). BlockNote serializes an unset optional
    /// prop — e.g. the image block's `previewWidth` — as `undefined`, so a
    /// byte-exact image block needs this case.
    case undefined
}

/// The content payload of a Yjs `Item`. Only the variants a from-scratch
/// BlockNote document needs are modelled.
enum YContent: Equatable {
    case xmlElement(nodeName: String)
    case xmlText
    case string(String)
    /// A formatting mark. `valueJSON` is the JSON encoding of the mark value —
    /// `"{}"` to open a boolean mark, `"null"` to close it, or e.g.
    /// `#"{"href":"…"}"#` for a link.
    case format(key: String, valueJSON: String)
    case any([YAnyValue])

    /// Number of logical positions this content occupies (advances the clock).
    /// Strings count UTF-16 code units, matching JS `String.length`.
    var length: Int {
        switch self {
        case .string(let s): return s.utf16.count
        default: return 1
        }
    }

    /// yjs content ref id used in the low 5 bits of an item's info byte.
    var ref: UInt8 {
        switch self {
        case .string: return 4  // ContentString
        case .format: return 6  // ContentFormat
        case .xmlElement, .xmlText: return 7  // ContentType
        case .any: return 8  // ContentAny
        }
    }
}

/// One Yjs `Item`. Every item in a from-scratch document is authored by the
/// same client, so IDs are `(clientID, clock)` and `origin` is just a clock.
struct YItem: Equatable {
    var clock: Int
    /// Clock of the left origin item (same client), or nil when this item is the
    /// first child of its parent.
    var origin: Int?
    /// Set when the parent is a named root type (e.g. "document-store").
    var parentRootKey: String?
    /// Clock of the parent item when the parent is a nested type.
    var parentClock: Int?
    /// Map key when this item is an attribute/map entry.
    var parentSub: String?
    var content: YContent
}

// MARK: - Update serialization

enum YjsUpdateEncoder {
    /// Serializes a from-scratch document (single client, empty delete set) into
    /// a Yjs v1 update — the exact bytes `Y.encodeStateAsUpdate` produces.
    static func encode(clientID: UInt32, items: [YItem]) -> Data {
        var e = Lib0Encoder()
        e.writeVarUInt(1)  // number of clients
        e.writeVarUInt(UInt(items.count))  // structs for this client
        e.writeVarUInt(UInt(clientID))  // client id
        e.writeVarUInt(UInt(items.first?.clock ?? 0))  // clock of first struct
        for item in items { writeItem(&e, clientID: clientID, item) }
        e.writeVarUInt(0)  // delete set: 0 clients
        return e.data
    }

    private static func writeItem(_ e: inout Lib0Encoder, clientID: UInt32, _ item: YItem) {
        let hasOrigin = item.origin != nil
        var info = item.content.ref
        if hasOrigin { info |= 0x80 }  // BIT8: has left origin
        if item.parentSub != nil { info |= 0x20 }  // BIT6: has parentSub
        e.writeUInt8(info)

        if let origin = item.origin {
            e.writeVarUInt(UInt(clientID))  // writeID(origin)
            e.writeVarUInt(UInt(origin))
        }
        // Parent info is written only when neither origin nor rightOrigin exist.
        if !hasOrigin {
            if let root = item.parentRootKey {
                e.writeVarUInt(1)  // parent is a root type
                e.writeVarString(root)
            } else {
                e.writeVarUInt(0)  // parent is a nested item
                e.writeVarUInt(UInt(clientID))
                e.writeVarUInt(UInt(item.parentClock ?? 0))
            }
            if let sub = item.parentSub { e.writeVarString(sub) }
        }
        writeContent(&e, item.content)
    }

    private static func writeContent(_ e: inout Lib0Encoder, _ content: YContent) {
        switch content {
        case .xmlElement(let nodeName):
            e.writeVarUInt(3)  // YXmlElementRefID
            e.writeVarString(nodeName)
        case .xmlText:
            e.writeVarUInt(6)  // YXmlTextRefID
        case .string(let s):
            e.writeVarString(s)
        case .format(let key, let valueJSON):
            e.writeVarString(key)
            e.writeVarString(valueJSON)
        case .any(let values):
            e.writeVarUInt(UInt(values.count))
            for value in values { writeAny(&e, value) }
        }
    }

    private static func writeAny(_ e: inout Lib0Encoder, _ value: YAnyValue) {
        switch value {
        case .string(let s):
            e.writeUInt8(119)
            e.writeVarString(s)
        case .int(let n):
            e.writeUInt8(125)
            e.writeVarInt(n)
        case .bool(let b): e.writeUInt8(b ? 120 : 121)
        case .null: e.writeUInt8(126)
        case .undefined: e.writeUInt8(127)
        }
    }
}
