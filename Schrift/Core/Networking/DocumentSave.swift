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
    ///
    /// `viaWebSocket` tags the PATCH body with `"websocket": true`, which the docs
    /// backend uses to distinguish a **live-collaboration snapshot** (the current full
    /// CRDT state pushed while a Hocuspocus room is joined) from a classic REST
    /// full-overwrite. It defaults to `false`, and when false the body is byte-identical
    /// to what it has always been (`{"content":"<base64>"}` via `JSONEncoder`), so every
    /// existing caller and golden expectation is unchanged.
    func setContent(documentID: UUID, yjsUpdate: Data, viaWebSocket: Bool = false) async throws {
        let body: Data
        if viaWebSocket {
            // Mixed value types (String content + Bool flag) ⇒ JSONSerialization, not a
            // `[String: String]` JSONEncoder. Only app-authored keys/values here.
            body = try JSONSerialization.data(
                withJSONObject: ["content": yjsUpdate.base64EncodedString(), "websocket": true])
        } else {
            body = try JSONEncoder().encode(["content": yjsUpdate.base64EncodedString()])
        }
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
    /// - **throws** ⇒ the *content* PATCH was not **confirmed**;
    /// - **returns non-nil** ⇒ the content landed and only the *title* PATCH failed;
    /// - **returns nil** ⇒ both landed.
    ///
    /// Note the throw case says *unconfirmed*, not "nothing reached the server": a dropped or
    /// timed-out response can hide a content PATCH the server actually applied, and that is
    /// precisely the flaky case this exists for. So the throw cannot be trusted to mean the
    /// server is unchanged — which is why `draftSyncDecision`'s **rule 0** ("the server body
    /// already equals our local body ⇒ `.push`") is the backstop: it catches exactly the state
    /// an unconfirmed-but-applied PATCH leaves behind, and stops the app raising a sync
    /// conflict against the user's own writing.
    ///
    /// Reporting the half-land as a return value rather than a second thrown type keeps
    /// `DocsAPIError` the one error type crossing this layer (see CLAUDE.md, Networking). The
    /// result is **not** discardable: a caller that ignores it silently loses the fact that
    /// the server holds its content, which is the whole point.
    func saveDocumentContent(documentID: UUID, title: String, markdown: String) async throws -> DocsAPIError? {
        let update = MarkdownYjs.encode(markdown: markdown)
        try await setContent(documentID: documentID, yjsUpdate: update)
        do {
            try await updateTitle(documentID: documentID, title: title)
            return nil
        } catch let error as DocsAPIError {
            return error
        } catch {
            // `performRequest` maps everything into `DocsAPIError`, so this is unreachable —
            // but it must never *rethrow*: the content PATCH has landed, and a throw would tell
            // the caller nothing reached the server, re-opening the conflict-against-your-own-
            // writing bug this signal exists to prevent.
            return .network(String(describing: error))
        }
    }

    /// Full-state live-collaboration snapshot save: PATCH the caller's Yjs bytes (tagged
    /// `"websocket": true`) then the title. Mirrors `saveDocumentContent`'s **half-land
    /// contract exactly** — it is two requests and can half-land — but the content bytes
    /// are a full-state Yjs snapshot the caller already holds
    /// (`DocumentCollaborationManager.encodeSnapshotForSave`), **not** re-derived from
    /// markdown via `MarkdownYjs.encode`:
    ///
    /// - **throws** ⇒ the *content* PATCH was not confirmed;
    /// - **returns non-nil** ⇒ the content landed and only the *title* PATCH failed;
    /// - **returns nil** ⇒ both landed.
    ///
    /// The `draftSyncDecision` rule-0/rule-1 backstop covers the unconfirmed-but-applied
    /// case exactly as it does for `saveDocumentContent`, which is why the result is **not**
    /// discardable — a caller that ignores it loses the fact that the server holds its bytes.
    func saveLiveSnapshot(documentID: UUID, title: String, yjsUpdate: Data) async throws -> DocsAPIError? {
        try await setContent(documentID: documentID, yjsUpdate: yjsUpdate, viaWebSocket: true)
        do {
            try await updateTitle(documentID: documentID, title: title)
            return nil
        } catch let error as DocsAPIError {
            return error
        } catch {
            // `performRequest` maps everything into `DocsAPIError`, so this is unreachable —
            // but it must never *rethrow*: the content PATCH has landed, and a throw would tell
            // the caller nothing reached the server, re-opening the conflict-against-your-own-
            // writing bug the split return exists to prevent.
            return .network(String(describing: error))
        }
    }
}
