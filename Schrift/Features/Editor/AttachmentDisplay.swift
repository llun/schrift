import Foundation

/// An uploaded file attachment a document links to, recognised in the markdown
/// the server exports.
///
/// The web editor stores an attachment as a BlockNote `file` block (a download
/// chip) or as docs' own `pdf` block; the server's markdown export flattens both
/// to a standalone `[name](url)` line, indistinguishable from a link the user
/// typed. Nothing in the markdown marks it as an attachment — only the URL shape
/// does, and only the server's own storage layout gives that shape meaning:
/// `{origin}/media/{document-uuid}/attachments/{file-uuid}(-unsafe)?.{ext}`
/// (the backend's `MEDIA_STORAGE_URL_PATTERN`).
///
/// `urlString` is the author's byte-for-byte spelling and must stay so — the
/// backend's `extract_attachments()` matches the embedded url exactly, and a
/// full-overwrite save re-serializes whatever we hold.
struct AttachmentDisplay: Equatable, Sendable {
    /// The markdown link label. May legitimately be empty (`[](url)`), which is
    /// what a `file` block with no `name` exports.
    let name: String
    /// The url exactly as authored — never re-normalized through `URL`.
    let urlString: String
    let url: URL
    /// The owning document's id, as spelled in the path.
    let documentUUID: String
    /// The attachment's own id, as spelled in the path.
    let fileUUID: String
    /// The server stored this under an `-unsafe` key: its declared extension and
    /// its sniffed bytes disagreed, or its mime type is on the blocklist (a
    /// `.docx` sniffing as `zip` is the routine case). Only the server's
    /// `Content-Disposition` differs; the bytes download and preview normally.
    let isUnsafeKey: Bool
    /// Lowercase-preserved as authored; validated ASCII-alphanumeric.
    let fileExtension: String
}

// MARK: - Classification

/// The whole of `text` is a single markdown link pointing at an attachment
/// uploaded to the user's own server, or nil.
///
/// Deliberately conservative in the same way `parseImageLine` is — anything
/// ambiguous declines and renders as ordinary link text, which is lossless.
/// Three independent gates must all pass:
///
/// 1. **Shape**: the trimmed text is exactly `[label](url)` with nothing before
///    or after it. A `]` or `[` in the label, whitespace or unbalanced parens in
///    the url, or a second link on the line all decline.
/// 2. **Origin**: `siteOrigin(for: url) == serverOrigin`, the same true origin
///    comparison `imageLoadPolicy` makes (scheme + host + port, host read via
///    `URL.host` so `https://origin@evil.com/x` and `origin.evil.com` cannot
///    pass). Fail-closed on an empty `serverOrigin`. This is what makes the
///    auto-download safe without a consent flow: an off-origin url is never an
///    attachment, so no request is ever issued for one.
/// 3. **Path**: the decoded path is *exactly* the server's storage layout —
///    five components, two of them UUIDs, and an ASCII-alphanumeric extension.
///    Because `URL.pathComponents` percent-decodes, a `%2e%2e` traversal or an
///    encoded separator decodes into extra or non-UUID components and is
///    rejected there, so nothing that reaches the cache's file naming can be
///    anything but a UUID and an extension. Re-composing the path from those
///    parts must then reproduce the url's own decoded path, which is what
///    additionally rejects a trailing slash or a doubled separator.
///    Percent-encoding that decodes to the same path is accepted and
///    canonicalized — provably harmless, since every part has been validated.
func parseAttachmentLink(_ text: String, serverOrigin: String) -> AttachmentDisplay? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("["), trimmed.hasSuffix(")") else { return nil }
    guard let separator = trimmed.range(of: "](") else { return nil }

    let name = String(trimmed[trimmed.index(after: trimmed.startIndex)..<separator.lowerBound])
    let urlString = String(trimmed[separator.upperBound..<trimmed.index(before: trimmed.endIndex)])
    // A bracket in the label would mean the `](` we split on isn't the link's
    // own separator (`[a[b](url)` is not a link at all in CommonMark).
    guard !name.contains("]"), !name.contains("["), !urlString.isEmpty else { return nil }
    // Two links on one line (`[a](u1)[b](u2)`) leave an unbalanced `)` in what
    // we took for the url; a space leaves trailing prose. Either way, decline.
    guard !urlString.contains(where: \.isWhitespace), hasBalancedAttachmentParentheses(urlString) else { return nil }

    guard !serverOrigin.isEmpty, let url = URL(string: urlString), siteOrigin(for: url) == serverOrigin else {
        return nil
    }
    guard let parts = attachmentPathParts(of: url) else { return nil }

    return AttachmentDisplay(
        name: name,
        urlString: urlString,
        url: url,
        documentUUID: parts.documentUUID,
        fileUUID: parts.fileUUID,
        isUnsafeKey: parts.isUnsafeKey,
        fileExtension: parts.fileExtension)
}

/// The attachment a block displays as a card, or nil for every other block.
///
/// Scoped to `.paragraph` because that is the only kind a standalone
/// `[name](url)` line parses into today: `parseClassifiedLine` has no link arm,
/// so `flushPending`'s single-line branch mints it. A multi-line run (an
/// attachment line adjacent to prose, with no blank line between) is one
/// `.unknown` block and deliberately does not classify — it is not a standalone
/// link, and treating part of an `.unknown` block's verbatim text as a card
/// would misrepresent what a save would write back.
func attachmentDisplay(for block: EditorBlock, serverOrigin: String) -> AttachmentDisplay? {
    guard case .paragraph = block.kind else { return nil }
    return parseAttachmentLink(block.text, serverOrigin: serverOrigin)
}

// MARK: - Derived values

/// The rooted `/media/…` path to download the attachment's bytes from, or nil
/// when it does not belong to `serverOrigin`.
///
/// Re-derived from the validated path parts rather than sliced out of the
/// authored url, so nothing author-controlled reaches the request path: every
/// component here has been proven to be a UUID, the literal `attachments`, or an
/// ASCII-alphanumeric extension. The result always satisfies `isSameOriginPath`,
/// which `DocsAPIClient.mediaData(path:)` re-checks before issuing the request.
///
/// The origin is re-tested rather than assumed: an `AttachmentDisplay` is
/// `Equatable` and freely constructible, so this stays correct if one is ever
/// built by hand or carried across a session change.
func attachmentMediaPath(for display: AttachmentDisplay, serverOrigin: String) -> String? {
    guard !serverOrigin.isEmpty, siteOrigin(for: display.url) == serverOrigin else { return nil }
    return canonicalAttachmentPath(
        documentUUID: display.documentUUID, fileName: attachmentFileName(for: display))
}

/// The attachment's on-server file name (`{uuid}[-unsafe].{ext}`) — also its
/// cache file name. Built from validated parts, never from `display.name`, so an
/// author-chosen label can never influence a path.
func attachmentFileName(for display: AttachmentDisplay) -> String {
    "\(display.fileUUID)\(display.isUnsafeKey ? "-unsafe" : "").\(display.fileExtension)"
}

/// What to show as the attachment's title. An empty label is legitimate (a
/// `file` block whose `name` was never set), and the server's own file name is
/// the only other thing that identifies it — the same fallback the web editor
/// makes when it renders `name || url`, just shorter.
func attachmentDisplayTitle(_ display: AttachmentDisplay) -> String {
    display.name.isEmpty ? attachmentFileName(for: display) : display.name
}

// MARK: - Private

private func canonicalAttachmentPath(documentUUID: String, fileName: String) -> String {
    "/media/\(documentUUID)/attachments/\(fileName)"
}

private func attachmentPathParts(
    of url: URL
) -> (documentUUID: String, fileUUID: String, isUnsafeKey: Bool, fileExtension: String)? {
    // A query or fragment means this isn't the plain storage url the server's
    // `$`-anchored pattern matches.
    guard url.query == nil, url.fragment == nil else { return nil }

    let components = url.pathComponents
    guard components.count == 5, components[0] == "/", components[1] == "media", components[3] == "attachments" else {
        return nil
    }
    let documentUUID = components[2]
    let fileName = components[4]
    guard UUID(uuidString: documentUUID) != nil else { return nil }

    guard let dot = fileName.lastIndex(of: ".") else { return nil }
    let fileExtension = String(fileName[fileName.index(after: dot)...])
    guard (1...10).contains(fileExtension.count),
        fileExtension.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
    else { return nil }

    var base = String(fileName[fileName.startIndex..<dot])
    let isUnsafeKey = base.hasSuffix("-unsafe")
    if isUnsafeKey { base.removeLast("-unsafe".count) }
    guard UUID(uuidString: base) != nil else { return nil }

    // `pathComponents` drops a trailing slash and collapses doubled separators,
    // so the component checks alone would accept paths the server's own
    // `$`-anchored pattern does not. Requiring the re-composed path to equal the
    // url's decoded path closes that gap.
    guard url.path(percentEncoded: false) == canonicalAttachmentPath(documentUUID: documentUUID, fileName: fileName)
    else { return nil }

    return (documentUUID, base, isUnsafeKey, fileExtension)
}

/// The url's parentheses must balance, for the same reason
/// `parseImageLine` checks: the closing `)` is taken to be the line's last
/// character, but CommonMark ends the destination at the first *unbalanced* one.
private func hasBalancedAttachmentParentheses(_ text: String) -> Bool {
    var depth = 0
    for character in text {
        if character == "(" {
            depth += 1
        } else if character == ")" {
            depth -= 1
            if depth < 0 { return false }
        }
    }
    return depth == 0
}
