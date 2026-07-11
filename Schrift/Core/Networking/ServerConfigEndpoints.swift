import Foundation

/// Public server config (`GET /api/v1.0/config/`). The Docs backend returns
/// `RELEASE_VERSION`; `JSONDecoder.docsAPI`'s `.convertFromSnakeCase` rewrites
/// that JSON key to `releaseVersion` *before* matching, so the property is named
/// to match the converted key (no custom CodingKeys). Optional ⇒ synthesized
/// `decodeIfPresent`, so a config without the key decodes to nil.
struct ServerConfig: Codable, Equatable, Sendable {
    let releaseVersion: String?

    /// Convenience alias for the Profile row.
    var version: String? { releaseVersion }

    init(releaseVersion: String? = nil) {
        self.releaseVersion = releaseVersion
    }
}

extension DocsAPIClient {
    /// Best-effort; the Profile hides the server-version row when unavailable.
    func serverConfig() async throws -> ServerConfig {
        try await get("config/")
    }
}
