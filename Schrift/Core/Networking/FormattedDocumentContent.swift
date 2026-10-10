import Foundation

struct FormattedDocumentContent: Codable, Equatable, Sendable {
    let id: UUID
    let title: String?
    let content: String?
    let createdAt: Date
    let updatedAt: Date
}

/// One block of a document's BlockNote tree, as `formatted-content/?content_format=json`
/// returns it — reduced to the little the editor reads from it: the block's `type`, the two
/// props that identify a media leaf (`url`, and `showPreview`, which decides whether a docs
/// `pdf` block exports to markdown at all), and its `children`.
///
/// It exists for one reason: the markdown export flattens a photo or file nested under a list
/// item (`markdownRecoveringLeafNesting`), and this tree is where the nesting survives. It is
/// **read-only structure, never content** — nothing here is ever written back or rendered.
///
/// Decoded defensively, because the shape is a third-party library's and every field is
/// optional in practice: unknown fields (inline `content`, every other prop) are ignored, a
/// missing or mistyped `type`/`url`/`showPreview` decodes as absent, and missing `children`
/// as `[]`. Only a `children` that is present but not an array fails the whole decode, which
/// callers read as "no tree".
///
/// **Nesting is bounded** (`maxNestingDepth`). `children` nest arbitrarily, the decoder
/// recurses once per level, and the depth is whatever the server — or anything in front of
/// it — sends: the `Lib0Decoder.readAny` lesson, where depth is input, not structure. A deeper
/// tree throws instead (`.decoding` once `DocsAPIClient.send` wraps it); real documents nest a
/// few levels, and the editor itself never draws deeper than `maxListIndent`.
struct BlockNoteTreeNode: Decodable, Equatable, Sendable {
    /// The deepest `children` level decoded before the decode is refused.
    static let maxNestingDepth = 64

    let type: String
    let url: String?
    let showPreview: Bool?
    let children: [BlockNoteTreeNode]

    init(type: String, url: String? = nil, showPreview: Bool? = nil, children: [BlockNoteTreeNode] = []) {
        self.type = type
        self.url = url
        self.showPreview = showPreview
        self.children = children
    }

    private enum CodingKeys: String, CodingKey {
        case type, props, children
    }

    private enum PropKeys: String, CodingKey {
        case url, showPreview
    }

    init(from decoder: Decoder) throws {
        // Depth is counted from the coding path rather than threaded through `userInfo`, so
        // the shared `JSONDecoder.docsAPI` needs no per-call configuration: every level of
        // nesting adds exactly one `children` key to the path.
        let depth = decoder.codingPath.filter { $0.stringValue == CodingKeys.children.stringValue }.count
        guard depth < Self.maxNestingDepth else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "BlockNote tree nested deeper than \(Self.maxNestingDepth) levels"))
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? container.decodeIfPresent(String.self, forKey: .type)) ?? ""
        let props = try? container.nestedContainer(keyedBy: PropKeys.self, forKey: .props)
        url = try? props?.decodeIfPresent(String.self, forKey: .url)
        showPreview = try? props?.decodeIfPresent(Bool.self, forKey: .showPreview)
        children = try container.decodeIfPresent([BlockNoteTreeNode].self, forKey: .children) ?? []
    }
}

/// `formatted-content/?content_format=json`: the same envelope as the markdown read, with
/// `content` the document's top-level BlockNote blocks instead of a string.
struct FormattedDocumentTree: Decodable, Equatable, Sendable {
    /// The server's `updated_at` for this read, when it carries one — lets a caller tell
    /// whether the tree and a markdown read it pairs with describe the same write.
    let updatedAt: Date?
    let content: [BlockNoteTreeNode]

    init(updatedAt: Date?, content: [BlockNoteTreeNode]) {
        self.updatedAt = updatedAt
        self.content = content
    }

    private enum CodingKeys: String, CodingKey {
        case updatedAt, content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try? container.decodeIfPresent(Date.self, forKey: .updatedAt)
        // An empty document may answer `null`; a *string* here (a server that ignored the
        // format and sent markdown) is not a tree and fails the decode.
        content = try container.decodeIfPresent([BlockNoteTreeNode].self, forKey: .content) ?? []
    }
}

extension DocsAPIClient {
    /// Reads a document's content in `format` (markdown), tolerating both backend shapes.
    ///
    /// Current docs releases serve the markdown projection at
    /// `documents/{id}/formatted-content/?content_format=…`. Older ones have **no such
    /// route** — the request 404s with an HTML body — and expose the same
    /// `{id, title, content, created_at, updated_at}` payload at
    /// `documents/{id}/content/?content_format=…` instead.
    ///
    /// Because `DocsAPIErrorMapper` turns every 404 into `.notFound`, and the editor reads
    /// `.notFound` as "this document was deleted", a whole server's documents rendered as
    /// "This document is no longer available." So: try the modern route, and fall back only
    /// on `.notFound`. A **deleted** document 404s on both routes and still surfaces
    /// `.notFound`, which the editor's teardown path depends on; a 403 is revoked access,
    /// not a missing route, and must not retry.
    ///
    /// Falling back on a *server that has both routes* would be dangerous, not merely
    /// wasteful: `FormattedDocumentContent.content` is a plain `String?`, so a base64 Yjs
    /// body decodes into it silently, and the full-overwrite save would then push that blob
    /// back as the document's markdown. So the fallback is gated twice:
    ///
    /// 1. Only `.routeNotFound` (Django's HTML 404) qualifies — never `.notFound` (DRF's
    ///    JSON 404 for a missing object), and never `.forbidden`.
    /// 2. A reverse proxy can also answer HTML for a path it swallowed, on a server that
    ///    *does* have the route. So the route's absence is **confirmed** against a document
    ///    id that cannot exist, where a present route still answers DRF's JSON 404.
    ///
    /// Only then is `content/` assumed to hold markdown, and the answer memoized so a legacy
    /// server pays for the detection once per client rather than once per document.
    func formattedContent(documentID: UUID, format: String = "markdown") async throws -> FormattedDocumentContent {
        let id = documentID.uuidString.lowercased()
        let legacyPath = "documents/\(id)/content/?content_format=\(format)"
        if prefersLegacyContentRoute {
            return try await get(legacyPath)
        }

        do {
            return try await get(formattedContentPath(id, format))
        } catch DocsAPIError.routeNotFound {
            guard try await formattedContentRouteIsAbsent(format: format) else {
                // The route is there (or the probe couldn't prove otherwise), so that HTML
                // came from something in front of it. Rethrow `.routeNotFound`, never
                // `.notFound`: the latter is read everywhere as "this document was deleted",
                // and would tear the editor down and purge the cache over a proxy hiccup.
                throw DocsAPIError.routeNotFound
            }
            do {
                let content: FormattedDocumentContent = try await get(legacyPath)
                prefersLegacyContentRoute = true
                return content
            } catch DocsAPIError.notFound {
                // DRF's JSON 404: the legacy route *answered*, so it exists — this one
                // document is simply gone. Memoize anyway, or a first document that happens
                // to be deleted leaves every later load re-running the whole detection.
                prefersLegacyContentRoute = true
                throw DocsAPIError.notFound
            }
            // Anything else — including `.routeNotFound`, meaning neither route exists — leaves
            // the flag alone. Pinning it to a route that cannot answer would break every
            // content read for the rest of the client's life, with no way back but a relaunch.
        }
    }

    /// Reads a document's BlockNote block tree (`content_format=json`) — the structure the
    /// markdown export loses when it flattens a leaf nested under a list item.
    ///
    /// Best-effort by contract: the only caller (`EditorViewModel`'s leaf-nesting overlay)
    /// treats every failure as "no tree" and installs the markdown as it is. So this has none
    /// of `formattedContent`'s route detection. A server already known to lack
    /// `formatted-content/` (`prefersLegacyContentRoute`) answers `.routeNotFound` without a
    /// request rather than asking a route it has proven absent; the legacy `content/` route is
    /// never tried, because whether it speaks `content_format=json` is unknown and a guess
    /// costs nothing but the overlay.
    ///
    /// The same goes for a server that has answered *this* read with a missing route
    /// (`.routeNotFound`) or a `400` (a release whose `formatted-content/` validates
    /// `content_format` and has no `json`): `contentTreeUnsupported` is memoized, and every
    /// later call answers `.routeNotFound` without a request, so such a server does not pay a
    /// failing request on every content read. Nothing else memoizes — a JSON 404 is about the
    /// document, and a transport error, a 5xx or a `403` say nothing about the format.
    func formattedContentTree(documentID: UUID) async throws -> FormattedDocumentTree {
        if prefersLegacyContentRoute || contentTreeUnsupported { throw DocsAPIError.routeNotFound }
        do {
            return try await get(formattedContentPath(documentID.uuidString.lowercased(), "json"))
        } catch DocsAPIError.routeNotFound {
            contentTreeUnsupported = true
            throw DocsAPIError.routeNotFound
        } catch DocsAPIError.server(statusCode: 400) {
            contentTreeUnsupported = true
            throw DocsAPIError.server(statusCode: 400)
        }
    }

    private func formattedContentPath(_ id: String, _ format: String) -> String {
        "documents/\(id)/formatted-content/?content_format=\(format)"
    }

    /// Asks whether the route exists at all, using a document id no server can hold: a
    /// registered route answers DRF's JSON 404 for it (`.notFound`), an unregistered one
    /// answers Django's HTML 404 again (`.routeNotFound`).
    ///
    /// Only those two answers are conclusive. Anything else — `.forbidden` from an ACL that
    /// checks permission before existence, a 5xx, a decoding surprise — proves nothing, so it
    /// reports "not absent" rather than escaping: the probe's error is about a document the
    /// user never opened, and letting a probe `.forbidden` out would trip the editor's
    /// `.notFound || .forbidden` teardown and purge the cache for the document on screen.
    ///
    /// A transport failure is the one exception. It is about the connection, not the probe,
    /// so it applies equally to the request the caller actually made and is worth surfacing —
    /// "I couldn't ask" must never read as "it isn't there".
    private func formattedContentRouteIsAbsent(format: String) async throws -> Bool {
        let probeID = "00000000-0000-4000-8000-000000000000"
        do {
            let _: FormattedDocumentContent = try await get(formattedContentPath(probeID, format))
            return false
        } catch DocsAPIError.routeNotFound {
            return true
        } catch let error as DocsAPIError {
            if case .network = error { throw error }
            return false
        }
    }
}
