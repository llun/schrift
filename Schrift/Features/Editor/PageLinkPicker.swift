import Foundation

// The `[[` page-link picker: typing `[[` in a block opens "Link a page" above the
// keyboard, and choosing a document replaces `[[query` with an ordinary markdown link
// to it — `[Title](https://<host>/docs/<uuid>/)`, the exact shape `isDocumentLink`
// recognises, so it draws as a page chip on both surfaces. Nothing about the result
// marks it as picker-made: it is the same link the link sheet would write by hand.
//
// Everything here is pure value code (no concurrency annotations), like the slash
// menu's filter: trigger detection, ranking and the link builder are unit-tested
// without UIKit, and the view model only wires them to its focused block and caret.

/// The longest query (UTF-16 units after `[[`) still treated as a search. Past it the
/// brackets are taken to be literal text the user moved on from, so a stray `[[` early
/// in a long paragraph does not reopen the picker for every word typed after it.
let pageLinkMaxQueryLength = 60

/// At most this many rows: the card sits above the keyboard and should not cover the
/// line being typed.
let pageLinkMaxResults = 6

/// A `[[` page-link search in progress in one block's markdown source.
struct PageLinkTrigger: Equatable {
    /// UTF-16 source range of `[[` plus the query — what choosing a page replaces.
    let range: NSRange
    /// What the user typed after `[[`, up to the caret.
    let query: String

    /// Where the `[[` starts. Identifies this search for dismissal: Escape hides the
    /// picker for *this* `[[`, and typing a new one elsewhere opens it again.
    var anchor: Int { range.location }
}

/// The `[[` search the caret is in, if any.
///
/// The caret must sit after a `[[` with nothing between them but the query. The query
/// may contain spaces (titles do) but not a bracket or a line break, must not *start*
/// with whitespace (`[[ ` reads as literal brackets), and stops being one past
/// `pageLinkMaxQueryLength`. A `[[` that is escaped (`\[[`), part of a longer run
/// (`[[[`), or inside an inline code span (an odd number of backticks before it) is
/// literal text and never triggers. So backspacing past the `[[`, typing `]`, or moving
/// the caret out of the query all end the search with no state of their own.
func pageLinkTrigger(in text: String, caret: Int) -> PageLinkTrigger? {
    let source = text as NSString
    guard caret >= 2, caret <= source.length else { return nil }
    let open = UInt16(UInt8(ascii: "["))
    let close = UInt16(UInt8(ascii: "]"))
    let backslash = UInt16(UInt8(ascii: "\\"))
    let backtick = UInt16(UInt8(ascii: "`"))
    let newline = UInt16(UInt8(ascii: "\n"))
    let carriageReturn = UInt16(UInt8(ascii: "\r"))

    // Walk back from the caret over the query to the nearest `[`.
    var index = caret - 1
    while index >= 0 {
        let unit = source.character(at: index)
        if unit == open { break }
        if unit == close || unit == newline || unit == carriageReturn { return nil }
        if caret - index > pageLinkMaxQueryLength { return nil }
        index -= 1
    }
    // `index` is the second `[`; the first must sit right before it.
    guard index >= 1, source.character(at: index - 1) == open else { return nil }
    let start = index - 1
    if start >= 1 {
        let before = source.character(at: start - 1)
        if before == open || before == backslash { return nil }
    }
    var backticks = 0
    for offset in 0..<start where source.character(at: offset) == backtick {
        backticks += 1
    }
    guard backticks.isMultiple(of: 2) else { return nil }

    let queryStart = start + 2
    let query = source.substring(with: NSRange(location: queryStart, length: caret - queryStart))
    if let first = query.first, first.isWhitespace { return nil }
    return PageLinkTrigger(range: NSRange(location: start, length: caret - start), query: query)
}

/// The documents the picker offers for `query`, best first, at most `limit`.
///
/// Matching folds case and diacritics (`resume` finds "Résumé"), and every
/// whitespace-separated word of the query must appear in the title. Titles that start
/// with the whole query rank first, then titles with a word starting with it, then any
/// other match; within a rank the most recently updated document leads, and the title
/// breaks a tie so the order is stable. An empty query offers the most recently updated.
///
/// Excluded: `currentDocumentID` (a page linking to itself), documents with no title
/// (there is nothing to match, and nothing to show as the link's text), and every
/// repeat of an id already offered — the sources overlap (a pinned document is usually
/// in recents too), and the first copy wins.
func rankedPageLinkCandidates(
    query: String, documents: [Document], excluding currentDocumentID: UUID, limit: Int = pageLinkMaxResults
) -> [Document] {
    let folded = foldedForPageLinkMatch(query.trimmingCharacters(in: .whitespaces))
    let words = folded.split(whereSeparator: \.isWhitespace).map(String.init)
    var seen: Set<UUID> = [currentDocumentID]
    var ranked: [(rank: Int, document: Document, title: String)] = []
    for document in documents {
        guard seen.insert(document.id).inserted else { continue }
        let title = pageLinkTitle(of: document)
        guard !title.isEmpty else { continue }
        let foldedTitle = foldedForPageLinkMatch(title)
        guard words.allSatisfy({ foldedTitle.contains($0) }) else { continue }
        let rank: Int
        if folded.isEmpty || foldedTitle.hasPrefix(folded) {
            rank = 0
        } else if foldedTitle.split(whereSeparator: \.isWhitespace).contains(where: { $0.hasPrefix(folded) }) {
            rank = 1
        } else {
            rank = 2
        }
        ranked.append((rank: rank, document: document, title: foldedTitle))
    }
    ranked.sort { lhs, rhs in
        if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
        if lhs.document.updatedAt != rhs.document.updatedAt { return lhs.document.updatedAt > rhs.document.updatedAt }
        return lhs.title < rhs.title
    }
    return ranked.prefix(max(0, limit)).map { $0.document }
}

/// A document's title as the picker shows it and the link carries it: trimmed, and
/// empty for an untitled document.
func pageLinkTitle(of document: Document) -> String {
    (document.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The part of `title` the query matched, for the row to emphasise — the first
/// case- and diacritic-insensitive occurrence of the trimmed query, nil when there is
/// none (an empty query, or a multi-word query whose words matched apart).
func pageLinkMatchRange(in title: String, query: String) -> Range<String.Index>? {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    return title.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive])
}

/// Replaces the trigger's `[[query` with a link to `document`. The caret lands right
/// after the link, so typing carries on outside it.
///
/// The URL is `documentShareURL` — the canonical `https://<host>/docs/<uuid>/`, lowercase
/// id and trailing slash, the form the server's markdown export writes and
/// `isDocumentLink` matches — and the label goes through `insertMarkdownLink`, which
/// escapes brackets and backslashes so any title round-trips. nil when there is no host
/// to point at, or the document has no title to show.
func pageLinkInsertion(
    in text: String, trigger: PageLinkTrigger, document: Document, serverHost: String
) -> MarkdownLinkEdit? {
    let title = pageLinkTitle(of: document)
    guard !serverHost.isEmpty, !title.isEmpty,
        let url = documentShareURL(serverHost: serverHost, documentID: document.id)
    else { return nil }
    guard NSMaxRange(trigger.range) <= (text as NSString).length else { return nil }
    return insertMarkdownLink(in: text, range: trigger.range, label: title, url: url.absoluteString)
}

/// Whether `text` still holds a `[[` at `location` — what keeps an Escape-dismissed
/// search dismissed. Once those brackets are gone (backspaced, or replaced), the dismissal
/// lapses, so typing `[[` again opens the picker even at the same offset.
func hasPageLinkOpener(in text: String, at location: Int) -> Bool {
    let source = text as NSString
    guard location >= 0, location + 2 <= source.length else { return false }
    return source.substring(with: NSRange(location: location, length: 2)) == "[["
}

/// One `[[` search: the block it is in and where its `[[` starts.
struct PageLinkSessionKey: Equatable {
    let blockID: UUID
    let anchor: Int
}

/// The row an arrow key moved to, valid only for the search and query it was moved in.
struct PageLinkHighlight: Equatable {
    let key: PageLinkSessionKey
    let query: String
    let index: Int
}

/// The cached documents one search ranks — see `EditorViewModel.pageLinkPicker`.
struct PageLinkCandidateMemo {
    let key: PageLinkSessionKey
    let documents: [Document]
}

/// A hardware-keyboard key the picker handles while it is up.
enum PageLinkPickerKey: Equatable, Sendable {
    case up
    case down
    case escape
}

/// What the picker card shows: the rows for the current query and which one Return
/// (or a hardware arrow key) acts on.
struct PageLinkPickerState: Equatable {
    let query: String
    let matches: [Document]
    /// Index into `matches`; 0 when there are none.
    let highlightedIndex: Int

    var highlighted: Document? {
        matches.indices.contains(highlightedIndex) ? matches[highlightedIndex] : nil
    }
}

/// Whether the visible picker claims `key` from the text view. Escape always closes the card;
/// Up and Down only have a row to move to when there are matches, and otherwise keep moving
/// the caret between lines.
func pageLinkPickerClaims(_ key: PageLinkPickerKey, matchCount: Int) -> Bool {
    switch key {
    case .escape: return true
    case .up, .down: return matchCount > 0
    }
}

/// The highlighted row after an arrow key, wrapping at both ends like a menu.
func movedPageLinkHighlight(_ index: Int, by key: PageLinkPickerKey, count: Int) -> Int {
    guard count > 0 else { return 0 }
    let current = min(max(0, index), count - 1)
    switch key {
    case .up: return (current - 1 + count) % count
    case .down: return (current + 1) % count
    case .escape: return current
    }
}

private func foldedForPageLinkMatch(_ string: String) -> String {
    string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
}
