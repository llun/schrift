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

/// An excerpt trimmed so its first match sits near the start of the line.
///
/// A row shows one or two lines of the excerpt and how many characters fit depends on Dynamic
/// Type, the script (CJK glyphs are about twice as wide) and the device, so no character budget
/// can say whether a match is in sight. Instead the excerpt is windowed whenever its first match
/// starts beyond `leadingContext` characters: it then starts about `leadingContext` characters
/// before the match, moved forward to a word boundary when that leaves at least half the context,
/// and a leading ellipsis marks the cut. When the boundary is too close to the match and the cut
/// word begins the excerpt, the excerpt is returned unchanged. An excerpt whose first match is
/// within the leading context, or that has no match, is returned unchanged.
func searchExcerptWindow(
    _ excerpt: String, query: String, locale: Locale = .current, leadingContext: Int = 12
) -> String {
    guard let first = searchHighlightRanges(in: excerpt, query: query, locale: locale).first else { return excerpt }
    let matchStart = excerpt.distance(from: excerpt.startIndex, to: first.lowerBound)
    guard matchStart > leadingContext else { return excerpt }
    var start = excerpt.index(excerpt.startIndex, offsetBy: max(0, matchStart - leadingContext))
    // Begin on a word: when the cut lands inside one (or on the space after one), skip ahead to
    // the next word, but never past the match itself.
    let cutInsideWord = start > excerpt.startIndex && !excerpt[excerpt.index(before: start)].isWhitespace
    if excerpt[start].isWhitespace || cutInsideWord {
        var forward: String.Index?
        if let gap = excerpt[start..<first.lowerBound].firstIndex(where: { $0.isWhitespace }) {
            var next = excerpt.index(after: gap)
            while next < first.lowerBound, excerpt[next].isWhitespace { next = excerpt.index(after: next) }
            forward = next
        }
        if let forward, excerpt.distance(from: forward, to: first.lowerBound) >= leadingContext / 2 {
            start = forward
        } else if forward != nil {
            // Skipping ahead would leave (almost) no context before the match. Look at the word the
            // cut is in instead: when it begins the excerpt there is nothing to trim, so return the
            // excerpt as is; otherwise keep the mid-word cut.
            var wordStart = start
            if excerpt[wordStart].isWhitespace, wordStart > excerpt.startIndex,
                !excerpt[excerpt.index(before: wordStart)].isWhitespace
            {
                wordStart = excerpt.index(before: wordStart)
            }
            while wordStart > excerpt.startIndex, !excerpt[excerpt.index(before: wordStart)].isWhitespace {
                wordStart = excerpt.index(before: wordStart)
            }
            if wordStart == excerpt.startIndex { return excerpt }
        }
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
        // Keyed explicitly: the bare `.backgroundColor` / `.font` names also exist in the UIKit
        // and AppKit scopes, so the SwiftUI keys are named to keep the lookup unambiguous.
        attributed[target][AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = background
        attributed[target][AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = foreground
        attributed[target][AttributeScopes.SwiftUIAttributes.FontAttribute.self] = font.weight(.semibold)
    }
    return attributed
}
