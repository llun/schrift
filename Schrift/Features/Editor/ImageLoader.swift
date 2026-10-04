import Foundation
import Observation

enum ImageLoadState: Equatable, Sendable {
    case cached(URL)
    case loading
    case requiresConsent
    case unavailableOffline
    case failed
}

/// One app-scoped owner for both document surfaces. Download tasks survive a surface swap;
/// the authenticated scope is checked again before any response may publish or reach disk.
@MainActor @Observable final class ImageLoader {
    private struct Key: Hashable {
        let scope: String
        let url: URL
    }
    private var states: [Key: ImageLoadState] = [:]
    private var inFlight: [Key: Task<Void, Never>] = [:]
    private let cache: ImageCacheStore
    private let serverOrigin: String
    private let scopeProvider: () -> String?
    private let fetch: (URL, String) async throws -> Data

    var scope: String? { scopeProvider() }

    init(
        serverOrigin: String, cache: ImageCacheStore = ImageCacheStore(),
        scopeProvider: @escaping () -> String?,
        fetch: @escaping (URL, String) async throws -> Data
    ) {
        self.serverOrigin = serverOrigin
        self.cache = cache
        self.scopeProvider = scopeProvider
        self.fetch = fetch
    }

    func state(for url: URL) -> ImageLoadState? {
        guard let scope else { return nil }
        return states[Key(scope: scope, url: url)]
    }

    func loadIfNeeded(_ url: URL, allowsNetwork: Bool, approvedURL: URL? = nil, retry: Bool = false) async {
        guard let scope, !serverOrigin.isEmpty else { return }
        let key = Key(scope: scope, url: url)
        if let running = inFlight[key] {
            await running.value
            return
        }
        if let file = cache.cachedFileURL(for: url, serverOrigin: serverOrigin, scope: scope),
            imageThumbnail(at: file) != nil
        {
            states[key] = .cached(file)
            return
        }
        guard allowsNetwork else {
            states[key] = .unavailableOffline
            return
        }
        guard imageLoadPolicy(for: url, serverOrigin: serverOrigin) == .allow || approvedURL == url else {
            states[key] = .requiresConsent
            return
        }
        if states[key] == .failed && !retry { return }
        states[key] = .loading
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let bytes = try await fetch(url, serverOrigin)
                guard self.scope == scope else { return }
                states[key] =
                    cache.store(bytes, for: url, serverOrigin: serverOrigin, scope: scope)
                    .map(ImageLoadState.cached) ?? .failed
            } catch {
                guard self.scope == scope else { return }
                states[key] = .failed
            }
        }
        inFlight[key] = task
        await task.value
        inFlight[key] = nil
        // Old account state holds no useful display information once its scope is gone.
        states = states.filter { $0.key.scope == self.scope }
    }

    static func inert() -> ImageLoader {
        ImageLoader(serverOrigin: "", scopeProvider: { nil }, fetch: { _, _ in throw URLError(.cancelled) })
    }
}
