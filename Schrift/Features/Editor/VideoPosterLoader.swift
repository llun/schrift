import AVFoundation
import Foundation
import ImageIO
import Observation
import UIKit
import UniformTypeIdentifiers

private actor VideoPosterExtractionLimiter {
    private let limit: Int
    private var inUse = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int = 2) {
        self.limit = max(1, limit)
    }

    func withPermit<T: Sendable>(_ operation: @Sendable () async -> T) async -> T {
        await acquire()
        defer { release() }
        return await operation()
    }

    private func acquire() async {
        if inUse < limit {
            inUse += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            inUse = max(0, inUse - 1)
        }
    }
}

/// Extracts, caches, and policy-gates poster frames for `.video` blocks.
///
/// Frames are always decoded from a local or cached file (never `AVURLAsset`
/// against a remote `http(s)://` URL) via `AVAssetImageGenerator` off the main
/// actor, stored under `"video-poster:\(url.absoluteString)"` in
/// `ImageCacheStore`, and never automatically fetched past `maxAutoFetchBytes`.
@MainActor
@Observable
final class VideoPosterLoader {
    /// Hard auto-fetch cap for video poster extraction (20 MB).
    static let maxAutoFetchBytes = 20 * 1024 * 1024
    static let posterKeyPrefix = "video-poster:"

    static func posterKey(for url: URL) -> String {
        posterKeyPrefix + url.absoluteString
    }

    static func posterKey(for urlString: String) -> String {
        posterKeyPrefix + urlString
    }

    static func posterURL(fromKey key: String) -> URL? {
        guard key.hasPrefix(posterKeyPrefix) else { return nil }
        return URL(string: String(key.dropFirst(posterKeyPrefix.count)))
    }

    private struct Key: Hashable {
        let scope: ImageCacheScope
        let url: String

        init(scope: ImageCacheScope, url: URL) {
            self.scope = scope
            self.url = url.absoluteString
        }
    }

    private struct Failure {
        enum Kind {
            case offline
            case transport
        }

        let kind: Kind
        let recordedAt: Date
    }

    private struct InFlightEntry {
        let id: UUID
        let task: Task<UIImage?, Never>
        var waiters: Set<UUID>
    }

    private let cache: ImageCacheStore
    private let attachmentCache: AttachmentCacheStore
    private let fetch: @MainActor @Sendable (URL, [HTTPCookie]) async throws -> (data: Data, mimeType: String?)
    private let cookieProvider: (URL) -> [HTTPCookie]
    private let scopeProvider: @MainActor () -> ImageCacheScope?
    private let extractPoster: @Sendable (URL, String?) async -> Data?
    private let now: () -> Date
    private let failureRetention: TimeInterval
    private let scratchDirectory: URL
    private let limiter = VideoPosterExtractionLimiter(limit: 2)

    private let memory = NSCache<NSString, UIImage>()
    private var activeScope: ImageCacheScope?
    private var aspectRatios: [Key: CGFloat] = [:]
    private var transportFailures: [Key: Failure] = [:]
    private var oversizeSkipped: Set<Key> = []
    private var failedPosters: Set<Key> = []
    private var approved: Set<Key> = []
    private var inFlight: [Key: InFlightEntry] = [:]

    /// Bumped when poster state or aspect ratio changes so SwiftUI observers re-read.
    private(set) var revision = 0

    init(
        cache: ImageCacheStore = ImageCacheStore(),
        attachmentCache: AttachmentCacheStore = AttachmentCacheStore(),
        fetch: @escaping @MainActor @Sendable (URL, [HTTPCookie]) async throws -> (data: Data, mimeType: String?) = {
            url, cookies in
            try await ImageTransport().responseData(
                for: url, cookies: cookies, byteLimit: VideoPosterLoader.maxAutoFetchBytes)
        },
        cookieProvider: @escaping (URL) -> [HTTPCookie] = { HTTPCookieStorage.shared.cookies(for: $0) ?? [] },
        scopeProvider: @escaping @MainActor () -> ImageCacheScope? = { nil },
        extractPoster: @escaping @Sendable (URL, String?) async -> Data? = { fileURL, mimeType in
            await VideoPosterLoader.extractJPEGPoster(from: fileURL, mimeType: mimeType)
        },
        scratchDirectory: URL = VideoPosterLoader.defaultScratchDirectory(),
        failureRetention: TimeInterval = 30,
        now: @escaping () -> Date = Date.init
    ) {
        self.cache = cache
        self.attachmentCache = attachmentCache
        self.fetch = fetch
        self.cookieProvider = cookieProvider
        self.scopeProvider = scopeProvider
        self.extractPoster = extractPoster
        self.scratchDirectory = scratchDirectory
        self.failureRetention = failureRetention
        self.now = now
        self.memory.countLimit = 16
        self.memory.totalCostLimit = 32 * 1024 * 1024
    }

    /// Inert loader for previews and views without a session container.
    static func inert() -> VideoPosterLoader { VideoPosterLoader(cookieProvider: { _ in [] }) }

    var scope: ImageCacheScope? { scopeProvider() }

    private func resolvedScope() -> ImageCacheScope? {
        guard let scope = scopeProvider(),
            !scope.serverOrigin.isEmpty,
            !scope.sessionID.isEmpty
        else {
            if activeScope != nil {
                activeScope = nil
                resetForScopeChange()
            }
            return nil
        }
        if let previous = activeScope, previous != scope {
            resetForScopeChange()
        }
        activeScope = scope
        return scope
    }

    private func resetForScopeChange() {
        memory.removeAllObjects()
        attachmentCache.removeAll()
        aspectRatios.removeAll()
        transportFailures.removeAll()
        oversizeSkipped.removeAll()
        failedPosters.removeAll()
        approved.removeAll()
    }

    func approve(_ url: URL) {
        guard let scope = resolvedScope() else { return }
        let key = Key(scope: scope, url: url)
        approved.insert(key)
        transportFailures.removeValue(forKey: key)
        revision += 1
    }

    func poster(for url: URL) -> UIImage? {
        guard let scope = resolvedScope(), isFetchableImageURL(url) else { return nil }
        let key = Key(scope: scope, url: url)
        let cacheKey = memoryKey(for: key)
        if let image = memory.object(forKey: cacheKey) {
            if aspectRatios[key] == nil, let ratio = imageAspectRatio(of: image.size) {
                aspectRatios[key] = ratio
            }
            return image
        }
        guard let fileURL = cache.cachedFileURL(forKey: Self.posterKey(for: url), scope: scope),
            let data = try? Data(contentsOf: fileURL),
            let image = displayedImage(from: data)
        else { return nil }
        storeInMemory(image, bytes: data.count, for: key)
        return image
    }

    func posterAspectRatio(for url: URL) -> CGFloat? {
        guard let scope = resolvedScope() else { return nil }
        let key = Key(scope: scope, url: url)
        if let cached = aspectRatios[key] { return cached }
        guard let image = poster(for: url) else { return nil }
        return aspectRatios[key] ?? imageAspectRatio(of: image.size)
    }

    func state(for url: URL) -> ImageLoadState {
        guard isFetchableImageURL(url) else { return .failed }
        guard let scope = resolvedScope() else { return .unavailableOffline }
        let key = Key(scope: scope, url: url)
        if let fileURL = cache.cachedFileURL(forKey: Self.posterKey(for: url), scope: scope) {
            return .cached(fileURL)
        }
        if inFlight[key] != nil { return .loading }
        if let failure = transportFailures[key] {
            if now().timeIntervalSince(failure.recordedAt) < failureRetention {
                return failure.kind == .offline ? .unavailableOffline : .failed
            }
            transportFailures.removeValue(forKey: key)
        }
        let policy = imageLoadPolicy(for: url, serverOrigin: scope.serverOrigin)
        switch policy {
        case .confirm where !approved.contains(key):
            return .requiresConsent
        case .allow, .confirm:
            break
        }
        if oversizeSkipped.contains(key) || failedPosters.contains(key) {
            return .failed
        }
        return .idle
    }

    func loadIfNeeded(_ url: URL, allowsNetwork: Bool = true) async -> UIImage? {
        if Task.isCancelled { return nil }
        guard isFetchableImageURL(url) else { return nil }
        guard let scope = resolvedScope() else { return nil }
        if let cached = poster(for: url) { return cached }

        let key = Key(scope: scope, url: url)
        let waiterID = UUID()

        let entry: InFlightEntry
        if var existing = inFlight[key] {
            existing.waiters.insert(waiterID)
            inFlight[key] = existing
            entry = existing
        } else {
            let entryID = UUID()
            let task = Task<UIImage?, Never> { @MainActor [weak self] in
                guard let self else { return nil }
                return await self.performLoad(url: url, key: key, scope: scope, allowsNetwork: allowsNetwork)
            }
            let created = InFlightEntry(id: entryID, task: task, waiters: [waiterID])
            inFlight[key] = created
            entry = created
        }

        revision += 1
        let image = await withTaskCancellationHandler {
            await entry.task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(waiterID, entryID: entry.id, for: key)
            }
        }

        if let current = inFlight[key], current.id == entry.id {
            inFlight.removeValue(forKey: key)
        }
        revision += 1
        return resolvedScope() == scope ? image : nil
    }

    func retry(_ url: URL, allowsNetwork: Bool = true) async -> UIImage? {
        if let scope = resolvedScope() {
            let key = Key(scope: scope, url: url)
            transportFailures.removeValue(forKey: key)
            oversizeSkipped.remove(key)
            failedPosters.remove(key)
        }
        return await loadIfNeeded(url, allowsNetwork: allowsNetwork)
    }

    private func cancelWaiter(_ waiterID: UUID, entryID: UUID, for key: Key) {
        guard var entry = inFlight[key], entry.id == entryID else { return }
        entry.waiters.remove(waiterID)
        if entry.waiters.isEmpty {
            inFlight.removeValue(forKey: key)
            entry.task.cancel()
        } else {
            inFlight[key] = entry
        }
    }

    private func performLoad(
        url: URL,
        key: Key,
        scope: ImageCacheScope,
        allowsNetwork: Bool
    ) async -> UIImage? {
        if Task.isCancelled || resolvedScope() != scope { return nil }
        if let cached = poster(for: url) { return cached }

        // Priority 1: local file already in AttachmentCacheStore (checks even if
        // oversizeSkipped/failedPosters was recorded earlier, so post-QuickLook >20 MB videos recover).
        if let display = parseAttachmentLink("[video](\(url.absoluteString))", serverOrigin: scope.serverOrigin),
            let localURL = attachmentCache.cachedFileURL(for: display)
        {
            return await extractAndCachePoster(
                fromFileURL: localURL,
                mimeType: nil,
                url: url,
                key: key,
                scope: scope
            )
        }

        // Priority 2: policy, consent, size/failure memory, offline, recent failure.
        let policy = imageLoadPolicy(for: url, serverOrigin: scope.serverOrigin)
        switch policy {
        case .confirm where !approved.contains(key):
            return nil
        case .allow, .confirm:
            break
        }

        if oversizeSkipped.contains(key) || failedPosters.contains(key) {
            return nil
        }

        if !allowsNetwork {
            transportFailures[key] = Failure(kind: .offline, recordedAt: now())
            return nil
        }

        if let failure = transportFailures[key] {
            if now().timeIntervalSince(failure.recordedAt) < failureRetention {
                return nil
            }
            transportFailures.removeValue(forKey: key)
        }

        // Priority 3: bounded 20 MB download to local file, then AVAssetImageGenerator.
        let sameOrigin = policy == .allow
        let cookies = sameOrigin ? cookieProvider(url) : []
        do {
            let (data, mimeType) = try await fetch(url, cookies)
            guard !Task.isCancelled, resolvedScope() == scope else { return nil }
            guard data.count <= Self.maxAutoFetchBytes else {
                oversizeSkipped.insert(key)
                return nil
            }

            guard let scratchURL = writeScratchFile(data: data, url: url, mimeType: mimeType) else {
                failedPosters.insert(key)
                return nil
            }
            defer { try? FileManager.default.removeItem(at: scratchURL) }
            let attachmentPayload = parseAttachmentLink(
                "[video](\(url.absoluteString))", serverOrigin: scope.serverOrigin
            )
            .map { (display: $0, data: data) }
            return await extractAndCachePoster(
                fromFileURL: scratchURL,
                mimeType: mimeType,
                url: url,
                key: key,
                scope: scope,
                attachmentCachePayload: attachmentPayload
            )
        } catch {
            if Task.isCancelled || resolvedScope() != scope { return nil }
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == URLError.dataLengthExceedsMaximum.rawValue {
                oversizeSkipped.insert(key)
                return nil
            }
            if isTransportFailure(error) {
                transportFailures[key] = Failure(kind: .transport, recordedAt: now())
                return nil
            }
            failedPosters.insert(key)
            return nil
        }
    }

    private func extractAndCachePoster(
        fromFileURL fileURL: URL,
        mimeType: String?,
        url: URL,
        key: Key,
        scope: ImageCacheScope,
        attachmentCachePayload: (display: AttachmentDisplay, data: Data)? = nil
    ) async -> UIImage? {
        guard fileURL.isFileURL, resolvedScope() == scope else { return nil }
        let jpegData = await limiter.withPermit {
            await extractPoster(fileURL, mimeType)
        }
        guard !Task.isCancelled, resolvedScope() == scope else { return nil }
        guard let jpegData, let image = displayedImage(from: jpegData) else {
            failedPosters.insert(key)
            return nil
        }
        guard resolvedScope() == scope else { return nil }
        if let payload = attachmentCachePayload {
            _ = attachmentCache.store(payload.data, for: payload.display)
        }
        oversizeSkipped.remove(key)
        failedPosters.remove(key)
        _ = cache.store(jpegData, forKey: Self.posterKey(for: url), scope: scope)
        storeInMemory(image, bytes: jpegData.count, for: key)
        return image
    }

    private func storeInMemory(_ image: UIImage, bytes: Int, for key: Key) {
        memory.setObject(image, forKey: memoryKey(for: key), cost: max(1, bytes))
        if let ratio = imageAspectRatio(of: image.size) {
            aspectRatios[key] = ratio
        }
    }

    private func memoryKey(for key: Key) -> NSString {
        [key.scope.serverOrigin, key.scope.sessionID, key.url]
            .map { "\($0.utf8.count):\($0)" }
            .joined() as NSString
    }

    private func writeScratchFile(data: Data, url: URL, mimeType: String?) -> URL? {
        let manager = FileManager.default
        try? manager.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dirURL = scratchDirectory
        try? dirURL.setResourceValues(values)

        let ext = Self.sanitizedVideoExtension(url: url, mimeType: mimeType)
        let fileURL = scratchDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)", isDirectory: false)
        do {
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return fileURL
        } catch {
            try? manager.removeItem(at: fileURL)
            return nil
        }
    }

    private nonisolated static let blockedPlaylistExtensions: Set<String> = [
        "m3u", "m3u8", "pls", "xspf", "mpd", "asx", "smil",
    ]
    private nonisolated static let supportedVideoContainerExtensions: Set<String> = [
        "mp4", "m4v", "mov", "webm", "avi", "mkv", "ts", "mts", "m2ts",
        "mpeg", "mpg", "ogv", "3gp", "3g2", "flv", "wmv", "asf", "divx",
    ]
    private nonisolated static let allowedVideoMIMETypes: Set<String> = [
        "video/mp4", "video/x-m4v", "video/quicktime", "video/webm",
        "video/3gpp", "video/3gpp2", "video/x-msvideo", "video/avi",
        "video/x-matroska", "video/mp2t", "video/mpeg", "video/ogg",
        "video/x-flv", "video/x-ms-wmv",
    ]

    nonisolated static func isSupportedVideoFileExtension(_ fileExtension: String) -> Bool {
        let ext = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !ext.isEmpty, !blockedPlaylistExtensions.contains(ext) else { return false }

        let types = UTType.types(tag: ext, tagClass: .filenameExtension, conformingTo: nil)
        if types.contains(where: { $0.conforms(to: .playlist) || $0.conforms(to: .m3uPlaylist) }) {
            return false
        }
        if types.contains(where: { $0.conforms(to: .movie) || $0.conforms(to: .video) }) {
            return true
        }
        let avTypes = Set(AVURLAsset.audiovisualTypes().map(\.rawValue))
        if types.contains(where: { avTypes.contains($0.identifier) && !$0.conforms(to: .audio) }) {
            return true
        }
        return supportedVideoContainerExtensions.contains(ext)
    }

    private nonisolated static func normalizedAllowedMIMEType(_ mimeType: String?) -> String? {
        guard let mimeType else { return nil }
        let base = mimeType.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let base, allowedVideoMIMETypes.contains(base) else { return nil }
        return base
    }

    nonisolated static func avURLAssetOptions(mimeType: String?) -> [String: Any] {
        var options: [String: Any] = [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
        ]
        if let safeMIME = normalizedAllowedMIMEType(mimeType) {
            options[AVURLAssetOverrideMIMETypeKey] = safeMIME
        }
        return options
    }

    private static func sanitizedVideoExtension(url: URL, mimeType: String?) -> String {
        let pathExt = url.pathExtension.lowercased()
        if isSupportedVideoFileExtension(pathExt) {
            return pathExt
        }
        if let safeMIME = normalizedAllowedMIMEType(mimeType),
            let utType = UTType(mimeType: safeMIME),
            let preferred = utType.preferredFilenameExtension?.lowercased(),
            isSupportedVideoFileExtension(preferred)
        {
            return preferred
        }
        return "mp4"
    }

    private nonisolated static func extractJPEGPoster(from fileURL: URL, mimeType: String?) async -> Data? {
        guard fileURL.isFileURL,
            !Task.isCancelled,
            isSupportedVideoFileExtension(fileURL.pathExtension)
        else { return nil }
        let asset = AVURLAsset(url: fileURL, options: avURLAssetOptions(mimeType: mimeType))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        let candidateTimes = [
            CMTime(seconds: 0.1, preferredTimescale: 600),
            .zero,
        ]
        for time in candidateTimes {
            if Task.isCancelled { return nil }
            if let (cgImage, _) = try? await generator.image(at: time) {
                return encodeJPEG(cgImage: cgImage, quality: 0.82)
            }
        }
        return nil
    }

    private nonisolated static func encodeJPEG(cgImage: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func defaultScratchDirectory() -> URL {
        let caches =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return
            caches
            .appendingPathComponent("dev.llun.Schrift", isDirectory: true)
            .appendingPathComponent("VideoPosterScratch", isDirectory: true)
    }
}
