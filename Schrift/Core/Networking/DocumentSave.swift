import Foundation

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
    /// **A save is two requests, so it can half-land**, and the caller must be able to tell
    /// which. If the connection drops between them — precisely the flaky-network case the
    /// offline stack exists for — the server already holds the new body (with a bumped
    /// `updated_at`) even though the save failed. A caller that only learns "it failed" does
    /// not know it authored the server's current content, so its next replay compares its own
    /// write against a stale baseline and raises a **sync conflict against the user's own
    /// text**. Hence the split return:
    ///
    /// - **throws** ⇒ the *content* PATCH failed, so nothing reached the server;
    /// - **returns non-nil** ⇒ the content landed and only the *title* PATCH failed;
    /// - **returns nil** ⇒ both landed.
    ///
    /// Reporting the half-land as a return value rather than a second thrown type keeps
    /// `DocsAPIError` the one error type crossing this layer (see CLAUDE.md, Networking).
    @discardableResult
    func saveDocumentContent(documentID: UUID, title: String, markdown: String) async throws -> Error? {
        let update = MarkdownYjs.encode(markdown: markdown)
        try await setContent(documentID: documentID, yjsUpdate: update)
        do {
            try await updateTitle(documentID: documentID, title: title)
            return nil
        } catch {
            return error
        }
    }
}
