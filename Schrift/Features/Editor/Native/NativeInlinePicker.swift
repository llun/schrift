import Foundation

/// Maximum UTF-16 span scanned backward from the caret for an `@` mention opener.
let nativeInlineMentionMaxQueryLength = 64

/// Maximum rows offered by the native inline pickers (`[[` and `@`).
let nativeInlinePickerMaxResults = pageLinkMaxResults

/// An active inline-object search (`[[query`, slash-initiated page search, or
/// `@query`) detected in block-relative UTF-16 coordinates.
struct NativeInlineTrigger: Equatable, Sendable {
    enum Kind: Equatable, Hashable, Sendable {
        case pageLink
        case slashPageLink
        case mention
    }

    let kind: Kind
    /// Block-relative UTF-16 range (`anchor..<caret`) replaced on candidate commit.
    let range: Range<Int>
    /// Filter text after the opener (`[[`, `@`, or `slashSessionAnchor`).
    let query: String

    var anchor: Int { range.lowerBound }
}

/// Identifies one trigger instance in a block so Escape dismissal or silent
/// failure stays scoped to that opener.
struct InlineTriggerKey: Equatable, Hashable, Sendable {
    let blockID: String
    let kind: NativeInlineTrigger.Kind
    let anchor: Int
}

/// A mentionable user filtered from `GET /documents/{id}/accesses/`.
struct MentionCandidate: Equatable, Hashable, Identifiable, Sendable {
    let userID: String
    let fullName: String
    let shortName: String?
    let email: String?

    var id: String { userID }
}

/// State rendered by `NativeMentionPickerView`.
struct NativeMentionPickerState: Equatable, Sendable {
    let query: String
    let isLoading: Bool
    let matches: [MentionCandidate]
    /// Index into `matches`; 0 when empty or loading.
    let highlightedIndex: Int

    var highlighted: MentionCandidate? {
        guard !isLoading else { return nil }
        return matches.indices.contains(highlightedIndex) ? matches[highlightedIndex] : nil
    }
}

typealias NativeInlinePickerKey = PageLinkPickerKey

private let editableInlineBlockNodes: Set<String> = [
    "paragraph", "heading", "bulletListItem", "numberedListItem", "checkListItem",
    "quote", "callout", "toggleListItem", "tableParagraph",
]

/// Detects the active inline picker trigger at `caret` in `block`, respecting
/// inline-object (`\u{FFFC}`), `"code"`, `"link"`, and line-break barriers.
func nativeInlineTrigger(
    in block: BlockSnapshot,
    caret: Int,
    slashSessionAnchor: Int?,
    activeMarks: [TextMark] = []
) -> NativeInlineTrigger? {
    guard !block.isOpaque,
        editableInlineBlockNodes.contains(block.node),
        caret >= 0
    else { return nil }

    var units: [UInt16] = []
    var isBarrier: [Bool] = []
    var isInlineChip: [Bool] = []
    var totalLength = 0

    for run in block.runs {
        let count = run.text.utf16.count
        totalLength += count
        guard units.count < caret else { continue }
        let runHasBlockingMark = run.marks.contains { $0.key == "code" || $0.key == NativeMark.link }
        let runIsChip = run.inlineObject != nil
        for unit in run.text.utf16 {
            guard units.count < caret else { break }
            units.append(unit)
            let isHardSeparator = unit == 0xFFFC || unit == 0x000A || unit == 0x000D || unit == 0x2028
            isBarrier.append(runIsChip || runHasBlockingMark || isHardSeparator)
            isInlineChip.append(runIsChip)
        }
    }

    guard caret <= totalLength else { return nil }

    let hasBlockingActiveMark = activeMarks.contains {
        $0.key == "code" || $0.key == NativeMark.link
    }
    if hasBlockingActiveMark { return nil }

    var barrierEnd = 0
    if caret > 0 {
        var index = caret - 1
        while index >= 0 {
            if isBarrier[index] {
                barrierEnd = index + 1
                break
            }
            index -= 1
        }
    }

    if let anchor = slashSessionAnchor {
        guard anchor >= barrierEnd, anchor <= caret else { return nil }
        if anchor == caret {
            let typingHasBlockingMark = NativeMarkSelection.typing(block.runs, at: anchor).contains {
                $0.key == "code" || $0.key == NativeMark.link
            }
            guard !typingHasBlockingMark else { return nil }
        }
        let query = String(decoding: units[anchor..<caret], as: UTF16.self)
        return NativeInlineTrigger(kind: .slashPageLink, range: anchor..<caret, query: query)
    }

    let pageLinkMatch = detectPageLinkTrigger(units: units, caret: caret, barrierEnd: barrierEnd)
    let mentionMatch = detectMentionTrigger(
        units: units, isInlineChip: isInlineChip, caret: caret, barrierEnd: barrierEnd)

    switch (pageLinkMatch, mentionMatch) {
    case (.some(let page), .some(let mention)):
        return page.anchor >= mention.anchor ? page : mention
    case (.some(let page), .none):
        return page
    case (.none, .some(let mention)):
        return mention
    case (.none, .none):
        return nil
    }
}

/// Filters and deduplicates document accesses into mentionable candidates:
/// requires a user with an id, `(maxRole ?? role) != .reader`, and a non-empty
/// snapshot label (`fullName || shortName || email`).
func mentionCandidates(from accesses: [DocumentAccess]) -> [MentionCandidate] {
    var seen: Set<String> = []
    var candidates: [MentionCandidate] = []
    candidates.reserveCapacity(accesses.count)

    for access in accesses {
        guard (access.maxRole ?? access.role) != .reader,
            let user = access.user,
            let id = user.id
        else { continue }

        let userID = id.uuidString.lowercased()
        guard !seen.contains(userID) else { continue }

        let fullName = trimmedNonEmpty(user.fullName)
        let shortName = trimmedNonEmpty(user.shortName)
        let email = trimmedNonEmpty(user.email)
        guard let label = fullName ?? shortName ?? email else { continue }

        seen.insert(userID)
        candidates.append(
            MentionCandidate(
                userID: userID,
                fullName: label,
                shortName: shortName,
                email: email))
    }
    return candidates
}

/// Ranks mention candidates for `query` using case- and diacritic-insensitive
/// matching: full-name prefix first, word-prefix second, multi-word substring
/// match third, then sorted alphabetically by folded name and user ID.
func rankedMentionCandidates(
    query: String,
    candidates: [MentionCandidate],
    limit: Int = nativeInlinePickerMaxResults
) -> [MentionCandidate] {
    let folded = foldedForInlineMatch(query.trimmingCharacters(in: .whitespaces))
    let words = folded.split(whereSeparator: \.isWhitespace).map(String.init)
    var ranked: [(rank: Int, candidate: MentionCandidate, foldedName: String)] = []

    for candidate in candidates {
        let foldedName = foldedForInlineMatch(candidate.fullName)
        guard words.allSatisfy({ foldedName.contains($0) }) else { continue }
        let rank: Int
        if folded.isEmpty || foldedName.hasPrefix(folded) {
            rank = 0
        } else if foldedName.split(whereSeparator: \.isWhitespace).contains(where: { $0.hasPrefix(folded) }) {
            rank = 1
        } else {
            rank = 2
        }
        ranked.append((rank: rank, candidate: candidate, foldedName: foldedName))
    }

    ranked.sort { lhs, rhs in
        if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
        if lhs.foldedName != rhs.foldedName { return lhs.foldedName < rhs.foldedName }
        return lhs.candidate.userID < rhs.candidate.userID
    }
    return ranked.prefix(max(0, limit)).map(\.candidate)
}

/// First case- and diacritic-insensitive occurrence of the trimmed query in `name`,
/// used to emphasize matched characters in mention rows.
func mentionMatchRange(in name: String, query: String) -> Range<String.Index>? {
    pageLinkMatchRange(in: name, query: query)
}

/// Whether the visible inline picker claims `key` from the text view. Escape
/// always dismisses; Up and Down claim only when at least one row exists.
func inlinePickerClaims(_ key: NativeInlinePickerKey, matchCount: Int) -> Bool {
    pageLinkPickerClaims(key, matchCount: matchCount)
}

/// Moves the highlighted row index by `key`, wrapping at both ends.
func movedInlinePickerHighlight(_ index: Int, by key: NativeInlinePickerKey, count: Int) -> Int {
    movedPageLinkHighlight(index, by: key, count: count)
}

/// Runaway-prose auto-close: closes the picker once `query` contains
/// whitespace and the resolved candidate list is empty.
func shouldAutoCloseInlinePicker(query: String, matchCount: Int, isLoading: Bool = false) -> Bool {
    !isLoading && matchCount == 0 && query.contains(where: \.isWhitespace)
}

// MARK: - Private helpers

private func detectPageLinkTrigger(units: [UInt16], caret: Int, barrierEnd: Int) -> NativeInlineTrigger? {
    let openBracket = UInt16(UInt8(ascii: "["))
    let closeBracket = UInt16(UInt8(ascii: "]"))
    guard caret - barrierEnd >= 2 else { return nil }

    var index = caret - 1
    while index > barrierEnd {
        let unit = units[index]
        if unit == closeBracket, units[index - 1] == closeBracket {
            return nil
        }
        if unit == openBracket, units[index - 1] == openBracket {
            let anchor = index - 1
            let query = String(decoding: units[(anchor + 2)..<caret], as: UTF16.self)
            if let first = query.first, first.isWhitespace { return nil }
            return NativeInlineTrigger(kind: .pageLink, range: anchor..<caret, query: query)
        }
        index -= 1
    }
    return nil
}

private func detectMentionTrigger(
    units: [UInt16],
    isInlineChip: [Bool],
    caret: Int,
    barrierEnd: Int
) -> NativeInlineTrigger? {
    let atSign = UInt16(UInt8(ascii: "@"))
    let lowerBound = max(barrierEnd, caret - nativeInlineMentionMaxQueryLength)
    guard caret > lowerBound else { return nil }

    var index = caret - 1
    while index >= lowerBound {
        if units[index] == atSign {
            let anchor = index
            let validBoundary = anchor == 0 || isInlineChip[anchor - 1] || isUTF16Whitespace(units[anchor - 1])
            guard validBoundary else { return nil }
            let query = String(decoding: units[(anchor + 1)..<caret], as: UTF16.self)
            if let first = query.first, first.isWhitespace { return nil }
            return NativeInlineTrigger(kind: .mention, range: anchor..<caret, query: query)
        }
        index -= 1
    }
    return nil
}

private func isUTF16Whitespace(_ unit: UInt16) -> Bool {
    guard let scalar = UnicodeScalar(unit) else { return false }
    return Character(scalar).isWhitespace
}

private func trimmedNonEmpty(_ string: String?) -> String? {
    guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}

private func foldedForInlineMatch(_ string: String) -> String {
    string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
}
