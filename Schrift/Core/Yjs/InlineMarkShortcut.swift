import Foundation

/// A matched inline markdown mark typing shortcut ending at the caret:
/// `**x**` / `__x__` (bold), `*x*` / `_x_` (italic), `` `x` `` (code), `~~x~~` (strike).
struct InlineMarkShortcutMatch: Equatable, Sendable {
    /// Block-relative UTF-16 range covering opening delimiter + body + closing delimiter.
    let fullRange: Range<Int>
    /// UTF-16 length of each delimiter (1 or 2).
    let delimiterLength: Int
    /// BlockNote mark key (`"bold"`, `"italic"`, `"code"`, `"strike"`).
    let markKey: String
    /// The delimiter string itself (`"**"`, `"__"`, `"*"`, `"_"`, `` "`" ``, `"~~"`).
    let delimiter: String

    var bodyRange: Range<Int> {
        (fullRange.lowerBound + delimiterLength)..<(fullRange.upperBound - delimiterLength)
    }

    var openingRange: Range<Int> {
        fullRange.lowerBound..<(fullRange.lowerBound + delimiterLength)
    }

    var closingRange: Range<Int> {
        (fullRange.upperBound - delimiterLength)..<fullRange.upperBound
    }

    /// True when `units` contains at least one visible scalar (neither
    /// whitespace/newline nor an inline-object placeholder `U+FFFC`).
    static func hasVisibleBody(_ units: ArraySlice<UInt16>) -> Bool {
        String(decoding: units, as: UTF16.self).unicodeScalars.contains {
            !CharacterSet.whitespacesAndNewlines.contains($0) && $0.value != 0xFFFC
        }
    }
}

/// Detects an inline markdown mark shortcut ending exactly at `caretOffset`
/// (UTF-16 offset in `text`), matching BlockNote/TipTap's mark input rules.
///
/// - Delimiters: `**x**` and `__x__` bold, `*x*` and `_x_` italic, `` `x` `` code,
///   `~~x~~` strike.
/// - Opening delimiter must be at block start or immediately preceded by whitespace.
/// - Body must be non-empty, not whitespace-only (nor inline-object-only), and
///   must not contain the delimiter character.
func detectInlineMarkShortcut(text: String, caretOffset: Int) -> InlineMarkShortcutMatch? {
    detectInlineMarkShortcut(units: Array(text.utf16), caretOffset: caretOffset)
}

private func detectInlineMarkShortcut(units: [UInt16], caretOffset: Int) -> InlineMarkShortcutMatch? {
    guard caretOffset >= 3, caretOffset <= units.count else { return nil }
    let lastUnit = units[caretOffset - 1]
    let candidates: [(delimiter: String, unit: UInt16, length: Int, markKey: String)]
    switch lastUnit {
    case 0x2A:  // '*'
        candidates = [("**", 0x2A, 2, "bold"), ("*", 0x2A, 1, "italic")]
    case 0x5F:  // '_'
        candidates = [("__", 0x5F, 2, "bold"), ("_", 0x5F, 1, "italic")]
    case 0x60:  // '`'
        candidates = [("`", 0x60, 1, "code")]
    case 0x7E:  // '~'
        candidates = [("~~", 0x7E, 2, "strike")]
    default:
        return nil
    }

    for candidate in candidates {
        let len = candidate.length
        guard caretOffset >= 2 * len + 1 else { continue }
        let bodyEnd = caretOffset - len
        guard (bodyEnd..<caretOffset).allSatisfy({ units[$0] == candidate.unit }) else { continue }
        // Scan backward across the body; it cannot contain the delimiter character.
        var bodyStart = bodyEnd
        while bodyStart > 0, units[bodyStart - 1] != candidate.unit {
            bodyStart -= 1
        }
        guard bodyStart < bodyEnd, bodyStart >= len else { continue }
        let openStart = bodyStart - len
        guard (openStart..<bodyStart).allSatisfy({ units[$0] == candidate.unit }) else { continue }
        // Opening delimiter must sit at block start or right after whitespace.
        if openStart > 0 {
            let before = units[openStart - 1]
            // Low surrogates belong to non-BMP scalars, none of which are whitespace.
            guard !(0xDC00...0xDFFF).contains(before),
                let scalar = Unicode.Scalar(before),
                CharacterSet.whitespacesAndNewlines.contains(scalar)
            else { continue }
        }
        guard InlineMarkShortcutMatch.hasVisibleBody(units[bodyStart..<bodyEnd]) else { continue }

        return InlineMarkShortcutMatch(
            fullRange: openStart..<caretOffset,
            delimiterLength: len,
            markKey: candidate.markKey,
            delimiter: candidate.delimiter)
    }
    return nil
}
