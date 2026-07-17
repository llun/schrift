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

    /// lib0 `writeAny` — the tagged encoding of an arbitrary JSON-ish value. The
    /// inverse of `Lib0Decoder.readAny`; the float/bigint blobs are re-emitted as
    /// the exact bytes they decoded from, so a decode→encode round-trip is
    /// byte-identical without re-deriving lib0's number-classification. The five
    /// original cases (string/int/bool/null/undefined) emit the same bytes the
    /// document-update encoder always did — the golden fixtures gate that.
    mutating func writeAny(_ value: YAnyValue) {
        switch value {
        case .string(let s):
            writeUInt8(119)
            writeVarString(s)
        case .int(let n):
            writeUInt8(125)
            writeVarInt(n)
        case .negativeZero:
            writeUInt8(125)
            writeUInt8(0x40)
        case .float32(let bytes):
            writeUInt8(124)
            data.append(bytes)
        case .float64(let bytes):
            writeUInt8(123)
            data.append(bytes)
        case .bigInt(let bytes):
            writeUInt8(122)
            data.append(bytes)
        case .bool(let b): writeUInt8(b ? 120 : 121)
        case .null: writeUInt8(126)
        case .undefined: writeUInt8(127)
        case .object(let entries):
            writeUInt8(118)
            writeVarUInt(UInt(entries.count))
            for entry in entries {
                writeVarString(entry.key)
                writeAny(entry.value)
            }
        case .array(let values):
            writeUInt8(117)
            writeVarUInt(UInt(values.count))
            for value in values { writeAny(value) }
        case .uint8Array(let bytes):
            writeUInt8(116)
            writeVarUint8Array(bytes)
        }
    }
}

// MARK: - Yjs struct model (a single-client, from-scratch document update)

/// An ordered `object` entry inside a `YAnyValue.object` — lib0 preserves JS
/// object insertion order on the wire, so entries are an array, not a dictionary.
struct YAnyObjectEntry: Equatable, Sendable {
    let key: String
    let value: YAnyValue
}

/// A JSON-representable attribute value — lib0's `readAny`/`writeAny` domain.
///
/// The original five cases (string/int/bool/null/undefined) are all a
/// from-scratch BlockNote document needs to *write*; the rest were added for the
/// read side (decoding arbitrary remote updates), so the full lib0 tag set
/// round-trips. Floats and bigints are held as their **raw wire bytes** rather
/// than a `Double`/`Int64`, so a decode→re-encode is byte-identical without
/// replaying lib0's integer-vs-float32-vs-float64 classification (an
/// interpretation the projection layer can do later, when it needs the value).
enum YAnyValue: Equatable, Sendable {
    case string(String)  // tag 119
    case int(Int)  // tag 125 (lib0 signed varint)
    /// JS `-0`, which yjs writes as tag 125 + the byte `0x40`. Swift `Int` can't
    /// hold negative zero, so it needs its own case to round-trip byte-identically.
    case negativeZero  // tag 125, byte 0x40
    case float32(Data)  // tag 124 — raw 4 big-endian bytes
    case float64(Data)  // tag 123 — raw 8 big-endian bytes
    case bigInt(Data)  // tag 122 — raw 8 big-endian bytes
    case bool(Bool)  // tags 120 (true) / 121 (false)
    case null  // tag 126
    /// JS `undefined`, distinct from `null` on the wire (lib0 `writeAny` emits
    /// 127 for undefined, 126 for null). BlockNote serializes an unset optional
    /// prop — e.g. the image block's `previewWidth` — as `undefined`, so a
    /// byte-exact image block needs this case.
    case undefined  // tag 127
    case object([YAnyObjectEntry])  // tag 118
    case array([YAnyValue])  // tag 117
    case uint8Array(Data)  // tag 116
}

/// The content payload of a Yjs `Item`, as the **from-scratch encoder** models it.
/// Only the variants a newly built BlockNote document needs are present.
///
/// Distinct from `YContent` (`YContent.swift`), the live CRDT store's mutable
/// content: this one is a write-only description of a document being built from
/// nothing by a single client, so it needs no splice, merge, or integrate.
enum YEncoderContent: Equatable {
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

/// One Yjs `Item`, as the **from-scratch encoder** models it. Every item in a
/// from-scratch document is authored by the same client, so IDs are
/// `(clientID, clock)` and `origin` is just a clock.
///
/// Distinct from `YItem` (`YStruct.swift`), the live CRDT store's item: that one
/// is the full YATA operation, with real origins, a parent pointer, and the
/// left/right links this single-client encoder never needs.
struct YEncoderItem: Equatable {
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
    var content: YEncoderContent
}

// MARK: - Update serialization

enum YjsUpdateEncoder {
    /// Serializes a from-scratch document (single client, empty delete set) into
    /// a Yjs v1 update — the exact bytes `Y.encodeStateAsUpdate` produces.
    static func encode(clientID: UInt32, items: [YEncoderItem]) -> Data {
        var e = Lib0Encoder()
        e.writeVarUInt(1)  // number of clients
        e.writeVarUInt(UInt(items.count))  // structs for this client
        e.writeVarUInt(UInt(clientID))  // client id
        e.writeVarUInt(UInt(items.first?.clock ?? 0))  // clock of first struct
        for item in items { writeItem(&e, clientID: clientID, item) }
        e.writeVarUInt(0)  // delete set: 0 clients
        return e.data
    }

    private static func writeItem(_ e: inout Lib0Encoder, clientID: UInt32, _ item: YEncoderItem) {
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

    private static func writeContent(_ e: inout Lib0Encoder, _ content: YEncoderContent) {
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
            for value in values { e.writeAny(value) }
        }
    }
}
