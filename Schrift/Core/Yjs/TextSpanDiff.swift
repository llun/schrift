import Foundation

// MARK: - Char-level (char,marks) span diff (B6)

/// A per-character view of a run list: the UTF-16 units and the marks active at
/// each unit (marks as a `[key: valueJSON]` dictionary — one entry per key,
/// matching BlockNote's format map).
struct MarkedText: Equatable {
    var units: [UInt16]
    var marks: [[String: String]]
}

/// Computes the minimal changed visible range between an old and new run list,
/// plus the new span's pieces with self-describing boundary marks. This is the
/// crux algorithm behind the within-block text edit (`YWrite.delete` +
/// `YWrite.insert(pieces)`): the store never needs to know what was open
/// before the edit, because every inserted span carries its own opens/closes.
enum TextSpanDiff {
    /// Flattens `runs` into a per-UTF-16-unit view: each unit paired with the
    /// dictionary of marks active over it.
    static func marked(_ runs: [InlineRun]) -> MarkedText {
        var units: [UInt16] = []
        var marks: [[String: String]] = []
        for run in runs {
            // `uniquingKeysWith:` (last-wins) rather than `uniqueKeysWithValues:`, which
            // traps on a duplicate key — a run's marks array is not guaranteed unique by
            // its type, and the store must never crash on malformed input (see CLAUDE.md
            // "Malformed input must throw, never trap").
            let m = Dictionary(run.marks.map { ($0.key, $0.valueJSON) }, uniquingKeysWith: { _, last in last })
            for u in Array(run.text.utf16) {
                units.append(u)
                marks.append(m)
            }
        }
        return MarkedText(units: units, marks: marks)
    }

    /// True for a UTF-16 high (leading) surrogate code unit (`0xD800...0xDBFF`).
    private static func isHighSurrogate(_ u: UInt16) -> Bool { (0xD800...0xDBFF).contains(u) }

    /// True for a UTF-16 low (trailing) surrogate code unit (`0xDC00...0xDFFF`).
    private static func isLowSurrogate(_ u: UInt16) -> Bool { (0xDC00...0xDFFF).contains(u) }

    /// The change to turn `old` into `new`: delete visible [range.lowerBound,
    /// range.upperBound) (UTF-16 indices into old), then insert `pieces`
    /// (self-describing: opens the marks active at the new start, restores the
    /// marks the kept suffix expects at the new end). nil ⇒ no change.
    static func diff(old: [InlineRun], new: [InlineRun]) -> (deleteRange: Range<Int>, insertPieces: [InlinePiece])? {
        let a = marked(old)
        let b = marked(new)
        if a == b { return nil }
        let maxCommon = min(a.units.count, b.units.count)
        var p = 0
        while p < maxCommon, a.units[p] == b.units[p], a.marks[p] == b.marks[p] { p += 1 }
        // A trailing high surrogate in the common prefix means its low surrogate fell into
        // the changed region — the prefix boundary is mid-pair. Back it up so the whole
        // code point is in the changed span (never split a surrogate pair; yjs would render
        // U+FFFD — yjs#248 — corrupting a swap of two astral chars sharing a high surrogate).
        if p > 0, isHighSurrogate(a.units[p - 1]) { p -= 1 }
        var s = 0
        let budget = maxCommon - p
        while s < budget,
            a.units[a.units.count - 1 - s] == b.units[b.units.count - 1 - s],
            a.marks[a.marks.count - 1 - s] == b.marks[b.marks.count - 1 - s]
        { s += 1 }
        // A leading low surrogate in the common suffix means its high surrogate fell into the
        // changed region — back the suffix off so the whole code point is in the changed span
        // (the mirror of the prefix snap, for two astral chars sharing a low surrogate).
        if s > 0, isLowSurrogate(a.units[a.units.count - s]) { s -= 1 }
        let deleteRange = p..<(a.units.count - s)  // UTF-16 indices into old
        // Rebuild the new span [p, newLen - s) as self-describing pieces: the marks
        // active just-left in `new` (marks[p-1]) are what the kept prefix already
        // holds open; the inserted span opens/closes relative to that, and restores
        // the suffix's leading marks at its end.
        let newStart = p
        let newEnd = b.units.count - s
        let leftMarks = newStart > 0 ? b.marks[newStart - 1] : [:]
        let rightMarks = newEnd < b.units.count ? b.marks[newEnd] : [:]
        let pieces = buildSpanPieces(b, from: newStart, to: newEnd, leftMarks: leftMarks, rightMarks: rightMarks)
        return (deleteRange, pieces)
    }

    /// The pieces for units [from, to), opening every mark transition relative to
    /// `leftMarks` (already open from the kept prefix) and closing to `rightMarks`
    /// (the kept suffix's leading marks) at the end. Self-describing ⇒ correct even
    /// when the deletion removed the format items the suffix relied on.
    private static func buildSpanPieces(
        _ b: MarkedText, from: Int, to: Int, leftMarks: [String: String], rightMarks: [String: String]
    ) -> [InlinePiece] {
        var out: [InlinePiece] = []
        var open = leftMarks
        var i = from
        while i < to {
            let want = b.marks[i]
            emitTransition(from: &open, to: want, into: &out)
            // Coalesce a maximal run of identical marks into one string piece.
            var j = i
            var units: [UInt16] = []
            while j < to, b.marks[j] == want {
                units.append(b.units[j])
                j += 1
            }
            out.append(.string(String(decoding: units, as: UTF16.self)))
            i = j
        }
        // Restore the suffix's leading marks (or, if the span is empty, transition
        // leftMarks → rightMarks so a pure delete still leaves formatting consistent).
        emitTransition(from: &open, to: rightMarks, into: &out)
        return out
    }

    private static func emitTransition(
        from open: inout [String: String], to want: [String: String], into out: inout [InlinePiece]
    ) {
        for (k, _) in open where want[k] == nil {
            out.append(.format(key: k, valueJSON: "null"))
            open[k] = nil
        }
        for (k, v) in want where open[k] != v {
            out.append(.format(key: k, valueJSON: v))
            open[k] = v
        }
    }
}
