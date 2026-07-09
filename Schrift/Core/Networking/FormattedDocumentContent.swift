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
    /// Note the fallback is only reachable via the *modern* route first, so a server that
    /// has both keeps its existing behavior — `content/`'s payload is only assumed to be
    /// markdown on a server that has already proved it lacks `formatted-content/`.
    func formattedContent(documentID: UUID, format: String = "markdown") async throws -> FormattedDocumentContent {
        let id = documentID.uuidString.lowercased()
        let legacyPath = "documents/\(id)/content/?content_format=\(format)"
        if prefersLegacyContentRoute {
            return try await get(legacyPath)
        }

        do {
            return try await get("documents/\(id)/formatted-content/?content_format=\(format)")
        } catch DocsAPIError.notFound {
            let content: FormattedDocumentContent = try await get(legacyPath)
            // Only now is the route's absence proven: a deleted document would have 404ed
            // here too and rethrown, leaving the flag untouched.
            prefersLegacyContentRoute = true
            return content
        }
    }
}
