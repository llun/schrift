import Foundation
import ImageIO
import UIKit

// Decoding stays inside the loader, never in a view. ImageIO's thumbnail path
// bounds bitmap memory and applies orientation without decoding a full-size photo.
func displayedImage(from data: Data) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 2048,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return UIImage(cgImage: image)
}

enum ImageLoadState: Equatable, Sendable {
    case idle, loading, requiresConsent, unavailableOffline, failed
    case cached(URL)
}

/// One owner for both surfaces. Tasks outlive view teardown; failures need an
/// explicit retry. Consent is exact-URL, namespace-scoped and memory-only. Cached
/// external bytes may display without a tap, because that issues no request.
@MainActor @Observable final class ImageLoader {
    private struct Key: Hashable {
        let scope: ImageCacheScope
        let url: URL
    }

    private var states: [Key: ImageLoadState] = [:]
    private var approved: Set<Key> = []
    private var inFlight: [Key: Task<UIImage?, Never>] = [:]
    private let decoded: NSCache<NSURL, UIImage>
    private let decode: @Sendable (Data) async -> UIImage?
    private let scopeProvider: () -> ImageCacheScope?
    private let cache: ImageCacheStore
    private let fetch: @MainActor @Sendable (URL, [HTTPCookie]) async throws -> Data
    private let cookieProvider: (URL) -> [HTTPCookie]

    var scope: ImageCacheScope? { scopeProvider() }

    init(
        scopeProvider: @escaping () -> ImageCacheScope?, cache: ImageCacheStore = ImageCacheStore(),
        decodedCache: NSCache<NSURL, UIImage>? = nil,
        fetch: @escaping @MainActor @Sendable (URL, [HTTPCookie]) async throws -> Data = { url, cookies in
            try await ImageTransport().data(for: url, cookies: cookies)
        },
        decode: @escaping @Sendable (Data) async -> UIImage? = { data in
            await Task.detached { displayedImage(from: data) }.value
        }, cookieProvider: @escaping (URL) -> [HTTPCookie] = { HTTPCookieStorage.shared.cookies(for: $0) ?? [] }
    ) {
        decoded = decodedCache ?? NSCache<NSURL, UIImage>()
        decoded.countLimit = 12
        decoded.totalCostLimit = 48 * 1024 * 1024
        self.decode = decode
        self.scopeProvider = scopeProvider
        self.cache = cache
        self.fetch = fetch
        self.cookieProvider = cookieProvider
    }

    convenience init(
        serverOrigin: String, cache: ImageCacheStore = ImageCacheStore(),
        scopeProvider: @escaping () -> String?, fetch: @escaping @MainActor @Sendable (URL, String) async throws -> Data
    ) {
        self.init(
            scopeProvider: { scopeProvider().map { ImageCacheScope(serverOrigin: serverOrigin, sessionID: $0) } },
            cache: cache, fetch: { url, _ in try await fetch(url, serverOrigin) }, cookieProvider: { _ in [] })
    }

    @discardableResult
    func loadIfNeeded(_ url: URL, allowsNetwork: Bool, approvedURL: URL?, retry: Bool = false) async -> UIImage? {
        if approvedURL == url { approve(url) }
        if retry { return await self.retry(url, allowsNetwork: allowsNetwork) }
        return await loadIfNeeded(url, allowsNetwork: allowsNetwork)
    }

    @discardableResult
    func loadIfNeeded(_ url: URL, allowsNetwork: Bool, retry: Bool) async -> UIImage? {
        retry
            ? await self.retry(url, allowsNetwork: allowsNetwork)
            : await loadIfNeeded(url, allowsNetwork: allowsNetwork)
    }

    func state(for url: URL) -> ImageLoadState {
        guard let scope else { return .unavailableOffline }
        return states[Key(scope: scope, url: url)] ?? .idle
    }

    /// Pure presentation accessor: disk and thumbnail work happen only in loads.
    func image(for url: URL) -> UIImage? {
        guard case .cached(let file) = state(for: url) else { return nil }
        return decoded.object(forKey: file as NSURL)
    }

    func approve(_ url: URL) {
        guard let scope, isFetchableImageURL(url) else { return }
        approved.insert(Key(scope: scope, url: url))
    }

    @discardableResult
    func loadIfNeeded(_ url: URL, allowsNetwork: Bool = true) async -> UIImage? {
        guard let scope else { return nil }
        let key = Key(scope: scope, url: url)
        if let running = inFlight[key] {
            let image = await running.value
            return self.scope == key.scope ? image : nil
        }
        // The task carries pixels to every waiter directly. NSCache is only for
        // reuse: eviction between async continuations cannot lose a load result.
        let task = Task { [weak self] () -> UIImage? in
            await self?.resolve(key, allowsNetwork: allowsNetwork)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        return self.scope == key.scope ? image : nil
    }

    @discardableResult
    func retry(_ url: URL, allowsNetwork: Bool = true) async -> UIImage? {
        if let scope, states[Key(scope: scope, url: url)] == .failed {
            states[Key(scope: scope, url: url)] = nil
        }
        return await loadIfNeeded(url, allowsNetwork: allowsNetwork)
    }

    private func resolve(_ key: Key, allowsNetwork: Bool) async -> UIImage? {
        guard scope == key.scope else { return nil }
        guard isFetchableImageURL(key.url) else {
            states[key] = .failed
            return nil
        }
        if let file = cache.cachedFileURL(for: key.url, scope: key.scope) {
            if let image = decoded.object(forKey: file as NSURL) {
                states[key] = .cached(file)
                return image
            }
            let data = await Task.detached { try? Data(contentsOf: file) }.value
            guard scope == key.scope else { return nil }
            if let data, await Task.detached(operation: { imageDataIsWithinLimits(data) }).value,
                let image = await decode(data)
            {
                guard scope == key.scope else { return nil }
                remember(image, file: file)
                states[key] = .cached(file)
                return image
            }
            guard scope == key.scope else { return nil }
            cache.remove(key.url, scope: key.scope)
        }
        let sameOrigin = imageLoadPolicy(for: key.url, serverOrigin: key.scope.serverOrigin) == .allow
        guard sameOrigin || approved.contains(key) else {
            states[key] = .requiresConsent
            return nil
        }
        // A previous failure remains retry-only, even after connectivity flips.
        guard states[key] != .failed else { return nil }
        guard allowsNetwork else {
            states[key] = .unavailableOffline
            return nil
        }
        states[key] = .loading
        let cookies = sameOrigin ? cookieProvider(key.url) : []
        do {
            let data = try await fetch(key.url, cookies)
            guard scope == key.scope else { return nil }
            guard await Task.detached(operation: { imageDataIsWithinLimits(data) }).value,
                let image = await decode(data)
            else {
                states[key] = .failed
                return nil
            }
            guard scope == key.scope else { return nil }
            guard let file = cache.store(data, for: key.url, scope: key.scope) else {
                states[key] = .failed
                return nil
            }
            remember(image, file: file)
            states[key] = .cached(file)
            return image
        } catch {
            guard scope == key.scope else { return nil }
            states[key] = .failed
            return nil
        }
    }

    private func remember(_ image: UIImage, file: URL) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        decoded.setObject(image, forKey: file as NSURL, cost: cost)
    }

    static func inert() -> ImageLoader { ImageLoader(scopeProvider: { nil }, cookieProvider: { _ in [] }) }
}
