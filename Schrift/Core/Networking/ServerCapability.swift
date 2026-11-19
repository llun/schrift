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
/// Only a decoded config that proves a route is an answer — the same rule as
/// `ContentSaveRoute(config:)`: a release major ≥ 6 or a yhub collaboration URL is Docs 6, a
/// parsable older release is legacy, and a config that names neither (a hidden or custom
/// version, a Hocuspocus URL) proves nothing. Every failure — a 404 (a proxy mid-rollout
/// answers one too), a transport error, a 5xx, an undecodable body, an expired session —
/// proves nothing and stays unknown: a wrong legacy would lock a Docs 6 user out of their
/// own server.
func serverCapability(from result: Result<ServerConfig, any Error>) -> ServerCapability? {
    guard case .success(let config) = result else { return nil }
    return serverCapability(from: config)
}

/// The capability a decoded config proves, or nil (`ContentSaveRoute(config:)`'s rule).
func serverCapability(from config: ServerConfig) -> ServerCapability? {
    switch ContentSaveRoute(config: config) {
    case .collaborationYDoc: return .docs6
    case .legacyContent: return .legacy
    case nil: return nil
    }
}

/// The Docs capability last proved for each server, keyed by `siteOrigin` (`https://host[:port]`).
///
/// Deliberately separate from `ServerConfigStore`, which keeps the whole decoded config for the
/// save route and the yhub org: this store answers one question — *is this server Docs 6?* It
/// is written wherever a config is learned (`noteServerConfig`, the client's `onServerConfig`
/// hook, sign-in and the launch refresh).
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

    /// Records what a decoded config proves; a config that proves nothing changes nothing.
    func record(_ config: ServerConfig, forServerOrigin origin: String) {
        guard let capability = serverCapability(from: config) else { return }
        record(capability, forServerOrigin: origin)
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
