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
    /// Live collaboration is available when the server advertises a WebSocket and,
    /// for Docs 6's y-websocket transport, its internal server capability is enabled.
    /// The user preference `schrift.liveCollaboration` remains an independent opt-in;
    /// it cannot bypass this server gate. The socket URL is still origin-pinned by
    /// `CollaborationEndpoint`.
    var supportsLiveCollaboration: Bool {
        collaborationWsUrl?.isEmpty == false
            && (!usesCollaborationYDocServer || Self.yWebSocketLiveCollaborationEnabled)
    }

    /// The native editor's server capability (PR09a): a Docs 6 deployment that
    /// advertises its collaboration socket. Native typing exists only on Docs 6,
    /// and this never reads `yWebSocketLiveCollaborationEnabled` (A5's switch).
    var supportsNativeLiveCollaboration: Bool {
        collaborationWsUrl?.isEmpty == false && usesCollaborationYDocServer
    }

    /// Internal release capability, deliberately separate from the user preference.
    static let yWebSocketLiveCollaborationEnabled = true

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
        // Absolute anchors also reject a final newline (regex `$` accepts one).
        guard let segment = collaborationOrgPathSegment,
            segment.range(of: #"\A[A-Za-z0-9._~-]+\z"#, options: .regularExpression) != nil,
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
    /// The save path fetches config itself only after the legacy route 404s, to learn the
    /// collaboration org; see `ContentSaveRoute`.
    ///
    /// Concurrent callers (launch task, Profile, favorites route discovery) share one request;
    /// the slot clears when it settles, so later calls refetch.
    func serverConfig() async throws -> ServerConfig {
        if let task = inFlightServerConfig { return try await task.value }
        let task = Task { try await self.fetchServerConfig() }
        inFlightServerConfig = task
        defer { inFlightServerConfig = nil }
        return try await task.value
    }

    private func fetchServerConfig() async throws -> ServerConfig {
        let config: ServerConfig = try await get("config/")
        if let route = ContentSaveRoute(config: config) {
            contentSaveRoute = route
        }
        notifyServerConfig(config)
        return config
    }
}

/// Last-known server capabilities (`GET /api/v1.0/config/`) persisted per
/// `serverOrigin`, so offline local-document creation and offline Docs 6
/// read-only guards know whether the server runs Docs 6 and its yhub org.
struct ServerConfigStore: @unchecked Sendable {
    private static let key = "dev.llun.Schrift.serverConfigs"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func config(forServerOrigin origin: String) -> ServerConfig? {
        guard !origin.isEmpty else { return nil }
        return allConfigs()[origin]
    }

    func remember(_ config: ServerConfig, forServerOrigin origin: String) {
        guard !origin.isEmpty else { return }
        var configs = allConfigs()
        configs[origin] = config
        if let data = try? JSONEncoder().encode(configs) {
            userDefaults.set(data, forKey: Self.key)
        }
    }

    func clear(forServerOrigin origin: String) {
        guard !origin.isEmpty else { return }
        var configs = allConfigs()
        guard configs.removeValue(forKey: origin) != nil else { return }
        if configs.isEmpty {
            userDefaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(configs) {
            userDefaults.set(data, forKey: Self.key)
        }
    }

    private func allConfigs() -> [String: ServerConfig] {
        guard let data = userDefaults.data(forKey: Self.key),
            let configs = try? JSONDecoder().decode([String: ServerConfig].self, from: data)
        else { return [:] }
        return configs
    }
}
