import Foundation

/// Crafted deep type-nesting update frames — the shape a hostile peer sends to
/// drive the delete/gc cascades off the native stack. Shared by the store-level
/// recursion tests and the collaboration-manager fail-safe test.
enum DeepNestingFixtures {
    /// LEB128 unsigned varint.
    private static func varUInt(_ value: UInt) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        while v >= 0x80 {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
        return out
    }

    /// An update on client 42 building a `depth`-deep chain of nested array types:
    /// struct 0 parented to the named root `"t"`, struct i>0 parented to
    /// `id(42, i-1)`, each `ContentType` typeRef 0 (array). `deleteRoot` appends a
    /// delete set removing `(42, 0)`; `innermostFirst` orders the delete-set ranges
    /// highest-clock→lowest, keeping every per-item delete cascade shallow so the
    /// depth lands entirely in gc (`tryGcDeleteSet`).
    static func nestedTypeChain(depth: Int, deleteRoot: Bool, innermostFirst: Bool = false) -> Data {
        var out: [UInt8] = []
        out += varUInt(1)  // 1 client block
        out += varUInt(UInt(depth))  // numStructs
        out += varUInt(42)  // client
        out += varUInt(0)  // first clock

        // struct 0: ContentType (info 0x07), parent = named root "t", typeRef 0.
        out += [0x07, 0x01, 0x01, 0x74, 0x00]
        // struct i>0: ContentType, parent = id(42, i-1), typeRef 0.
        for i in 1..<depth {
            out += [0x07, 0x00]
            out += varUInt(42)
            out += varUInt(UInt(i - 1))
            out += [0x00]
        }

        if deleteRoot {
            out += varUInt(1)  // 1 client in the delete set
            out += varUInt(42)  // client
            if innermostFirst {
                out += varUInt(UInt(depth))  // one range per clock, highest first
                for clock in stride(from: depth - 1, through: 0, by: -1) {
                    out += varUInt(UInt(clock))
                    out += varUInt(1)
                }
            } else {
                out += varUInt(1)  // 1 range
                out += varUInt(0)  // clock 0
                out += varUInt(1)  // length 1 (deleting the root cascades to children)
            }
        } else {
            out += varUInt(0)  // empty delete set
        }
        return Data(out)
    }
}
