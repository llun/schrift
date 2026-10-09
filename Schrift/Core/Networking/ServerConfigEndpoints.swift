import Foundation

/// Public server config (`GET /api/v1.0/config/`). The Docs backend returns
/// `RELEASE_VERSION`; `JSONDecoder.docsAPI`'s `.convertFromSnakeCase` rewrites
/// that JSON key to `releaseVersion` *before* matching, so the property is named
/// to match the converted key (no custom CodingKeys). Optional ⇒ synthesized
/// `decodeIfPresent`, so a config without the key decodes to nil.
struct ServerConfig: Codable, Equatable, Sendable {
    let releaseVersion: String?
    /// The backend's `COLLABORATION_WS_URL` (snake_case-converted). Present when
    /// the deployment runs the y-provider collaboration server.
    let collaborationWsUrl: String?

    /// Convenience alias for the Profile row.
    var version: String? { releaseVersion }

    /// Whether the server advertises a collaboration WebSocket. Used **only** as
    /// a boolean gate for live-editing availability — the dialed socket URL is
    /// always derived from the user's own server origin (`CollaborationEndpoint`),
    /// never from this value, so a cross-origin config can't redirect the socket
    /// or leak the session cookie off-origin.
    ///
    /// **False on a Docs 6 server.** Docs 6 replaced the Hocuspocus collaboration server
    /// with yhub, which speaks plain y-websocket at `/collaboration/ws/v1/{org}`; the app's
    /// collaboration layer speaks Hocuspocus and cannot join such a room, so advertising it
    /// would only open a socket that never syncs.
    var supportsLiveCollaboration: Bool {
        collaborationWsUrl?.isEmpty == false && !usesCollaborationYDocServer
    }

    /// Whether this is a Docs 6+ deployment, whose document content lives in the yhub
    /// collaboration server rather than behind `documents/{id}/content/` — known from the
    /// release major, or from a collaboration URL in yhub's `/ws/v1/{org}` shape (which a
    /// deployment that hides or customizes its version still exposes).
    var usesCollaborationYDocServer: Bool {
        if let major = releaseVersionComponents(releaseVersion)?.first, major >= 6 { return true }
        return collaborationOrgPathSegment != nil
    }

    /// The yhub organization for this server's document routes: the last path segment of a
    /// `…/ws/v1/{org}` collaboration URL when it is plain URL-safe text, else `docs` (yhub's
    /// default). Only the *org segment* is ever taken from config — never the host — and it
    /// is character-validated because it is interpolated into a request path.
    var collaborationOrg: String {
        guard let segment = collaborationOrgPathSegment,
            segment.range(of: #"^[A-Za-z0-9._~-]+$"#, options: .regularExpression) != nil,
            segment != ".", segment != ".."
        else { return "docs" }
        return segment
    }

    /// The `{org}` of a collaboration URL whose path ends in `/ws/v1/{org}` (yhub's
    /// y-websocket endpoint), unvalidated; nil for any other shape (Hocuspocus's
    /// `/collaboration/ws/`, an empty or unparsable value).
    private var collaborationOrgPathSegment: String? {
        guard let raw = collaborationWsUrl, !raw.isEmpty, let url = URL(string: raw) else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 3, components[components.count - 3] == "ws",
            components[components.count - 2] == "v1"
        else { return nil }
        return components[components.count - 1]
    }

    init(releaseVersion: String? = nil, collaborationWsUrl: String? = nil) {
        self.releaseVersion = releaseVersion
        self.collaborationWsUrl = collaborationWsUrl
    }
}

extension DocsAPIClient {
    /// Best-effort; the Profile hides the server-version row when unavailable.
    ///
    /// Also records where this server's document content is saved (`contentSaveRoute`)
    /// whenever the config says so definitively, so the first save on a Docs 6 server goes
    /// straight to the collaboration server instead of discovering the legacy route's 404.
    /// The save path deliberately does not fetch config itself; see `ContentSaveRoute`.
    func serverConfig() async throws -> ServerConfig {
        let config: ServerConfig = try await get("config/")
        if let route = ContentSaveRoute(config: config) {
            contentSaveRoute = route
        }
        return config
    }
}
