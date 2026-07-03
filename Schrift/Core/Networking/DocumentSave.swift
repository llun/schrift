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
    func saveDocumentContent(documentID: UUID, title: String, markdown: String) async throws {
        let update = MarkdownYjs.encode(markdown: markdown)
        try await setContent(documentID: documentID, yjsUpdate: update)
        try await updateTitle(documentID: documentID, title: title)
    }
}
