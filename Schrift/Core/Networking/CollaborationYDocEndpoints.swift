import Foundation

// MARK: - Where a document's body is saved

/// Which route `saveDocumentContent` writes a document's body through.
///
/// Docs 6 removed `GET`/`PATCH documents/{id}/content/` (the Django route is gone, so it
/// answers Django's HTML 404 → `.routeNotFound`). Content now lives in the collaboration
/// server ("yhub"), mounted on the **same origin** under `/collaboration/`, whose
/// `/collaboration/ydoc/v1/{org}/{id}` route returns the document's Yjs state and applies a
/// PATCHed update **incrementally** (see `BlockNoteIncrementalSave`).
///
/// The route is decided by `serverConfig()` (`init(config:)`) when the config is definitive.
/// The save path itself never fetches config — that would add a request to the first save
/// of every client — so with nothing known it tries the legacy route first and, on
/// `.routeNotFound` only, falls back to the collaboration route. That fallback is safe
/// because Django's route 404 means the legacy PATCH wrote nothing. It is memoized only once
/// the collaboration route has *answered*: pinning a route that cannot answer would break
/// every save for the rest of the client's life (the `prefersLegacyContentRoute` lesson).
enum ContentSaveRoute: Equatable, Sendable {
    /// `PATCH documents/{id}/content/` with a full-overwrite Yjs document (Docs < 6).
    case legacyContent
    /// `PATCH /collaboration/ydoc/v1/{org}/{id}` with an incremental update (Docs 6+).
    case collaborationYDoc(org: String)

    /// The route a config proves, or nil when it proves nothing (no parsable version and no
    /// yhub-shaped collaboration URL). `org` is only ever the character-validated
    /// `ServerConfig.collaborationOrg` — the host is never taken from config.
    init?(config: ServerConfig) {
        if config.usesCollaborationYDocServer {
            self = .collaborationYDoc(org: config.collaborationOrg)
        } else if releaseVersionComponents(config.releaseVersion) != nil {
            self = .legacyContent
        } else {
            return nil
        }
    }
}

/// The collaboration server's document route: `/collaboration/ydoc/v1/{org}/{uuid}`, no
/// trailing slash (it is not a Django route), uuid lowercased.
///
/// **A rooted path, deliberately** — like `checkMedia(path:)`, it resolves against the
/// server origin rather than the `/api/v1.0/` base. Unlike that exception it is entirely
/// app-authored: the only variable parts are a `UUID` and an `org` that
/// `ServerConfig.collaborationOrg` has already restricted to `[A-Za-z0-9._~-]` (and never `.`
/// or `..`), so nothing here can name another host, scheme or path.
func collaborationYDocPath(org: String, documentID: UUID) -> String {
    "/collaboration/ydoc/v1/\(org)/\(documentID.uuidString.lowercased())"
}

/// `GET …?gc=true&awareness=false` with `Accept: application/json` answers
/// `{"doc": "<base64 Yjs v1 update>"}`; an empty or absent `doc` is an empty document.
private struct CollaborationYDocSnapshot: Decodable {
    let doc: String?
}

extension DocsAPIClient {
    /// The document's whole (garbage-collected) Yjs state from the collaboration server.
    func collaborationYDocState(documentID: UUID, org: String) async throws -> Data {
        let path = collaborationYDocPath(org: org, documentID: documentID) + "?gc=true&awareness=false"
        let snapshot: CollaborationYDocSnapshot = try await get(path, accept: "application/json")
        guard let encoded = snapshot.doc, !encoded.isEmpty else { return Data() }
        guard let bytes = Data(base64Encoded: encoded) else {
            throw DocsAPIError.decoding("collaboration document is not base64")
        }
        return bytes
    }

    /// Applies an incremental Yjs update to the document on the collaboration server. A
    /// mutating request, so it goes through `sendVoid` and carries the CSRF/`Origin` headers
    /// like every other — harmless to a same-origin server that does not check them.
    func applyCollaborationYDocUpdate(documentID: UUID, org: String, update: Data) async throws {
        let body = try JSONEncoder().encode(["update": update.base64EncodedString()])
        try await sendVoid(path: collaborationYDocPath(org: org, documentID: documentID), method: "PATCH", body: body)
    }

    /// Writes a document's body through whichever route this server has (see
    /// `ContentSaveRoute`). Throws ⇒ the body was not confirmed; returns ⇒ the server holds
    /// it — `saveDocumentContent`'s half-land contract depends on exactly that.
    func saveContentBody(documentID: UUID, markdown: String) async throws {
        if case .collaborationYDoc(let org) = contentSaveRoute {
            try await saveContentToCollaborationYDoc(documentID: documentID, org: org, markdown: markdown)
            return
        }
        do {
            // The one production full-overwrite encode site; it runs on the client actor, so
            // the origin is read straight off `baseURL`.
            let update = MarkdownYjs.encode(markdown: markdown, serverOrigin: serverOrigin)
            try await setContent(documentID: documentID, yjsUpdate: update)
        } catch DocsAPIError.routeNotFound {
            // Django's own route 404: the legacy PATCH wrote nothing, so trying the Docs 6
            // route is safe. Only this error qualifies — `.notFound` (a deleted document),
            // `.forbidden` and everything else are answers about the document, not the route.
            try await saveContentToCollaborationYDoc(documentID: documentID, org: "docs", markdown: markdown)
        }
    }

    /// The Docs 6 body save: GET the server's state, diff the editor's blocks against it
    /// (`BlockNoteIncrementalSave`), PATCH the incremental update — or nothing, when the
    /// server already reads that way. Memoizes the route once the GET has answered.
    private func saveContentToCollaborationYDoc(documentID: UUID, org: String, markdown: String) async throws {
        let state = try await collaborationYDocState(documentID: documentID, org: org)
        contentSaveRoute = .collaborationYDoc(org: org)
        let origin = serverOrigin
        let update: Data?
        do {
            update = try BlockNoteIncrementalSave.update(
                serverState: state, newBlocks: MarkdownYjs.blockNoteBlocks(from: markdown, serverOrigin: origin),
                serverOrigin: origin)
        } catch {
            throw DocsAPIError.decoding("collaboration document: \(error)")
        }
        guard let update else { return }
        try await applyCollaborationYDocUpdate(documentID: documentID, org: org, update: update)
    }
}
