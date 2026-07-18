import Foundation

/// The inverse of `InlineMarkdown`'s scanner: `[InlineRun]` → markdown
/// source. `InlineMarkdown.parse` is the oracle this writer serves — the
/// correctness property is `parse(write(runs, escapeAll:)) ≡ normalized(runs)`
/// (equivalence via `runsEquivalent`, which is order-insensitive on marks).
///
/// This file deliberately does **not** verify the property by calling `parse`
/// on its own output — that stays Task 4's job at the block/document level,
/// with an escalate-then-go-opaque strategy (`escapeAll: false` first,
/// `escapeAll: true` on verification failure, `.unknown` if even that
/// fails). `write` only returns nil for cases it can determine, from the
/// characters it is itself placing, can never round-trip:
/// - a code run whose text is empty or contains a backtick (inline code has
///   no escape mechanism at all — the scanner's code-span content is always
///   literal, see `InlineMarkdown.swift`'s "Backslash inside a code span"
///   handling);
/// - a link whose href contains `(`, `)`, `\`, or whitespace, or is empty
///   (the scanner captures the href as the **raw** characters between the
///   parens — see `matchLink` — so nothing written there is ever unescaped
///   on read-back; there is no spelling of such an href, escaped or not,
///   that reads back to the same string);
/// - a code run nested inside bold, strike, or a link whose (always
///   verbatim, never escaped) text contains that outer mark's own token
///   (`**`, `~~`, or `]` respectively) — `matchDelimiter` and `matchLink`'s
///   bracket search don't skip over nested code spans the way
///   `matchUnderscoreEmphasis` does, so that token would end the outer mark
///   early no matter what;
/// - an italic `_` delimiter this function places that would not actually
///   function as one where it lands — either `isLoneUnderscore` fails (it's
///   immediately adjacent to another `_`, from escaped/literal text or a
///   forced close-then-reopen at the same boundary) or the matching
///   open/close flanking rule fails (see "Italic flanking" below).
/// A link **label** containing `]` is only impossible at `escapeAll: false`
/// (verbatim mode has no way to keep the bracket from closing the label
/// early); `escapeAll: true` fixes it via the ordinary text-escaping path
/// below, since `]` is itself an escapable character — except when that `]`
/// is inside a nested code run, which stays unwritable at any setting per
/// the previous bullet.
///
/// **On the italic-flanking check being here at all:** the task brief this
/// file was built from frames flanking failures against *unrelated
/// surrounding prose* (e.g. an italic run ending flush against a letter in
/// the next run, `_it_x`) as intentionally out of scope for this file —
/// "keep the writer simple, the oracle decides" — deferring them to Task
/// 4's verify-and-escalate loop rather than pre-analysis here. This file
/// still follows that for prose it doesn't control. But the exact seeded
/// fuzz test this brief also specifies (`testSeededFuzzRoundTrip`) asserts
/// unconditional round-tripping for every non-nil `escapeAll: true` output,
/// and — because this function's own stack/persistence/code-innermost
/// bookkeeping fully determines both neighbors of every delimiter it
/// places — several fuzz-discovered cases were delimiters *this function
/// itself* positioned somewhere flanking would fail (see the three bugs
/// fixed together: code-outranking-siblings-by-persistence, code losing its
/// innermost position across a run boundary, and italic landing adjacent to
/// another `_`). Those are mechanically determinable from characters this
/// function is placing, not from prose it doesn't control, so they are
/// checked here — narrowly, using only the scanner's own transcribed
/// predicates, never by calling `parse`.
enum InlineMarkdownWriter {

    // MARK: - Public API

    /// Runs → markdown source that `InlineMarkdown.parse` reads back
    /// equivalently to `normalized(runs)`. `escapeAll: false` emits text
    /// verbatim wherever a mark's own grammar allows it (the caller tries
    /// this first, for the least-cluttered output); `escapeAll: true`
    /// backslash-escapes every scanner-escapable character in non-code text,
    /// which the caller escalates to when verification of the `false`
    /// attempt fails. Returns nil only for the structurally-impossible cases
    /// documented on the type.
    static func write(_ runs: [InlineRun], escapeAll: Bool) -> String? {
        guard hasNoEmptyCodeRun(runs) else { return nil }

        let runs = normalized(runs)
        guard !runs.isEmpty else { return "" }
        guard isNormalizedFormWritable(runs, escapeAll: escapeAll) else { return nil }

        // Built as `[Character]` (rather than appending directly to a
        // `String`) so the italic-flanking check below can index by
        // position — see `italicOpenIndices`/`italicCloseIndices`.
        var outputChars: [Character] = []
        /// Positions in `outputChars` of an italic **delimiter** `_` this
        /// function placed as an open or close token — as opposed to a `_`
        /// that is part of a run's own (possibly escaped) text. Checked once
        /// at the end against the scanner's exact open/close rules.
        var italicOpenIndices: Set<Int> = []
        var italicCloseIndices: Set<Int> = []
        var openStack: [(key: String, valueJSON: String)] = []

        func append(_ token: String, italicRole: ItalicDelimiterRole? = nil) {
            switch italicRole {
            case .open: italicOpenIndices.insert(outputChars.count)
            case .close: italicCloseIndices.insert(outputChars.count)
            case nil: break
            }
            outputChars.append(contentsOf: token)
        }

        for (index, run) in runs.enumerated() {
            let nextIdentities = Set(run.marks.map(markIdentity))

            // A mark that must close forces closing every mark opened after
            // it too — markdown tokens nest strictly (LIFO), so an inner
            // token can never stay open while an outer one closes.
            var closeFrom = openStack.firstIndex(where: { !nextIdentities.contains(markIdentity($0)) })

            // `code`, once open, must stay the innermost element on the
            // stack for its *entire* open duration — not only at the moment
            // it opens. If it would otherwise survive this boundary
            // untouched (still in `nextIdentities`) but something new needs
            // to open here, that new mark would land nested *inside* the
            // still-open code span (new opens always append to the end of
            // the stack), which the "code sorts last" rule above already
            // established the grammar cannot express. Forcing code to close
            // here is safe — it simply reopens via `toOpen` below, since
            // it's still in `run.marks`.
            if let codeIndex = openStack.firstIndex(where: { $0.key == "code" }),
                closeFrom.map({ codeIndex < $0 }) ?? true
            {
                let survivingIdentities = Set(openStack.prefix(closeFrom ?? openStack.count).map(markIdentity))
                if run.marks.contains(where: { !survivingIdentities.contains(markIdentity($0)) }) {
                    closeFrom = min(closeFrom ?? openStack.count, codeIndex)
                }
            }

            if let closeFrom {
                for mark in openStack[closeFrom...].reversed() {
                    guard let token = closeToken(for: mark) else { return nil }
                    append(token, italicRole: mark.key == "italic" ? .close : nil)
                }
                openStack.removeSubrange(closeFrom...)
            }

            let openIdentities = Set(openStack.map(markIdentity))
            var seenIdentities = Set<String>()
            let toOpen =
                run.marks
                .filter { !openIdentities.contains(markIdentity($0)) }
                .filter { seenIdentities.insert(markIdentity($0)).inserted }
                .sorted { lhs, rhs in
                    // `code` is a hard innermost constraint, not merely a tie-
                    // break: a code span's content is always literal, so
                    // nothing can meaningfully sit *inside* one — placing
                    // code outside a sibling mark whose persistence happens
                    // to be shorter would require that sibling's tokens to
                    // open/close while still inside the backticks, which the
                    // grammar cannot express (they'd just become literal code
                    // text instead). Every other mark's placement is decided
                    // by "persists furthest", tie-broken by fixed priority.
                    let codeL = lhs.key == "code"
                    let codeR = rhs.key == "code"
                    if codeL != codeR { return codeR }
                    let persistenceL = persistenceLength(of: lhs, in: runs, from: index)
                    let persistenceR = persistenceLength(of: rhs, in: runs, from: index)
                    if persistenceL != persistenceR { return persistenceL > persistenceR }
                    return priority(of: lhs.key) < priority(of: rhs.key)
                }

            for mark in toOpen {
                append(openToken(for: mark), italicRole: mark.key == "italic" ? .open : nil)
                openStack.append(mark)
            }

            append(
                emitText(
                    run.text,
                    escapeAll: escapeAll,
                    insideCode: run.marks.contains { $0.key == "code" }
                ))
        }

        for mark in openStack.reversed() {
            guard let token = closeToken(for: mark) else { return nil }
            append(token, italicRole: mark.key == "italic" ? .close : nil)
        }

        // Every italic delimiter this function placed must actually function
        // as one: `isLoneUnderscore` (not immediately adjacent to *any*
        // other `_`, whether that neighbor is content or another delimiter —
        // e.g. a forced close-then-reopen at the same boundary would
        // otherwise land two `_` back to back with nothing between them) and
        // the matching open/close flanking rule. Unlike the open-ended
        // "italic run flush against unrelated prose" case Task 4's oracle is
        // responsible for, every character on both sides of a delimiter
        // *this function placed* is already fully known at this point —
        // checking is mechanical, not verification of the broader semantic
        // tree, so it happens here rather than being deferred.
        for position in italicOpenIndices {
            guard isLoneUnderscore(outputChars, at: position), canOpenUnderscore(outputChars, at: position) else {
                return nil
            }
        }
        for position in italicCloseIndices {
            guard isLoneUnderscore(outputChars, at: position), canCloseUnderscore(outputChars, at: position) else {
                return nil
            }
        }

        return String(outputChars)
    }

    /// Which role an italic `_` this function places is filling — needed
    /// because open and close are validated against different scanner rules
    /// (`canOpenUnderscore` vs `canCloseUnderscore`).
    private enum ItalicDelimiterRole {
        case open
        case close
    }

    /// Normalization applied before writing and before comparing:
    /// - expel leading/trailing whitespace from bold/italic/strike — never
    ///   code/link, which are never the *trigger* for expulsion — out to an
    ///   adjacent run that doesn't carry that mark. Mirrors
    ///   prosemirror-markdown's `expelEnclosingWhitespace`: `** word**` isn't
    ///   valid CommonMark emphasis (the opening `**` is blocked by the
    ///   following space per the flanking rule), so the whitespace has to
    ///   move outside the token. The expulsion looks at each mark's own
    ///   *maximal contiguous span* across runs, not at individual run
    ///   boundaries — whitespace in the interior of a still-continuing span
    ///   (e.g. between "bold " and "bi" when both carry `bold`) stays put.
    /// - coalesce adjacent runs left with identical mark sets;
    /// - drop runs left with no text.
    static func normalized(_ runs: [InlineRun]) -> [InlineRun] {
        var slots: [(character: Character, marks: [MarkKey])] = []
        for run in runs {
            let marks = run.marks.map { MarkKey(key: $0.key, valueJSON: $0.valueJSON) }
            for character in run.text {
                slots.append((character, marks))
            }
        }
        guard !slots.isEmpty else { return [] }

        for key in expellableMarkKeys {
            var i = 0
            while i < slots.count {
                guard slots[i].marks.contains(where: { $0.key == key }) else {
                    i += 1
                    continue
                }
                var j = i
                while j < slots.count, slots[j].marks.contains(where: { $0.key == key }) { j += 1 }

                var lead = i
                while lead < j, slots[lead].character.isWhitespace { lead += 1 }
                var trail = j
                while trail > lead, slots[trail - 1].character.isWhitespace { trail -= 1 }

                for k in i..<lead { slots[k].marks.removeAll { $0.key == key } }
                for k in trail..<j { slots[k].marks.removeAll { $0.key == key } }
                i = j
            }
        }

        var result: [InlineRun] = []
        var currentMarks: [MarkKey] = []
        var currentText = ""
        var hasCurrent = false

        func flush() {
            guard hasCurrent, !currentText.isEmpty else { return }
            result.append(InlineRun(currentText, marks: currentMarks.map { (key: $0.key, valueJSON: $0.valueJSON) }))
        }

        for slot in slots {
            let canonical = slot.marks.sorted { priority(of: $0.key) < priority(of: $1.key) }
            if hasCurrent, canonical == currentMarks {
                currentText.append(slot.character)
            } else {
                flush()
                currentMarks = canonical
                currentText = String(slot.character)
                hasCurrent = true
            }
        }
        flush()
        return result
    }

    /// Equivalence = same concatenated text + same mark set per character,
    /// order-insensitive, link marks compared by **href** rather than raw
    /// `valueJSON` — a round trip through `InlineMarkdown.parse` rebuilds the
    /// link value via its own `JSONSerialization` call, which need not be
    /// byte-identical to whatever JSON the input carried, only equivalent.
    static func runsEquivalent(_ a: [InlineRun], _ b: [InlineRun]) -> Bool {
        let flatA = flatten(a)
        let flatB = flatten(b)
        return flatA.text == flatB.text && flatA.marks == flatB.marks
    }

    // MARK: - isEscapable (mirrors the scanner)

    /// Mirrors `InlineMarkdown.swift`'s private `Scanner.isEscapable(_:)`
    /// character-for-character. That method is private, so the exact set is
    /// transcribed here rather than shared — keep the two lists in sync.
    /// `InlineMarkdownWriterTests.testEscapableCharactersMirrorTheScanner`
    /// is the tripwire: it round-trips every character in this set through
    /// the real scanner and fails the moment the two lists diverge.
    static let escapableCharacters: Set<Character> = Set("\\`*_{}[]()#+-.!~>|")

    // MARK: - Italic flanking (mirrors the scanner)

    /// Mirrors `InlineMarkdown.swift`'s private free functions
    /// `isMarkdownPunctuation`/`neighbor`/`isLeftFlanking`/`isRightFlanking`/
    /// `isLoneUnderscore`/`canOpenUnderscore`/`canCloseUnderscore`, character
    /// for character. Those are private, so transcribed here rather than
    /// shared. The three entry points actually used for validation
    /// (`isLoneUnderscore`/`canOpenUnderscore`/`canCloseUnderscore`) are
    /// internal rather than private so
    /// `InlineMarkdownWriterTests.testItalicFlankingMirrorsTheScanner` can
    /// call them directly and check representative neighbor combinations
    /// against the real scanner's actual parse output — the sync lock. Used
    /// only to validate a `_` delimiter *this file itself* is about to place
    /// (see `write`) — never to pre-judge arbitrary surrounding prose, which
    /// stays Task 4's job.
    private static let asciiPunctuation: Set<Character> = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

    private static func isMarkdownPunctuation(_ character: Character) -> Bool {
        character.isASCII ? asciiPunctuation.contains(character) : character.isPunctuation
    }

    private static func neighbor(_ chars: [Character], _ index: Int) -> Character? {
        chars.indices.contains(index) ? chars[index] : nil
    }

    private static func isLeftFlanking(_ chars: [Character], at index: Int) -> Bool {
        guard let next = neighbor(chars, index + 1), !next.isWhitespace else { return false }
        guard isMarkdownPunctuation(next) else { return true }
        guard let previous = neighbor(chars, index - 1) else { return true }
        return previous.isWhitespace || isMarkdownPunctuation(previous)
    }

    private static func isRightFlanking(_ chars: [Character], at index: Int) -> Bool {
        guard let previous = neighbor(chars, index - 1), !previous.isWhitespace else { return false }
        guard isMarkdownPunctuation(previous) else { return true }
        guard let next = neighbor(chars, index + 1) else { return true }
        return next.isWhitespace || isMarkdownPunctuation(next)
    }

    static func isLoneUnderscore(_ chars: [Character], at index: Int) -> Bool {
        chars[index] == "_" && neighbor(chars, index - 1) != "_" && neighbor(chars, index + 1) != "_"
    }

    static func canOpenUnderscore(_ chars: [Character], at index: Int) -> Bool {
        guard isLeftFlanking(chars, at: index) else { return false }
        guard isRightFlanking(chars, at: index) else { return true }
        return neighbor(chars, index - 1).map(isMarkdownPunctuation) ?? false
    }

    static func canCloseUnderscore(_ chars: [Character], at index: Int) -> Bool {
        guard isRightFlanking(chars, at: index) else { return false }
        guard isLeftFlanking(chars, at: index) else { return true }
        return neighbor(chars, index + 1).map(isMarkdownPunctuation) ?? false
    }

    // MARK: - Structural pre-checks

    /// The one thing normalization can hide: a code run with **empty** text
    /// contributes no characters to `normalized`'s character-flatten pass, so
    /// it silently disappears — a raw-runs check is the only place this is
    /// still visible. (Coalescing can't introduce a *non-empty* code run's
    /// backtick or shrink a link's href, so those are checked after
    /// normalization instead, where coalescing's *joins* are also visible —
    /// see `isNormalizedFormWritable`.)
    private static func hasNoEmptyCodeRun(_ runs: [InlineRun]) -> Bool {
        !runs.contains { $0.marks.contains(where: { $0.key == "code" }) && $0.text.isEmpty }
    }

    /// The remaining structurally-impossible cases, checked against the
    /// *normalized* runs so a coalescing join is covered too — e.g. two
    /// adjacent code runs neither containing `**` on its own can still join
    /// into one that does.
    private static func isNormalizedFormWritable(_ runs: [InlineRun], escapeAll: Bool) -> Bool {
        for run in runs {
            let keys = Set(run.marks.map { $0.key })

            if keys.contains("code") {
                if run.text.contains("`") { return false }
                // Code content is always verbatim (never escaped), so any
                // token it happens to contain is indistinguishable from a
                // real one to an *outer* mark's own closing search.
                // `matchUnderscoreEmphasis` explicitly steps over nested code
                // spans, so italic is safe; `matchDelimiter` (bold, strike)
                // and `matchLink`'s bracket search do not, so a code run
                // nested inside any of those must not contain the substring
                // that would end them early.
                if keys.contains("bold"), run.text.contains("**") { return false }
                if keys.contains("strike"), run.text.contains("~~") { return false }
                if keys.contains("link"), run.text.contains("]") { return false }
            }

            for mark in run.marks where mark.key == "link" {
                guard let href = extractHref(mark.valueJSON), isWritableHref(href) else { return false }
            }
            if !escapeAll, keys.contains("link"), !keys.contains("code"), run.text.contains("]") {
                // No spelling exists at this escapeAll setting: an unescaped
                // `]` always closes the label early, and verbatim mode never
                // escapes it. escapeAll: true fixes this via the ordinary
                // text-escaping path (`]` is in `escapableCharacters`) — the
                // `keys.contains("code")` case above is the one exception
                // that stays unwritable even then.
                return false
            }
        }
        return true
    }

    private static func isWritableHref(_ href: String) -> Bool {
        !href.isEmpty && !href.contains(where: { $0 == "(" || $0 == ")" || $0 == "\\" || $0.isWhitespace })
    }

    // MARK: - Emission helpers

    private static func openToken(for mark: (key: String, valueJSON: String)) -> String {
        switch mark.key {
        case "bold": return "**"
        case "italic": return "_"
        case "strike": return "~~"
        case "code": return "`"
        case "link": return "["
        default: return ""
        }
    }

    private static func closeToken(for mark: (key: String, valueJSON: String)) -> String? {
        switch mark.key {
        case "bold": return "**"
        case "italic": return "_"
        case "strike": return "~~"
        case "code": return "`"
        case "link":
            guard let href = extractHref(mark.valueJSON) else { return nil }
            return "](" + href + ")"
        default: return nil
        }
    }

    /// How many consecutive runs, starting at `start`, still carry a mark
    /// identical to `mark`. Drives the "open first the mark that persists
    /// furthest" tie-break when several marks open at the same boundary.
    private static func persistenceLength(
        of mark: (key: String, valueJSON: String),
        in runs: [InlineRun],
        from start: Int
    ) -> Int {
        let identity = markIdentity(mark)
        var count = 0
        var i = start
        while i < runs.count, runs[i].marks.contains(where: { markIdentity($0) == identity }) {
            count += 1
            i += 1
        }
        return count
    }

    /// Fixed opening priority (outer→inner) for marks opening together with
    /// equal persistence: link, bold, italic, strike, code — code always
    /// innermost, link always outermost.
    private static let markPriority: [String: Int] = [
        "link": 0,
        "bold": 1,
        "italic": 2,
        "strike": 3,
        "code": 4,
    ]

    private static func priority(of key: String) -> Int { markPriority[key] ?? Int.max }

    /// A mark's identity for stack/grouping purposes: link marks are
    /// distinguished by **href** (two link runs only continue the same link
    /// when their destinations match), everything else by key alone (the
    /// other four marks' `valueJSON` is always `"{}"`).
    private static func markIdentity(_ mark: (key: String, valueJSON: String)) -> String {
        if mark.key == "link" {
            return "link:" + (extractHref(mark.valueJSON) ?? mark.valueJSON)
        }
        return mark.key
    }

    private static func extractHref(_ valueJSON: String) -> String? {
        guard let data = valueJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let href = object["href"] as? String
        else { return nil }
        return href
    }

    private static func emitText(_ text: String, escapeAll: Bool, insideCode: Bool) -> String {
        // Code spans have no escape mechanism — content is always literal,
        // mirroring the scanner's own code-span handling.
        guard !insideCode, escapeAll else { return text }
        var output = ""
        output.reserveCapacity(text.count)
        for character in text {
            if escapableCharacters.contains(character) { output.append("\\") }
            output.append(character)
        }
        return output
    }

    private static func flatten(_ runs: [InlineRun]) -> (text: String, marks: [Set<String>]) {
        var text = ""
        var marks: [Set<String>] = []
        for run in runs {
            let identities = Set(run.marks.map(markIdentity))
            for character in run.text {
                text.append(character)
                marks.append(identities)
            }
        }
        return (text, marks)
    }

    /// The three mark types whose leading/trailing whitespace gets expelled
    /// during normalization. Code and link are never included: they are
    /// never the *trigger* for expulsion, even when they co-occur with one
    /// of these three on the same characters.
    private static let expellableMarkKeys: [String] = ["bold", "italic", "strike"]

    /// A hashable stand-in for `InlineRun`'s `(key: String, valueJSON:
    /// String)` mark tuples — plain tuples aren't `Equatable`/`Hashable` as
    /// array elements, so `normalized`'s character-level grouping needs a
    /// real type to key on.
    private struct MarkKey: Hashable {
        let key: String
        let valueJSON: String
    }
}
