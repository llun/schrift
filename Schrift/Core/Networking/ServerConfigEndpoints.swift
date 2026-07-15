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
    var supportsLiveCollaboration: Bool { collaborationWsUrl?.isEmpty == false }

    init(releaseVersion: String? = nil, collaborationWsUrl: String? = nil) {
        self.releaseVersion = releaseVersion
        self.collaborationWsUrl = collaborationWsUrl
    }
}

extension DocsAPIClient {
    /// Best-effort; the Profile hides the server-version row when unavailable.
    func serverConfig() async throws -> ServerConfig {
        try await get("config/")
    }
}
