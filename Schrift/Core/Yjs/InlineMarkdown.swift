import Foundation

// Parses the common inline markdown spans inside a block's text into BlockNote
// styled runs. Deliberately conservative: only unambiguous spans are parsed;
// anything ambiguous is left as literal text so a save never mangles content.
//
// Supported: `**bold**`, `*italic*`, `_italic_`, `` `code` ``, `~~strike~~`,
// `[text](url)`, and backslash escapes of markdown punctuation.
//
// The scanner emits **ranges**, not just text: `layout(of:)` partitions the
// source into the characters the reader sees (`spans`) and the markdown
// punctuation that produces them (`syntax`). `parse(_:)` is a projection of
// that same result, so the block editor's styling and the save path can never
// disagree about what a `*` means — they are one engine, not two. See the
// "Editor & the on-device save" section in `CLAUDE.md`.

/// An inline mark carried by a span of text. `key`/`valueJSON` are the exact
/// BlockNote wire values the Yjs encoder emits; changing either changes the
/// saved bytes and breaks the golden hex tests.
enum InlineMark: Equatable, Sendable {
    case bold
    case italic
    case code
    case strike
    /// `href` is the **raw** destination substring, never re-normalized through
    /// `URL` — the backend matches it byte-for-byte.
    case link(href: String)

    var key: String {
        switch self {
        case .bold: return "bold"
        case .italic: return "italic"
        case .code: return "code"
        case .strike: return "strike"
        case .link: return "link"
        }
    }

    var valueJSON: String {
        switch self {
        case .bold: return InlineMarkdown.boldValue
        case .italic: return InlineMarkdown.italicValue
        case .code: return InlineMarkdown.codeValue
        case .strike: return InlineMarkdown.strikeValue
        case .link(let href): return linkValueJSON(href)
        }
    }
}

/// A contiguous run of *visible* characters and the marks that apply to them.
/// `range` is in UTF-16 (`NSRange`) coordinates over the block's markdown
/// source — the same coordinates `UITextView.selectedRange` uses.
struct InlineSpan: Equatable, Sendable {
    let range: NSRange
    let marks: [InlineMark]
}

/// A `[label](url)` occurrence located in the source.
struct InlineLinkSpan: Equatable, Sendable {
    /// The full `[label](url)` extent — what "remove the link" replaces.
    let range: NSRange
    /// The `label` portion, still carrying its backslash escapes.
    let labelRange: NSRange
    /// The label as the reader sees it (escapes resolved).
    let label: String
    /// The raw destination substring.
    let url: String
}

/// The complete inline structure of one block's markdown source.
///
/// **Partition invariant:** every UTF-16 offset of the source belongs to
/// exactly one of `spans` (visible content) or `syntax` (markdown punctuation).
/// `syntax` is *computed as the complement* of `spans`, so the two cannot drift
/// apart as the grammar grows.
struct InlineLayout: Equatable, Sendable {
    let spans: [InlineSpan]
    let syntax: [NSRange]
    let links: [InlineLinkSpan]
}

enum InlineMarkdown {
    static let boldValue = "{}"
    static let italicValue = "{}"
    static let codeValue = "{}"
    static let strikeValue = "{}"

    /// The BlockNote styled runs for `text` — a projection of `layout(of:)`.
    static func parse(_ text: String) -> [InlineRun] {
        let source = text as NSString
        let runs = layout(of: text).spans.map { span in
            InlineRun(source.substring(with: span.range), marks: span.marks.map { ($0.key, $0.valueJSON) })
        }
        return merged(runs)
    }

    /// The visible/hidden partition of `text`, plus its links.
    static func layout(of text: String) -> InlineLayout {
        var scanner = Scanner(source: text)
        scanner.scanAll()
        return scanner.finish()
    }

    // MARK: - Scanner

    /// Walks the source once, in `Character` units (so grapheme clusters are
    /// never split), while carrying a parallel prefix sum of UTF-16 lengths so
    /// every emitted range is expressible as an `NSRange`.
    ///
    /// Nested constructs recurse over **index sub-ranges of the original array**
    /// rather than over substring copies. Copies would be simpler, but they lose
    /// the offsets, and the offsets are the entire point.
    private struct Scanner {
        private let source: NSString
        private let chars: [Character]
        /// `utf16[i]` is the UTF-16 offset at which `chars[i]` begins.
        private let utf16: [Int]
        private var spans: [InlineSpan] = []
        private var links: [InlineLinkSpan] = []
        /// The content run being accumulated, in `Character` indices.
        private var pending: (range: Range<Int>, marks: [InlineMark])?

        init(source: String) {
            let chars = Array(source)
            var offsets = [Int](repeating: 0, count: chars.count + 1)
            for (index, character) in chars.enumerated() {
                offsets[index + 1] = offsets[index] + character.utf16.count
            }
            self.source = source as NSString
            self.chars = chars
            self.utf16 = offsets
        }

        mutating func scanAll() {
            scan(0..<chars.count, marks: [])
        }

        mutating func finish() -> InlineLayout {
            flushPending()
            // Nested links (pathological, but the grammar permits recursing into
            // a label) append inner-first; document order is what callers expect.
            links.sort { $0.range.location < $1.range.location }
            return InlineLayout(spans: spans, syntax: complementOfSpans(), links: links)
        }

        /// `marks` is carried onto every literal character produced, outermost
        /// first — the order the Yjs encoder serializes them in.
        private mutating func scan(_ bounds: Range<Int>, marks: [InlineMark]) {
            var i = bounds.lowerBound
            let n = bounds.upperBound

            while i < n {
                let c = chars[i]

                // Backslash escape: the backslash is syntax, the escaped
                // character is literal content.
                if c == "\\", i + 1 < n, isEscapable(chars[i + 1]) {
                    emit(i + 1..<i + 2, marks: marks)
                    i += 2
                    continue
                }

                // Inline code span: content is literal — no nested parsing and no
                // backslash escapes (backslash is a literal character inside code).
                // Require non-empty content so adjacent backticks stay literal.
                if c == "`", let close = indexOf("`", from: i + 1, limit: n, honoringEscapes: false), close > i + 1 {
                    emit(i + 1..<close, marks: adding(.code, to: marks))
                    i = close + 1
                    continue
                }

                // Link: [text](url)
                if c == "[", let link = matchLink(from: i, limit: n) {
                    let url = String(chars[link.urlRange])
                    // Flush *before* marking the label's first span: the text
                    // preceding the link is still pending and would otherwise be
                    // appended after this index and read back as part of the label.
                    flushPending()
                    let firstLabelSpan = spans.count
                    scan(link.labelRange, marks: marks + [.link(href: url)])
                    flushPending()
                    links.append(
                        InlineLinkSpan(
                            range: nsRange(i..<link.next),
                            labelRange: nsRange(link.labelRange),
                            label: text(ofSpansFrom: firstLabelSpan),
                            url: url
                        ))
                    i = link.next
                    continue
                }

                // Strong emphasis: **...**
                if c == "*", i + 1 < n, chars[i + 1] == "*",
                    let close = matchDelimiter(open: i, limit: n, delimiter: "**")
                {
                    scan(i + 2..<close, marks: adding(.bold, to: marks))
                    i = close + 2
                    continue
                }

                // Strikethrough: ~~...~~
                if c == "~", i + 1 < n, chars[i + 1] == "~",
                    let close = matchDelimiter(open: i, limit: n, delimiter: "~~")
                {
                    scan(i + 2..<close, marks: adding(.strike, to: marks))
                    i = close + 2
                    continue
                }

                // Emphasis: *...*
                if c == "*", let close = matchDelimiter(open: i, limit: n, delimiter: "*") {
                    scan(i + 1..<close, marks: adding(.italic, to: marks))
                    i = close + 1
                    continue
                }

                // Emphasis: _..._ — CommonMark's flanking rule, restricted to lone
                // underscores, so `snake_case` and `__x__` stay literal.
                if c == "_", isLoneUnderscore(chars, at: i), canOpenUnderscore(chars, at: i),
                    let close = matchUnderscoreEmphasis(open: i, limit: n)
                {
                    scan(i + 1..<close, marks: adding(.italic, to: marks))
                    i = close + 1
                    continue
                }

                emit(i..<i + 1, marks: marks)
                i += 1
            }
        }

        /// Nesting the same emphasis twice (`*_x_*`) must not emit its mark twice:
        /// a BlockNote format map holds one entry per key, and CommonMark collapses
        /// the pair to a single `<em>`. The golden hex tests cannot catch a
        /// duplicate — they hand-build their runs rather than calling `parse(_:)`.
        ///
        /// Links are exempt: nested links carry distinct `href`s, and only the
        /// four keyed marks can collide.
        private func adding(_ mark: InlineMark, to marks: [InlineMark]) -> [InlineMark] {
            marks.contains { $0.key == mark.key } ? marks : marks + [mark]
        }

        /// Appends visible content, coalescing with the pending run when it is
        /// adjacent and identically marked.
        private mutating func emit(_ range: Range<Int>, marks: [InlineMark]) {
            if let current = pending, current.marks == marks, current.range.upperBound == range.lowerBound {
                pending = (current.range.lowerBound..<range.upperBound, marks)
                return
            }
            flushPending()
            pending = (range, marks)
        }

        private mutating func flushPending() {
            guard let current = pending else { return }
            spans.append(InlineSpan(range: nsRange(current.range), marks: current.marks))
            pending = nil
        }

        /// The reader-visible text of the spans a label's scan just produced —
        /// i.e. the label with its backslash escapes resolved.
        private func text(ofSpansFrom index: Int) -> String {
            spans[index...].map { source.substring(with: $0.range) }.joined()
        }

        private func nsRange(_ range: Range<Int>) -> NSRange {
            NSRange(location: utf16[range.lowerBound], length: utf16[range.upperBound] - utf16[range.lowerBound])
        }

        /// Everything the spans don't cover is markdown punctuation.
        private func complementOfSpans() -> [NSRange] {
            var gaps: [NSRange] = []
            var cursor = 0
            for span in spans {
                if span.range.location > cursor {
                    gaps.append(NSRange(location: cursor, length: span.range.location - cursor))
                }
                cursor = max(cursor, span.range.location + span.range.length)
            }
            let end = utf16[chars.count]
            if cursor < end {
                gaps.append(NSRange(location: cursor, length: end - cursor))
            }
            return gaps
        }

        // MARK: Grammar

        private func isEscapable(_ c: Character) -> Bool {
            "\\`*_{}[]()#+-.!~>|".contains(c)
        }

        /// Finds `ch` at or after `from`, before `limit`. When `honoringEscapes`
        /// is true a backslash escapes the following character (used for link
        /// `]`/`)` scanning); code spans pass false because their content is literal.
        private func indexOf(_ ch: Character, from: Int, limit: Int, honoringEscapes: Bool = true) -> Int? {
            var i = from
            while i < limit {
                if honoringEscapes, chars[i] == "\\" {
                    i += 2
                    continue
                }  // skip escaped char
                if chars[i] == ch { return i }
                i += 1
            }
            return nil
        }

        /// Finds the matching closing `delimiter` (length 1 or 2) for an opening
        /// at `open`, requiring non-empty, non-blank inner content. Returns the
        /// index of the first char of the closing delimiter, or nil if unmatched.
        private func matchDelimiter(open: Int, limit: Int, delimiter: String) -> Int? {
            let d = Array(delimiter)
            let len = d.count
            var i = open + len
            while i < limit {
                if chars[i] == "\\" {
                    i += 2
                    continue
                }
                if i + len <= limit, Array(chars[i..<(i + len)]) == d {
                    let inner = chars[(open + len)..<i]
                    if inner.isEmpty || inner.allSatisfy({ $0 == " " }) { return nil }
                    return i
                }
                i += 1
            }
            return nil
        }

        /// Finds the closing `_` for an opening at `open`: the first lone `_` that
        /// can close, honoring backslash escapes, with non-empty, non-blank inner
        /// content — the same guards `matchDelimiter` applies.
        ///
        /// Flanking is evaluated against the **whole** `chars` array rather than
        /// `bounds`, because it is a property of the source text. That is exactly
        /// why `**_word_**` opens: the opening `_`'s predecessor is `*`, which is
        /// punctuation. The closing search still respects `limit`, so emphasis can
        /// never escape the span that contains it.
        ///
        /// **Code spans and links bind tighter than emphasis**, as in CommonMark,
        /// so the search steps over them whole. Without that, `` _`_` `` closed on
        /// the underscore *inside* the code span and destroyed it, and a `_` in a
        /// link's destination (`_[x](a_ b)_`) tore the link apart — both of which a
        /// full-overwrite save would then persist. Differential fuzzing against the
        /// previous scanner found exactly this: 100 of the corpus's diverging
        /// inputs were code spans being swallowed.
        ///
        /// `*`'s `matchDelimiter` does not step over them, and is deliberately left
        /// alone: changing it would move the saved bytes of every `*italic*` and
        /// `**bold**` in every existing document.
        ///
        /// An opener never reaches **past** an interior opener to grab a distant
        /// closer (equivalently: a closer pairs with the nearest opener, as in
        /// CommonMark). An intermediate lone `_` that can open but not close (a `_`
        /// at a left word boundary — space before, letter after) starts a *new*
        /// emphasis, so the search stops there and this opener stays literal.
        /// Without it, `_foo _bar_` italicized `foo _bar` where CommonMark — and
        /// the reading surface — italicize only `bar`, leaving `_foo ` literal. It
        /// is the conservative direction (an ambiguous leading `_` stays content),
        /// and it never drops a character. This is not a full CommonMark delimiter
        /// stack: deeper `_`+`*` tangles can still differ, the same signed-off
        /// out-of-scope class the `*` matcher already lives with.
        private func matchUnderscoreEmphasis(open: Int, limit: Int) -> Int? {
            var i = open + 1
            while i < limit {
                if chars[i] == "\\" {
                    i += 2
                    continue
                }
                if chars[i] == "`", let close = indexOf("`", from: i + 1, limit: limit, honoringEscapes: false),
                    close > i + 1
                {
                    i = close + 1
                    continue
                }
                if chars[i] == "[", let link = matchLink(from: i, limit: limit) {
                    i = link.next
                    continue
                }
                if chars[i] == "_", isLoneUnderscore(chars, at: i) {
                    if canCloseUnderscore(chars, at: i) {
                        let inner = chars[(open + 1)..<i]
                        if inner.isEmpty || inner.allSatisfy({ $0 == " " }) { return nil }
                        return i
                    }
                    if canOpenUnderscore(chars, at: i) { return nil }
                }
                i += 1
            }
            return nil
        }

        /// Matches `[text](url)` starting at `open` (a `[`).
        private func matchLink(from open: Int, limit: Int) -> (labelRange: Range<Int>, urlRange: Range<Int>, next: Int)?
        {
            guard let closeBracket = indexOf("]", from: open + 1, limit: limit) else { return nil }
            let parenOpen = closeBracket + 1
            guard parenOpen < limit, chars[parenOpen] == "(" else { return nil }
            guard let closeParen = indexOf(")", from: parenOpen + 1, limit: limit) else { return nil }
            let labelRange = (open + 1)..<closeBracket
            let urlRange = (parenOpen + 1)..<closeParen
            if labelRange.isEmpty || urlRange.isEmpty { return nil }
            return (labelRange, urlRange, closeParen + 1)
        }
    }

    /// Coalesces adjacent runs carrying identical marks.
    private static func merged(_ runs: [InlineRun]) -> [InlineRun] {
        var result: [InlineRun] = []
        for run in runs {
            if var last = result.last, sameMarks(last.marks, run.marks) {
                last.text += run.text
                result[result.count - 1] = last
            } else {
                result.append(run)
            }
        }
        return result
    }

    private static func sameMarks(_ a: [(key: String, valueJSON: String)], _ b: [(key: String, valueJSON: String)])
        -> Bool
    {
        a.map { [$0.key, $0.valueJSON] } == b.map { [$0.key, $0.valueJSON] }
    }
}

/// BlockNote stores a link mark's destination as `{"href": …}`. Built with
/// `JSONSerialization`, never string interpolation: the url is user data.
///
/// `.withoutEscapingSlashes` is **load-bearing**, not cosmetic. Yjs writes a
/// mark value as `writeVarString(JSON.stringify(value))`, and JavaScript's
/// `JSON.stringify` does not escape `/`. Foundation's default does, so without
/// this the encoder emitted `{"href":"https:\/\/x"}` (32 bytes) where yjs emits
/// `{"href":"https://x"}` (30) — semantically identical after `JSON.parse`, but
/// not byte-identical, which is the invariant `Core/Yjs` exists to hold.
/// `YjsEncoderTests.testLinkMark`'s golden hex is the unescaped form; it never
/// caught this because it hand-builds its `InlineRun`s instead of calling
/// `parse(_:)`. `InlineLayoutTests.testParseProducesExactlyTheRuns…` closes that.
private func linkValueJSON(_ url: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: ["href": url], options: [.withoutEscapingSlashes])
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"href\":\"\"}"
}

// MARK: - Underscore emphasis

/// CommonMark's ASCII punctuation set, spelled out from the spec.
private let asciiPunctuation: Set<Character> = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

/// CommonMark's "Unicode punctuation character": an ASCII punctuation character,
/// or one in the general categories `Pc, Pd, Pe, Pf, Pi, Po, Ps`.
///
/// Deliberately **not** `Character.isSymbol`, which is true for `+`, `😀` and `€`
/// alike. Only `+` counts here (it is ASCII), and the difference is observable in
/// Foundation's `AttributedString(markdown:)` — the reading surface, and the
/// oracle this rule converges on: `a+_x_+a` is emphasis, `😀_x_😀` is literal.
/// `Character.isPunctuation` is exactly the `P*` categories.
private func isMarkdownPunctuation(_ character: Character) -> Bool {
    character.isASCII ? asciiPunctuation.contains(character) : character.isPunctuation
}

/// The character before/after `index`, where the block's edges read as whitespace
/// — CommonMark treats the start and end of a line as such.
private func neighbor(_ chars: [Character], _ index: Int) -> Character? {
    chars.indices.contains(index) ? chars[index] : nil
}

/// A delimiter is **left-flanking** when it is not followed by whitespace and
/// either is not followed by punctuation, or is preceded by whitespace or
/// punctuation.
private func isLeftFlanking(_ chars: [Character], at index: Int) -> Bool {
    guard let next = neighbor(chars, index + 1), !next.isWhitespace else { return false }
    guard isMarkdownPunctuation(next) else { return true }
    guard let previous = neighbor(chars, index - 1) else { return true }
    return previous.isWhitespace || isMarkdownPunctuation(previous)
}

/// A delimiter is **right-flanking** when it is not preceded by whitespace and
/// either is not preceded by punctuation, or is followed by whitespace or
/// punctuation.
private func isRightFlanking(_ chars: [Character], at index: Int) -> Bool {
    guard let previous = neighbor(chars, index - 1), !previous.isWhitespace else { return false }
    guard isMarkdownPunctuation(previous) else { return true }
    guard let next = neighbor(chars, index + 1) else { return true }
    return next.isWhitespace || isMarkdownPunctuation(next)
}

/// A `_` participates as a delimiter only when it stands alone. Runs of two or
/// more (`__x__`, the `___` divider, `snake__case`) stay literal — the
/// conservative choice, and the one that keeps every such document's saved bytes
/// unchanged. `wrapInlineMarker` enforces the parallel rule from the editing
/// side (via `hugsDelimiterRuns`): a marker must never eat a longer delimiter run.
private func isLoneUnderscore(_ chars: [Character], at index: Int) -> Bool {
    chars[index] == "_" && neighbor(chars, index - 1) != "_" && neighbor(chars, index + 1) != "_"
}

/// Unlike `*`, a `_` may not open emphasis inside a word — this is what keeps
/// `snake_case` literal while `_word_` is emphasis.
private func canOpenUnderscore(_ chars: [Character], at index: Int) -> Bool {
    guard isLeftFlanking(chars, at: index) else { return false }
    guard isRightFlanking(chars, at: index) else { return true }
    // Right-flanking implies a non-whitespace predecessor exists.
    return neighbor(chars, index - 1).map(isMarkdownPunctuation) ?? false
}

/// The mirror of `canOpenUnderscore`: a `_` may not close emphasis inside a word.
private func canCloseUnderscore(_ chars: [Character], at index: Int) -> Bool {
    guard isRightFlanking(chars, at: index) else { return false }
    guard isLeftFlanking(chars, at: index) else { return true }
    return neighbor(chars, index + 1).map(isMarkdownPunctuation) ?? false
}
