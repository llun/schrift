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
                // The route exists; something in front of it produced that HTML. Report the
                // 404 we actually got rather than reading a different endpoint.
                throw DocsAPIError.notFound
            }
            let content: FormattedDocumentContent = try await get(legacyPath)
            prefersLegacyContentRoute = true
            return content
        }
    }

    private func formattedContentPath(_ id: String, _ format: String) -> String {
        "documents/\(id)/formatted-content/?content_format=\(format)"
    }

    /// A document id no server can hold. A registered route answers DRF's JSON 404 for it
    /// (`.notFound`); an unregistered one answers Django's HTML 404 again (`.routeNotFound`).
    /// Transport failures propagate — "I couldn't ask" must never read as "it isn't there".
    private func formattedContentRouteIsAbsent(format: String) async throws -> Bool {
        let probeID = "00000000-0000-4000-8000-000000000000"
        do {
            let _: FormattedDocumentContent = try await get(formattedContentPath(probeID, format))
            return false
        } catch DocsAPIError.routeNotFound {
            return true
        } catch DocsAPIError.notFound {
            return false
        }
    }
}
