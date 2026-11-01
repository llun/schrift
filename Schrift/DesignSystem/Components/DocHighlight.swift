import SwiftUI

/// The most terms of a query that are highlighted. A pasted paragraph would otherwise turn every
/// row into a scan for hundreds of needles.
let searchHighlightMaxTerms = 8

/// The ranges of `text` that match the whitespace-separated terms of `query`.
///
/// Matching is case- and diacritic-insensitive and uses `locale` for the folding ("I" and "ı" in
/// Turkish, for instance). Every occurrence of every term is found; ranges that overlap or touch
/// are merged, so the terms "hot" and "hotel" mark one run. A blank query, or one with no
/// match, gives an empty array. CJK works because a term is matched as a substring, not as a
/// whole word. Pure, so the Search rows and their tests share one rule.
func searchHighlightRanges(in text: String, query: String, locale: Locale = .current) -> [Range<String.Index>] {
    guard !text.isEmpty else { return [] }
    var seen = Set<String>()
    var terms: [String] = []
    for term in query.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
        let key = term.lowercased()
        guard seen.insert(key).inserted else { continue }
        terms.append(term)
        if terms.count == searchHighlightMaxTerms { break }
    }
    guard !terms.isEmpty else { return [] }

    var found: [Range<String.Index>] = []
    for term in terms {
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
            let range = text.range(
                of: term, options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<text.endIndex, locale: locale),
            !range.isEmpty
        {
            found.append(range)
            searchStart = range.upperBound
        }
    }
    return mergedSearchHighlightRanges(found)
}

/// Sorts ranges and joins any that overlap or touch.
func mergedSearchHighlightRanges(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
    var merged: [Range<String.Index>] = []
    for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
        if let last = merged.last, range.lowerBound <= last.upperBound {
            if range.upperBound > last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<range.upperBound
            }
        } else {
            merged.append(range)
        }
    }
    return merged
}

/// An excerpt trimmed so its first match is visible.
///
/// A row shows one line of the excerpt, so a match further in than `visibleLimit` characters is
/// cut off by the tail truncation and the row would show nothing to explain why it matched.
/// When that happens the excerpt starts about `leadingContext` characters before the match,
/// moved forward to a word boundary when there is one, and a leading ellipsis marks the cut.
/// An excerpt that fits, whose first match is already visible, or that has no match is returned
/// unchanged.
func searchExcerptWindow(
    _ excerpt: String, query: String, locale: Locale = .current,
    visibleLimit: Int = 40, leadingContext: Int = 12
) -> String {
    guard excerpt.count > visibleLimit,
        let first = searchHighlightRanges(in: excerpt, query: query, locale: locale).first
    else { return excerpt }
    let matchEnd = excerpt.distance(from: excerpt.startIndex, to: first.upperBound)
    guard matchEnd > visibleLimit else { return excerpt }

    let matchStart = excerpt.distance(from: excerpt.startIndex, to: first.lowerBound)
    var start = excerpt.index(excerpt.startIndex, offsetBy: max(0, matchStart - leadingContext))
    // Begin on a word: when the cut lands inside one (or on the space after one), skip ahead to
    // the next word, but never past the match itself.
    let cutInsideWord = start > excerpt.startIndex && !excerpt[excerpt.index(before: start)].isWhitespace
    if excerpt[start].isWhitespace || cutInsideWord,
        let gap = excerpt[start..<first.lowerBound].firstIndex(where: { $0.isWhitespace })
    {
        var next = excerpt.index(after: gap)
        while next < first.lowerBound, excerpt[next].isWhitespace { next = excerpt.index(after: next) }
        start = next
    }
    return "…" + String(excerpt[start...])
}

/// `text` with the matches of `query` drawn on `background`, in `foreground` and a semibold
/// `font`. Runs outside a match carry no attributes, so the surrounding `Text` styling applies
/// to them exactly as it would to a plain string.
func searchHighlightedString(
    _ text: String, query: String, locale: Locale = .current,
    font: Font, background: Color, foreground: Color
) -> AttributedString {
    var attributed = AttributedString(text)
    for range in searchHighlightRanges(in: text, query: query, locale: locale) {
        guard let target = Range<AttributedString.Index>(range, in: attributed) else { continue }
        attributed[target].backgroundColor = background
        attributed[target].foregroundColor = foreground
        attributed[target].font = font.weight(.semibold)
    }
    return attributed
}
