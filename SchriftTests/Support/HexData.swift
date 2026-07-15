import Foundation

/// Hex helpers shared by the byte-exact Yjs / collaboration suites. Golden
/// fixtures are transcribed as lowercase hex captured from the real `yjs` /
/// `y-protocols` / `@hocuspocus/provider` libraries.
extension Data {
    /// Parses a lowercase/uppercase hex string ("0a1b…") into bytes.
    ///
    /// Traps on malformed input (odd length or a non-hex digit): a mistyped
    /// fixture is a test-authoring bug that should fail loudly at the call site,
    /// not silently decode to the wrong bytes.
    init(hex: String) {
        precondition(hex.count % 2 == 0, "hex string must have an even length: \(hex)")
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                preconditionFailure("invalid hex byte in fixture: \(hex[index..<next])")
            }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    /// Lowercase hex of these bytes, for golden-byte assertions.
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
