import Foundation

/// Deeply-nested lib0 `any` fixtures — the shape a hostile peer would send to
/// drive `Lib0Decoder.readAny`'s recursion off the stack. Shared because three
/// suites build the same bytes: the decoder's own boundary tests, the update
/// decoder, and the end-to-end collaboration fail-safe test.
enum NestedAnyFixtures {
    /// `depth` nested single-element arrays (tag 117 + count 1 per level)
    /// wrapping a `null` (tag 126) at the bottom.
    static func nestedArray(depth: Int) -> Data {
        Data(Array(repeating: [0x75, 0x01] as [UInt8], count: depth).flatMap { $0 } + [0x7E])
    }

    /// `depth` nested single-entry objects (tag 118 + count 1 + the one-character
    /// key "a" per level) wrapping a `null`. The object branch nests through
    /// different code than the array branch, so it needs its own fixture.
    static func nestedObject(depth: Int) -> Data {
        Data(Array(repeating: [0x76, 0x01, 0x01, 0x61] as [UInt8], count: depth).flatMap { $0 } + [0x7E])
    }

    /// A full update frame whose single struct is `ContentAny` holding one
    /// `depth`-deep nested array: 1 client, 1 struct, client 42, clock 0,
    /// info 0x08, named root parent "t", 1 value.
    static func contentAnyUpdate(depth: Int) -> Data {
        Data(hex: "01012a000801017401") + nestedArray(depth: depth)
    }
}
