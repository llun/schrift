import SwiftUI
import XCTest

@testable import Schrift

/// Records even redundant writes: comparing the final defaults misses notifications that
/// can invalidate AppStorage while SwiftUI is constructing its first scene.
private final class LaunchDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var writes: [String] = []
    private var removals: [String] = []

    var writtenKeys: [String] { lock.withLock { writes + removals } }
    var removedKeys: [String] { lock.withLock { removals } }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.withLock { writes.append(defaultName) }
        super.set(value, forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) {
        lock.withLock { removals.append(defaultName) }
        super.removeObject(forKey: defaultName)
    }

    func resetWrites() {
        lock.withLock {
            writes.removeAll()
            removals.removeAll()
        }
    }
}

@MainActor
final class LaunchPreferencesTests: XCTestCase {
    private var suite: String!
    private var defaults: LaunchDefaults!
    private let namespaceKey = "dev.llun.Schrift.imageCacheSessionID"
    private let legacyKey = "dev.llun.Schrift.cachedSharedByMeDocuments"

    override func setUp() {
        super.setUp()
        suite = "LaunchPreferencesTests.\(UUID())"
        defaults = LaunchDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func authenticatedKeychain() throws -> FakeKeychainStore {
        let keychain = FakeKeychainStore()
        try keychain.save(Data([1]), forKey: "dev.llun.Schrift.isAuthenticated")
        return keychain
    }

    func testRepeatedCacheConstructionDoesNotWriteWhenLegacyCacheIsAbsent() {
        for _ in 0..<5 { _ = DocumentCacheStore(userDefaults: defaults) }
        XCTAssertEqual(defaults.writtenKeys, [], "View reconstruction must not invalidate AppStorage")
    }

    func testLegacyCacheIsRemovedOnceAndCurrentListsArePreserved() {
        let cache = DocumentCacheStore(userDefaults: defaults)
        cache.saveRecentDocuments([])
        defaults.set(Data("legacy".utf8), forKey: legacyKey)
        defaults.resetWrites()

        for _ in 0..<5 { _ = DocumentCacheStore(userDefaults: defaults) }

        XCTAssertNil(defaults.object(forKey: legacyKey))
        XCTAssertEqual(defaults.removedKeys, [legacyKey])
        XCTAssertEqual(cache.loadRecentDocuments(), [])
    }

    func testRestoringExistingSessionNamespaceDoesNotWritePreferences() throws {
        let namespace = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        defaults.set(namespace.uuidString, forKey: namespaceKey)
        defaults.resetWrites()
        let keychain = try authenticatedKeychain()
        let cookies = FakeCookieStorage()

        for _ in 0..<5 {
            let session = SessionStore(userDefaults: defaults, keychain: keychain, cookieStorage: cookies)
            XCTAssertTrue(session.isAuthenticated)
            XCTAssertEqual(session.imageCacheSessionID, namespace)
        }

        XCTAssertEqual(defaults.writtenKeys, [], "Restoring a session must not invalidate AppStorage")
    }

    func testMissingOrMalformedSessionNamespaceIsMigratedOnce() throws {
        let keychain = try authenticatedKeychain()
        for stored in [nil, "invalid"] as [String?] {
            defaults.set(stored, forKey: namespaceKey)
            defaults.resetWrites()
            let first = SessionStore(userDefaults: defaults, keychain: keychain, cookieStorage: FakeCookieStorage())
            let second = SessionStore(userDefaults: defaults, keychain: keychain, cookieStorage: FakeCookieStorage())
            XCTAssertNotNil(first.imageCacheSessionID)
            XCTAssertEqual(first.imageCacheSessionID, second.imageCacheSessionID)
            XCTAssertEqual(defaults.writtenKeys, [namespaceKey])
        }
    }

    func testStoreReconstructionUnderAppStorageSettlesItsFirstFrame() async throws {
        defaults.set(UUID().uuidString, forKey: namespaceKey)
        defaults.resetWrites()
        let counter = Counter()
        let host = UIHostingController(
            rootView: LaunchPreferencesProbe(
                defaults: defaults, keychain: try authenticatedKeychain(), counter: counter))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        host.view.layoutIfNeeded()
        await waitUntil { counter.current > 0 }
        await waitAndConfirmNever { counter.current >= 12 }
        XCTAssertEqual(defaults.writtenKeys, [])
    }
}

/// Recreates the launch path's stores while the offline preference is observed. The cap
/// breaks a bad feedback loop before it can watchdog-kill the entire XCTest host.
private struct LaunchPreferencesProbe: View {
    let defaults: UserDefaults
    let keychain: FakeKeychainStore
    let counter: Counter
    @AppStorage private var workOffline: Bool

    init(defaults: UserDefaults, keychain: FakeKeychainStore, counter: Counter) {
        self.defaults = defaults
        self.keychain = keychain
        self.counter = counter
        _workOffline = AppStorage(wrappedValue: false, "schrift.workOffline", store: defaults)
    }

    var body: some View {
        let pass = counter.next()
        if pass < 12 {
            let _ = DocumentCacheStore(userDefaults: defaults)
            let _ = SessionStore(userDefaults: defaults, keychain: keychain, cookieStorage: FakeCookieStorage())
        }
        return Text(workOffline ? "Offline" : "Online")
    }
}
