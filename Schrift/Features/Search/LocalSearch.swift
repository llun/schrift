import Foundation

// On-device search: the documents already cached on the phone, matched without a request.
//
// Everything here is pure value code, like `rankedPageLinkCandidates`: the entries are built
// from whatever the caller was able to vouch for (see `SearchViewModel.localSearchDocuments`),
// the matcher ranks them, and the merge combines them with the server's answer. None of it
// touches a store, so it runs off the main actor and is unit-tested without one.

/// The most documents the on-device search offers for one query.
let localSearchMaxResults = 50

/// The longest snippet of a document's text shown for a body-only match, in characters.
let localSearchSnippetMaxLength = 240

/// How many characters of a long matching line are kept before the match in a snippet.
let localSearchSnippetLeadingContext = 40

/// A cached document and the text of it kept on the device.
struct LocalSearchEntry: Sendable, Equatable {
    let document: Document
    /// The cached markdown body, nil when the document's content was never opened on this device.
    let body: String?
}

/// The entries to search: `documents` (already scoped to the signed-in account by the caller),
/// first copy of an id winning, each paired with its cached body when there is one.
///
/// A cached body is only ever attached to a document the caller listed. The content cache is not
/// stamped by account, so an entry for a document nobody vouched for is ignored rather than
/// searched.
func localSearchEntries(documents: [Document], contents: [CachedDocumentContent]) -> [LocalSearchEntry] {
    var bodies: [UUID: String] = [:]
    for content in contents { bodies[content.documentID] = content.markdown }
    var seen = Set<UUID>()
    var entries: [LocalSearchEntry] = []
    for document in documents where seen.insert(document.id).inserted {
        entries.append(LocalSearchEntry(document: document, body: bodies[document.id]))
    }
    return entries
}

/// The documents in `entries` that match `query`, best first, at most `limit`.
///
/// Matching is `searchHighlightRanges`' (case- and diacritic-insensitive, `locale`-aware,
/// substring based), so a row found here highlights exactly what matched. A document matches when
/// **every** term of the query appears somewhere in its title, excerpt or cached body. A document
/// whose title holds every term ranks above one that needed its text, then the most recently
/// updated leads, and the title and id break a tie so the order is stable.
///
/// A document found through its body alone, whose excerpt shows no match, comes back with that
/// excerpt replaced by the line of text that matched (`localSearchSnippet`), so the row shows
/// why it was found.
///
/// Checks for cancellation as it goes and gives up with an empty array, so a stale keystroke's
/// scan stops early; callers drop the result of a cancelled search.
func localSearchResults(
    query: String, entries: [LocalSearchEntry], locale: Locale = .current, limit: Int = localSearchMaxResults
) -> [Document] {
    let terms = searchQueryTerms(query)
    guard !terms.isEmpty, limit > 0 else { return [] }
    var seen = Set<UUID>()
    var ranked: [(rank: Int, document: Document)] = []
    for entry in entries {
        if Task.isCancelled { return [] }
        guard seen.insert(entry.document.id).inserted else { continue }
        let title = entry.document.title ?? ""
        let excerpt = entry.document.excerpt ?? ""
        var inTitle = true
        var matchesAll = true
        for term in terms {
            if searchTextContains(title, term: term, locale: locale) { continue }
            inTitle = false
            if searchTextContains(excerpt, term: term, locale: locale) { continue }
            if let body = entry.body, searchTextContains(body, term: term, locale: locale) { continue }
            matchesAll = false
            break
        }
        guard matchesAll else { continue }
        var document = entry.document
        if !inTitle, let body = entry.body,
            searchHighlightRanges(in: excerpt, query: query, locale: locale).isEmpty,
            let snippet = localSearchSnippet(body: body, query: query, locale: locale)
        {
            document.excerpt = snippet
        }
        ranked.append((rank: inTitle ? 0 : 1, document: document))
    }
    ranked.sort { lhs, rhs in
        if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
        if lhs.document.updatedAt != rhs.document.updatedAt { return lhs.document.updatedAt > rhs.document.updatedAt }
        let lhsTitle = (lhs.document.title ?? "").lowercased()
        let rhsTitle = (rhs.document.title ?? "").lowercased()
        if lhsTitle != rhsTitle { return lhsTitle < rhsTitle }
        return lhs.document.id.uuidString < rhs.document.id.uuidString
    }
    return ranked.prefix(limit).map { $0.document }
}

/// The line of `body` holding its first match for `query`, as a one-line excerpt: leading
/// markdown markers (`#`, `-`, `*`, `>`, `+`) and surrounding whitespace dropped, and capped at
/// `localSearchSnippetMaxLength` (a longer line starts shortly before its match).
/// nil when nothing in `body` matches, or the matching line is only markers.
func localSearchSnippet(body: String, query: String, locale: Locale = .current) -> String? {
    guard let match = searchHighlightRanges(in: body, query: query, locale: locale).first else { return nil }
    let lineRange = body.lineRange(for: match)
    var line = body[lineRange].trimmingCharacters(in: .whitespacesAndNewlines)
    // Markers are dropped only from the front, and only when the match is not among them.
    let markers: Set<Character> = ["#", ">", "-", "*", "+", " ", "\t"]
    let trimmed = String(line.drop(while: { markers.contains($0) }))
    if searchHighlightRanges(in: trimmed, query: query, locale: locale).first != nil { line = trimmed }
    guard !line.isEmpty else { return nil }
    // A line longer than the cap would cut its own match off, so it starts a little before the
    // match instead. A shorter one is left whole: the row windows its excerpt itself.
    if line.count > localSearchSnippetMaxLength,
        let first = searchHighlightRanges(in: line, query: query, locale: locale).first
    {
        let lead = line.distance(from: line.startIndex, to: first.lowerBound)
        if lead > localSearchSnippetLeadingContext {
            let start = line.index(line.startIndex, offsetBy: lead - localSearchSnippetLeadingContext)
            line = "…" + String(line[start...])
        }
    }
    return String(line.prefix(localSearchSnippetMaxLength))
}

/// What the Search results area shows: the server's rows in the server's order, then the
/// on-device matches the server did not return.
struct SearchResultSet: Equatable {
    var server: [Document] = []
    var localOnly: [Document] = []

    var all: [Document] { server + localOnly }
    var isEmpty: Bool { server.isEmpty && localOnly.isEmpty }
}

/// Merges the server's rows with the on-device matches.
///
/// A document both have is shown once, in the server's position — the server's copy is the
/// fresher one and its order is its relevance. Documents only the device found follow, still in
/// the device's ranking, to be labelled "On this device".
///
/// `serverIsCurrent` says whether `server` answers the query being shown. When it does not (the
/// user is still typing and the server has only answered an earlier query) and the device has
/// matches for the new one, the device's matches alone are shown: stale server rows would be a
/// different question's answer. With nothing on the device to show instead, the earlier rows
/// stay rather than leaving the list empty, as a refined query always has.
func mergeSearchResults(server: [Document], serverIsCurrent: Bool, local: [Document]) -> SearchResultSet {
    if !serverIsCurrent, !local.isEmpty { return SearchResultSet(server: [], localOnly: local) }
    let serverIDs = Set(server.map(\.id))
    return SearchResultSet(server: server, localOnly: local.filter { !serverIDs.contains($0.id) })
}
