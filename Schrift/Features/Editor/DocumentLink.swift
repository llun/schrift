import Foundation

/// What the reading surface should do with a link tapped in document content.
enum DocumentLinkAction: Equatable {
    /// A link to another document on this server: open it in the app.
    case openInApp(UUID)
    /// A link to the document already on screen. Swallow the tap rather than stack a
    /// second copy of it — `NavigationPath.append` does not de-duplicate, so a document
    /// that links to itself (or a chain of them) would grow the stack without bound.
    case alreadyOpen
    /// Anything else. Hand it to the system exactly as before this classification existed.
    case openInBrowser
}

/// Classifies a link tapped in document content.
///
/// Documents are linked as ordinary absolute markdown links to the web app's own page —
/// `[Title](https://<serverHost>/docs/<uuid>/)`, the inverse of `documentShareURL` — so
/// nothing in the markdown marks them as internal. (The web editor stores them as a
/// custom `interlinkingLinkInline` node, but the server's markdown export flattens that
/// to a plain link.) Recognising the shape here is what keeps a sub-page link in the app
/// instead of handing it to Safari.
///
/// The URL is authored by whoever can write the document, so the match is deliberately
/// narrow. A URL is a document link only when all of the following hold:
///
/// * the scheme is `http` or `https` — never `javascript:`, `data:` or `file:`;
/// * the host equals `serverHost` **exactly**. Case-insensitively, because hostnames are
///   and `String ==` is not; and against `URL.host` rather than the string, because
///   `https://docs.llun.dev@evil.com/…` is hosted at `evil.com` and
///   `docs.llun.dev.evil.com` must not pass as a suffix;
/// * the path is exactly `/docs/<uuid>`. `URL.pathComponents` folds a trailing slash away,
///   so both spellings of the canonical link match, while `/docs/<uuid>/versions/1` and
///   `/docs/new/` do not.
///
/// Everything unmatched falls through to `.openInBrowser`, so external links behave exactly
/// as they did before. The scheme and host checks are not a fetch guard — the extracted id
/// is only ever used against the client's own `documents/{id}/` path, and the port is not
/// compared because `serverHost` carries none — they exist so the app never *intercepts* a
/// link that belongs to somebody else's site.
func documentLinkAction(for url: URL, serverHost: String, currentDocumentID: UUID) -> DocumentLinkAction {
    guard let linkedID = linkedDocumentID(from: url, serverHost: serverHost) else { return .openInBrowser }
    return linkedID == currentDocumentID ? .alreadyOpen : .openInApp(linkedID)
}

private func linkedDocumentID(from url: URL, serverHost: String) -> UUID? {
    // `URL.host` is "" for a `file:` URL, and RootView falls back to "" when the server
    // URL somehow has no host; without this an empty host would match an empty serverHost.
    guard !serverHost.isEmpty,
        let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
        let host = url.host, host.caseInsensitiveCompare(serverHost) == .orderedSame
    else { return nil }

    // ["/", "docs", "<uuid>"] — anything longer is a different page on the server.
    let segments = url.pathComponents
    guard segments.count == 3, segments[1] == "docs" else { return nil }
    return UUID(uuidString: segments[2])
}
