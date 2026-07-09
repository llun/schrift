import Foundation

struct FormattedDocumentContent: Codable, Equatable, Sendable {
    let id: UUID
    let title: String?
    let content: String?
    let createdAt: Date
    let updatedAt: Date
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
