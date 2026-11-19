import Foundation

/// What a server's `GET /api/v1.0/config/` has proved about its Docs version.
///
/// Schrift supports only Docs 6+ servers (`ServerConfig.usesCollaborationYDocServer`), so the
/// app refuses to run against a pre-Docs 6 one. The capability is a **tri-state**: `docs6` and
/// `legacy` are both answers, and the *absence* of an entry is unknown — never fetched, or the
/// last fetch failed. Unknown never blocks: an offline launch must keep working.
enum ServerCapability: String, Codable, Sendable {
    case docs6
    case legacy
}

/// The capability a `GET config/` outcome proves, or nil when it proves nothing.
///
/// Only two things are answers. A decoded config says which side it is on. A 404 for the
/// **route** is also an answer — a server with no `config/` route cannot be Docs 6, whose
/// collaboration URL (the only other proof) comes from config — and it is the same
/// "definitive" rule `fallbackCollaborationOrg` already uses for the save route
/// (`CollaborationYDocEndpoints.swift`). Everything else — a transport failure, a 5xx, an
/// undecodable body, an expired session — proves nothing and must stay unknown: reading a
/// failed fetch as legacy would lock a Docs 6 user out of their own server whenever they
/// launch offline.
func serverCapability(from result: Result<ServerConfig, any Error>) -> ServerCapability? {
    switch result {
    case .success(let config):
        return config.usesCollaborationYDocServer ? .docs6 : .legacy
    case .failure(let error):
        guard let apiError = error as? DocsAPIError, apiError == .notFound || apiError == .routeNotFound
        else { return nil }
        return .legacy
    }
}

/// The Docs capability last proved for each server, keyed by `siteOrigin` (`https://host[:port]`).
///
/// Deliberately separate from `ServerConfigStore`, which keeps the whole decoded config for the
/// save route and the yhub org: this store answers one question — *is this server Docs 6?* — and
/// it can answer it for a server whose config route 404s, where there is no config to keep.
/// Both are written together wherever a config is learned (`noteServerConfig`, the client's
/// `onServerConfig` hook, sign-in and the launch refresh), so they never disagree.
///
/// `@unchecked Sendable` for the same reason `ServerConfigStore` is: it is written from the API
/// client's `@Sendable` `onServerConfig` hook, off the main actor, and `UserDefaults` is
/// thread-safe. Reads never write, so a `@State` initializer that runs twice cannot invalidate
/// `@AppStorage` and loop the first scene.
struct ServerCapabilityStore: @unchecked Sendable {
    private static let key = "dev.llun.Schrift.serverCapabilities"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// nil means unknown — never fetched, or the last fetch proved nothing.
    func capability(forServerOrigin origin: String) -> ServerCapability? {
        guard !origin.isEmpty else { return nil }
        return allCapabilities()[origin]
    }

    func record(_ capability: ServerCapability, forServerOrigin origin: String) {
        guard !origin.isEmpty else { return }
        var capabilities = allCapabilities()
        guard capabilities[origin] != capability else { return }
        capabilities[origin] = capability
        persist(capabilities)
    }

    /// Records what a decoded config proves. The 404 case has no config to pass here; callers
    /// that see one record `.legacy` directly.
    func record(_ config: ServerConfig, forServerOrigin origin: String) {
        record(config.usesCollaborationYDocServer ? .docs6 : .legacy, forServerOrigin: origin)
    }

    func clear(forServerOrigin origin: String) {
        guard !origin.isEmpty else { return }
        var capabilities = allCapabilities()
        guard capabilities.removeValue(forKey: origin) != nil else { return }
        persist(capabilities)
    }

    private func persist(_ capabilities: [String: ServerCapability]) {
        if capabilities.isEmpty {
            userDefaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(capabilities) {
            userDefaults.set(data, forKey: Self.key)
        }
    }

    private func allCapabilities() -> [String: ServerCapability] {
        guard let data = userDefaults.data(forKey: Self.key),
            let capabilities = try? JSONDecoder().decode([String: ServerCapability].self, from: data)
        else { return [:] }
        return capabilities
    }
}
