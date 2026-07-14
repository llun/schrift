import Foundation

/// The content PATCH of a save **landed**, but the title PATCH that follows it did not.
/// The server therefore already holds this save's body: the caller must record the push
/// (so a later replay recognises its own write instead of raising a conflict against the
/// user's own text) while still treating the save as failed and classifying retryability
/// from `underlying`.
struct DocumentTitleSaveFailed: Error {
    let underlying: Error
}

extension DocsAPIClient {
    /// Creates a new, empty document. The docs backend creates documents from a
    /// JSON body (`{"title": …}`); the multipart file-upload path is gated behind
    /// a server setting (`CONVERSION_UPLOAD_ENABLED`) that is off on the target
    /// deployment, so it is not used.
    func createDocument(title: String) async throws -> Document {
        let body = try JSONEncoder().encode(["title": title])
        return try await send(path: "documents/", method: "POST", body: body)
    }

    /// Replaces a document's content. The backend stores content as base64-encoded
    /// Yjs and validates it, so `yjsUpdate` must be a real Yjs update.
    func setContent(documentID: UUID, yjsUpdate: Data) async throws {
        let body = try JSONEncoder().encode(["content": yjsUpdate.base64EncodedString()])
        try await sendVoid(
            path: "documents/\(documentID.uuidString.lowercased())/content/", method: "PATCH", body: body)
    }

    /// Persists a document's title.
    func updateTitle(documentID: UUID, title: String) async throws {
        let body = try JSONEncoder().encode(["title": title])
        try await sendVoid(path: "documents/\(documentID.uuidString.lowercased())/", method: "PATCH", body: body)
    }

    func deleteDocument(documentID: UUID) async throws {
        try await sendVoid(path: "documents/\(documentID.uuidString.lowercased())/", method: "DELETE", body: nil)
    }

    /// Full-overwrite save of a document's title and content. The editor's
    /// markdown is converted to a Yjs update on-device (`MarkdownYjs`) and PATCHed
    /// to the content endpoint — the docs backend only accepts base64 Yjs there
    /// and offers no markdown-to-Yjs conversion a client session can call.
    ///
    /// **A save is two requests, so it can half-land**, and the caller must be able to
    /// tell: if the connection drops between them — precisely the flaky-network case the
    /// offline stack exists for — the server already holds the new body (with a bumped
    /// `updated_at`) while this call throws. A caller that sees only "it threw" does not
    /// know it authored the server's current content, so its next replay compares its own
    /// write against a stale baseline and raises a **sync conflict against the user's own
    /// text**. `DocumentTitleSaveFailed` carries that fact out through the `throw`.
    func saveDocumentContent(documentID: UUID, title: String, markdown: String) async throws {
        let update = MarkdownYjs.encode(markdown: markdown)
        try await setContent(documentID: documentID, yjsUpdate: update)
        do {
            try await updateTitle(documentID: documentID, title: title)
        } catch {
            throw DocumentTitleSaveFailed(underlying: error)
        }
    }
}
