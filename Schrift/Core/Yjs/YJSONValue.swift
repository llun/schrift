import Foundation

// MARK: - JSON value (format-value equality only)

/// A JSON value, parsed so text operations, deltas and cleanup compare
/// `ContentFormat` values the way yjs does.
///
/// Everywhere else Schrift keeps a format value as its raw JSON text (see
/// `YContent.format`), so nothing hinges on JSON canonicalization. yjs's
/// `equalAttrs` first checks identity, then compares objects and arrays by their
/// enumerable keys (lib0 `equalFlat`), with each value compared using `===`.
///
/// Numbers are `Double` because a JS number is a double — `1`, `1.0` and `1e0`
/// are the same value, and a large integer loses exactly the precision
/// `JSON.parse` would. A lone surrogate escape becomes U+FFFD (a Swift `String`
/// cannot hold one; JS keeps it), which only affects a value no schema writes.
/// A JSON object key compared by UTF-16 code units, as JS property keys are.
/// Swift `String` hashes by canonical equivalence, which would merge `"é"` and
/// `"e\u{0301}"` into one key where `JSON.parse` keeps two.
struct YJSONKey: Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    let units: [UInt16]
    init(_ string: String) { units = Array(string.utf16) }
    init(stringLiteral value: String) { self.init(value) }
    var string: String { String(decoding: units, as: UTF16.self) }
    var description: String { string }
}

indirect enum YJSONValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([YJSONValue])
    case object([YJSONKey: YJSONValue])

    /// The deepest nesting `parse` accepts. A format value is a flat object of
    /// primitives in every schema Schrift knows; the cap keeps a crafted
    /// `[[[[…` from recursing the native stack, for the same reason
    /// `Lib0Decoder.maxAnyNestingDepth` exists. Past it `parse` returns nil and
    /// independently parsed values compare unequal (shared identity still wins).
    static let maxNestingDepth = 64

    /// Parses `text`, or nil when it is not JSON. yjs would have rejected such a
    /// value at decode time (`readJSON` calls `JSON.parse`); Schrift keeps the
    /// raw text, so independently parsed unparseable values compare unequal.
    static func parse(_ text: String) -> YJSONValue? {
        var parser = YJSONParser(text)
        return parser.parseDocument()
    }

    /// yjs `equalAttrs` (@6282) over two raw JSON texts: `===`, or lib0
    /// `equalFlat` for two objects/arrays (same key count, every value `===`).
    ///
    /// `nil` is an absent attribute (JS `undefined`), not JSON `null`: yjs's
    /// `undefined === null` is false, so `equalAttrs(nil, "null")` is false here
    /// too. Callers that treat a `"null"` format value as "delete the key" (as
    /// `updateCurrentAttributes` does) normalize it to `nil` first.
    static func equalAttrs(
        _ a: String?, _ b: String?, identityA: YAttributeIdentity? = nil, identityB: YAttributeIdentity? = nil
    ) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case (let a?, let b?):
            // A shared value object is `===` even when its contents are nested
            // beyond the parser's defensive depth cap. JSON text is not identity.
            if let identityA, let identityB, identityA === identityB, isContainer(a), isContainer(b) { return true }
            guard let left = parse(a), let right = parse(b) else { return false }
            if strictEqual(left, right) { return true }
            guard let leftKeys = left.enumerableKeys, let rightKeys = right.enumerableKeys else { return false }
            guard leftKeys.count == rightKeys.count else { return false }
            for (key, value) in leftKeys {
                guard let other = rightKeys[key], strictEqual(value, other) else { return false }
            }
            return true
        }
    }

    static func isContainer(_ text: String) -> Bool {
        let first = text.first { !$0.isWhitespace }
        return first == "{" || first == "["
    }

    /// JS string equality: **UTF-16 code units**, not Swift's canonical
    /// equivalence. `"é"` (U+00E9) and `"e\u{0301}"` are different JS strings and
    /// must compare unequal — Swift's `String ==` would call them equal, which
    /// silently skipped a format whose value differed only in normalization.
    static func jsStringEqual(_ a: String, _ b: String) -> Bool {
        a.utf16.elementsEqual(b.utf16)
    }

    /// `Object.keys` over JSON containers: an array's keys are its indices, so
    /// `[]` and `{}` have the same flat contents, as do `[1]` and `{"0":1}`.
    private var enumerableKeys: [YJSONKey: YJSONValue]? {
        switch self {
        case .object(let members): return members
        case .array(let elements):
            return Dictionary(uniqueKeysWithValues: elements.enumerated().map { (YJSONKey(String($0)), $1) })
        default: return nil
        }
    }

    /// JS `===` over independently parsed JSON. Container identity must be
    /// checked by the caller using the value's token, never its JSON spelling.
    static func strictEqual(_ a: String, _ b: String) -> Bool {
        guard let left = parse(a), let right = parse(b) else { return false }
        return strictEqual(left, right)
    }

    /// JS `===` over two parsed values: primitives by value, containers never
    /// (two parses never share an identity).
    private static func strictEqual(_ a: YJSONValue, _ b: YJSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.number(let x), .number(let y)): return x == y
        case (.string(let x), .string(let y)): return jsStringEqual(x, y)
        default: return false
        }
    }

    /// Structural equality with string leaves compared by **UTF-16 code units**,
    /// as JS `===` compares strings. The synthesized conformance would use Swift's
    /// canonical equivalence, making `"é"` and `"e\u{0301}"` equal.
    static func == (lhs: YJSONValue, rhs: YJSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.string(let a), .string(let b)): return jsStringEqual(a, b)
        case (.array(let a), .array(let b)):
            guard a.count == b.count else { return false }
            for (x, y) in zip(a, b) where x != y { return false }
            return true
        case (.object(let a), .object(let b)):
            guard a.count == b.count else { return false }
            for (key, value) in a {
                guard let other = b[key], value == other else { return false }
            }
            return true
        default: return false
        }
    }
}

// MARK: - Reader

/// A total recursive-descent JSON reader: no traps, no throws. Malformed input
/// returns nil, which `equalAttrs` reads as "not equal".
private struct YJSONParser {
    private let scalars: [Unicode.Scalar]
    private var index = 0

    init(_ text: String) {
        scalars = Array(text.unicodeScalars)
    }

    mutating func parseDocument() -> YJSONValue? {
        guard let value = parseValue(depth: 0) else { return nil }
        skipWhitespace()
        return index == scalars.count ? value : nil
    }

    private mutating func skipWhitespace() {
        while index < scalars.count, Self.isWhitespace(scalars[index]) { index += 1 }
    }

    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
    }

    private mutating func parseValue(depth: Int) -> YJSONValue? {
        guard depth <= YJSONValue.maxNestingDepth else { return nil }
        skipWhitespace()
        guard index < scalars.count else { return nil }
        switch scalars[index] {
        case "{": return parseObject(depth: depth)
        case "[": return parseArray(depth: depth)
        case "\"": return parseString().map { .string($0) }
        case "t": return consume("true") ? .bool(true) : nil
        case "f": return consume("false") ? .bool(false) : nil
        case "n": return consume("null") ? .null : nil
        default: return parseNumber()
        }
    }

    private mutating func consume(_ literal: String) -> Bool {
        let expected = Array(literal.unicodeScalars)
        guard index + expected.count <= scalars.count,
            Array(scalars[index..<(index + expected.count)]) == expected
        else { return false }
        index += expected.count
        return true
    }

    private mutating func parseObject(depth: Int) -> YJSONValue? {
        index += 1  // "{"
        var members: [YJSONKey: YJSONValue] = [:]
        skipWhitespace()
        if index < scalars.count, scalars[index] == "}" {
            index += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard let key = parseString() else { return nil }
            skipWhitespace()
            guard index < scalars.count, scalars[index] == ":" else { return nil }
            index += 1
            guard let value = parseValue(depth: depth + 1) else { return nil }
            // `JSON.parse` keeps the last of duplicate keys, as a dictionary does.
            members[YJSONKey(key)] = value
            skipWhitespace()
            guard index < scalars.count else { return nil }
            if scalars[index] == "," {
                index += 1
                continue
            }
            if scalars[index] == "}" {
                index += 1
                return .object(members)
            }
            return nil
        }
    }

    private mutating func parseArray(depth: Int) -> YJSONValue? {
        index += 1  // "["
        var elements: [YJSONValue] = []
        skipWhitespace()
        if index < scalars.count, scalars[index] == "]" {
            index += 1
            return .array(elements)
        }
        while true {
            guard let value = parseValue(depth: depth + 1) else { return nil }
            elements.append(value)
            skipWhitespace()
            guard index < scalars.count else { return nil }
            if scalars[index] == "," {
                index += 1
                continue
            }
            if scalars[index] == "]" {
                index += 1
                return .array(elements)
            }
            return nil
        }
    }

    private mutating func parseString() -> String? {
        guard index < scalars.count, scalars[index] == "\"" else { return nil }
        index += 1
        var result = ""
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\"" {
                index += 1
                return result
            }
            guard scalar == "\\" else {
                result.unicodeScalars.append(scalar)
                index += 1
                continue
            }
            index += 1
            guard index < scalars.count else { return nil }
            let escape = scalars[index]
            index += 1
            switch escape {
            case "\"": result.unicodeScalars.append("\"")
            case "\\": result.unicodeScalars.append("\\")
            case "/": result.unicodeScalars.append("/")
            case "b": result.unicodeScalars.append("\u{08}")
            case "f": result.unicodeScalars.append("\u{0C}")
            case "n": result.unicodeScalars.append("\n")
            case "r": result.unicodeScalars.append("\r")
            case "t": result.unicodeScalars.append("\t")
            case "u":
                guard let unit = parseHex4() else { return nil }
                if (0xD800...0xDBFF).contains(unit) {
                    // A high surrogate: pair it with a following `\uXXXX` low
                    // surrogate, or replace it — a Swift `String` cannot hold a
                    // lone surrogate, where JS keeps it.
                    let saved = index
                    if index + 1 < scalars.count, scalars[index] == "\\", scalars[index + 1] == "u" {
                        index += 2
                        if let low = parseHex4(), (0xDC00...0xDFFF).contains(low),
                            let combined = Unicode.Scalar(
                                0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))
                        {
                            result.unicodeScalars.append(combined)
                            continue
                        }
                        index = saved
                    }
                    result.unicodeScalars.append("\u{FFFD}")
                } else if let scalar = Unicode.Scalar(unit), !(0xDC00...0xDFFF).contains(unit) {
                    result.unicodeScalars.append(scalar)
                } else {
                    result.unicodeScalars.append("\u{FFFD}")
                }
            default:
                return nil
            }
        }
        return nil
    }

    private mutating func parseHex4() -> UInt32? {
        guard index + 4 <= scalars.count else { return nil }
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let digit = Self.hexValue(scalars[index]) else { return nil }
            value = value << 4 | digit
            index += 1
        }
        return value
    }

    private static func hexValue(_ scalar: Unicode.Scalar) -> UInt32? {
        switch scalar.value {
        case 0x30...0x39: return scalar.value - 0x30
        case 0x41...0x46: return scalar.value - 0x41 + 10
        case 0x61...0x66: return scalar.value - 0x61 + 10
        default: return nil
        }
    }

    private mutating func parseNumber() -> YJSONValue? {
        let start = index
        if index < scalars.count, scalars[index] == "-" { index += 1 }
        var sawDigit = false
        while index < scalars.count, Self.isDigit(scalars[index]) {
            index += 1
            sawDigit = true
        }
        if index < scalars.count, scalars[index] == "." {
            index += 1
            while index < scalars.count, Self.isDigit(scalars[index]) {
                index += 1
                sawDigit = true
            }
        }
        if index < scalars.count, scalars[index] == "e" || scalars[index] == "E" {
            index += 1
            if index < scalars.count, scalars[index] == "+" || scalars[index] == "-" { index += 1 }
            while index < scalars.count, Self.isDigit(scalars[index]) { index += 1 }
        }
        guard sawDigit else { return nil }
        let text = String(String.UnicodeScalarView(scalars[start..<index]))
        guard let value = Double(text) else { return nil }
        return .number(value)
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        (0x30...0x39).contains(scalar.value)
    }
}
