import UIKit
import XCTest

@testable import Schrift

@MainActor final class ImageLoaderTests: XCTestCase {
    private var directory: URL!
    private var scope: ImageCacheScope?
    private let origin = "https://docs.example.org"
    private let url = URL(string: "https://docs.example.org/media/photo.png")!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        scope = ImageCacheScope(serverOrigin: origin, sessionID: UUID())
    }

    override func tearDown() {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
    }

    private func loader(cache: ImageCacheStore? = nil) -> ImageLoader {
        ImageLoader(
            scopeProvider: { self.scope }, cache: cache ?? ImageCacheStore(directory: directory),
            fetch: { url, cookies in
                try await ImageTransport(session: MockURLProtocol.makeSession()).data(for: url, cookies: cookies)
            }, cookieProvider: { _ in [] })
    }

    private func stub(log: RequestRecorder, gate: MockURLProtocol.ResponseGate? = nil, status: Int = 200) {
        let bytes = testPNGData(width: 80, height: 40)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(
                statusCode: status, headers: ["Content-Type": "image/png"], body: bytes, error: nil, releasedBy: gate)
        }
    }

    func testViewedImageSurvivesModeReappearanceAndColdOfflineRelaunch() async throws {
        let log = RequestRecorder()
        stub(log: log)
        let online = loader()
        await online.loadIfNeeded(url)
        XCTAssertNotNil(online.image(for: url))
        await online.loadIfNeeded(url)
        let cold = loader()
        await cold.loadIfNeeded(url, allowsNetwork: false)
        XCTAssertNotNil(cold.image(for: url))
        XCTAssertEqual(log.methods, ["GET"])
    }

    func testColdOfflineMissMakesNoRequest() async {
        let log = RequestRecorder()
        stub(log: log)
        let subject = loader()
        await subject.loadIfNeeded(url, allowsNetwork: false)
        XCTAssertEqual(subject.state(for: url), .unavailableOffline)
        XCTAssertTrue(log.methods.isEmpty)
    }

    func testDuplicateRequestsJoinAndViewCancellationDoesNotKillDownload() async {
        let log = RequestRecorder()
        let gate = MockURLProtocol.ResponseGate()
        stub(log: log, gate: gate)
        let subject = loader()
        let reading = Task { await subject.loadIfNeeded(url) }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        reading.cancel()
        let editing = Task { await subject.loadIfNeeded(url) }
        XCTAssertEqual(subject.state(for: url), .loading)
        gate.open()
        await reading.value
        await editing.value
        XCTAssertEqual(log.methods, ["GET"])
        XCTAssertNotNil(subject.image(for: url))
    }

    func testAccountReplacementHidesOldImageAndRejectsLateResult() async {
        let log = RequestRecorder()
        let gate = MockURLProtocol.ResponseGate()
        stub(log: log, gate: gate)
        let subject = loader()
        let oldScope = scope!
        let pending = Task { await subject.loadIfNeeded(url) }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        scope = ImageCacheScope(serverOrigin: origin, sessionID: UUID())
        XCTAssertNil(subject.image(for: url))
        gate.open()
        await pending.value
        XCTAssertNil(ImageCacheStore(directory: directory).cachedFileURL(for: url, scope: oldScope))
        await subject.loadIfNeeded(url, allowsNetwork: false)
        XCTAssertEqual(subject.state(for: url), .unavailableOffline)
    }

    func testExternalConsentSurvivesModesButNeverApprovesAChangedURLOrNewSession() async {
        let log = RequestRecorder()
        stub(log: log)
        let external = URL(string: "https://external.example.org/image.png")!
        let changed = URL(string: "https://external.example.org/changed.png")!
        let subject = loader()
        await subject.loadIfNeeded(external)
        XCTAssertEqual(subject.state(for: external), .requiresConsent)
        XCTAssertTrue(log.methods.isEmpty)
        subject.approve(external)
        await subject.loadIfNeeded(external)
        await subject.loadIfNeeded(external)
        XCTAssertNotNil(subject.image(for: external))
        await subject.loadIfNeeded(changed)
        XCTAssertEqual(subject.state(for: changed), .requiresConsent)
        let cold = loader()
        await cold.loadIfNeeded(external, allowsNetwork: false)
        XCTAssertNotNil(cold.image(for: external), "reading existing bytes makes no external request")
        await cold.loadIfNeeded(changed)
        XCTAssertEqual(cold.state(for: changed), .requiresConsent)
        XCTAssertEqual(log.methods, ["GET"])
    }

    func testEvictionIsRecheckedOfflineAndFailureRequiresDeliberateRetry() async {
        let log = RequestRecorder()
        stub(log: log, status: 500)
        let cache = ImageCacheStore(directory: directory)
        let subject = loader(cache: cache)
        await subject.loadIfNeeded(url)
        XCTAssertEqual(subject.state(for: url), .failed)
        await subject.loadIfNeeded(url)
        XCTAssertEqual(log.methods.count, 1)
        stub(log: log)
        await subject.retry(url)
        XCTAssertNotNil(subject.image(for: url))
        cache.removeAll()
        await subject.loadIfNeeded(url, allowsNetwork: false)
        XCTAssertNil(subject.image(for: url))
        XCTAssertEqual(subject.state(for: url), .unavailableOffline)
        XCTAssertEqual(log.methods.count, 2)
    }

    func testUnknownSessionAndNonHTTPURLsFailClosed() async {
        let log = RequestRecorder()
        stub(log: log)
        let subject = loader()
        scope = nil
        await subject.loadIfNeeded(url)
        XCTAssertTrue(log.methods.isEmpty)
        scope = ImageCacheScope(serverOrigin: origin, sessionID: UUID())
        let file = URL(string: "file:///private/tmp/photo")!
        subject.approve(file)
        await subject.loadIfNeeded(file)
        XCTAssertEqual(subject.state(for: file), .failed)
        XCTAssertTrue(log.methods.isEmpty)
    }

    func testExternalConsentNeverConsultsServerCookiesAndExpiresWithNamespace() async {
        let log = RequestRecorder()
        stub(log: log)
        var cookieReads = 0
        let subject = ImageLoader(
            scopeProvider: { self.scope }, cache: ImageCacheStore(directory: directory),
            fetch: { url, cookies in
                try await ImageTransport(session: MockURLProtocol.makeSession()).data(for: url, cookies: cookies)
            },
            cookieProvider: { _ in
                cookieReads += 1
                return []
            })
        let external = URL(string: "https://external.example.org/image.png")!
        subject.approve(external)
        await subject.loadIfNeeded(external)
        XCTAssertEqual(cookieReads, 0)
        scope = ImageCacheScope(serverOrigin: origin, sessionID: UUID())
        await subject.loadIfNeeded(external)
        XCTAssertEqual(subject.state(for: external), .requiresConsent)
        XCTAssertEqual(log.methods, ["GET"])
    }

    func testApprovedExternalURLRequiresConsentAgainAfterColdEvictedReopen() async {
        let log = RequestRecorder()
        stub(log: log)
        let cache = ImageCacheStore(directory: directory)
        let subject = loader(cache: cache)
        let external = URL(string: "https://external.example.org/image.png")!
        subject.approve(external)
        await subject.loadIfNeeded(external)
        cache.removeAll()
        let cold = loader(cache: cache)
        await cold.loadIfNeeded(external)
        XCTAssertEqual(cold.state(for: external), .requiresConsent)
        XCTAssertEqual(log.methods, ["GET"])
    }

    func testFailedConfirmationCannotReuseNewAccountImagesUnderRestoredOldCookies() async throws {
        try await assertReplacementNamespaceIsNotRestored(confirm: false)
    }

    func testFailedCookieSnapshotCannotReuseNewAccountImagesUnderRestoredOldCookies() async throws {
        try await assertReplacementNamespaceIsNotRestored(confirm: true)
    }

    private func assertReplacementNamespaceIsNotRestored(confirm: Bool) async throws {
        let suite = "ImageLoaderTests.session.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = FakeKeychainStore()
        let storage = FakeCookieStorage()
        func cookie(_ value: String) -> HTTPCookie {
            HTTPCookie(properties: [.domain: "docs.example.org", .path: "/", .name: "sessionid", .value: value])!
        }
        let accountA = cookie("fixture-account-a")
        let accountB = cookie("fixture-account-b")
        storage.setCookie(accountA)
        let session = SessionStore(userDefaults: defaults, keychain: keychain, cookieStorage: storage)
        try session.signIn(serverURL: URL(string: origin)!)
        storage.setCookie(accountB)
        session.noteSessionCookiesReplaced()
        // This is the exact window after the web login installed B's cookies but
        // before confirming /users/me (which may fail). A failed cookie snapshot
        // must be equally unable to couple B's cache to A's restored session.
        if confirm {
            keychain.failingSaveKeys = ["dev.llun.Schrift.sessionCookies"]
            try session.signIn(serverURL: URL(string: origin)!)
        }
        let cache = ImageCacheStore(directory: directory)
        let bScope = ImageCacheScope(serverOrigin: origin, sessionID: try XCTUnwrap(session.imageCacheSessionID))
        XCTAssertNotNil(cache.store(testPNGData(width: 80, height: 40), for: url, scope: bScope))
        let coldStorage = FakeCookieStorage()
        let cold = SessionStore(userDefaults: defaults, keychain: keychain, cookieStorage: coldStorage)
        XCTAssertEqual(
            coldStorage.cookies(for: URL(string: origin)!)?.first(where: { $0.name == "sessionid" })?.value,
            accountA.value)
        let restoredScope = ImageCacheScope(serverOrigin: origin, sessionID: try XCTUnwrap(cold.imageCacheSessionID))
        XCTAssertNotEqual(restoredScope, bScope)
        let subject = ImageLoader(
            scopeProvider: { restoredScope }, cache: cache,
            fetch: { _, _ in
                XCTFail("Cold offline reopen must not fetch")
                throw URLError(.notConnectedToInternet)
            },
            cookieProvider: { _ in [] })
        await subject.loadIfNeeded(url, allowsNetwork: false)
        XCTAssertNil(subject.image(for: url))
        XCTAssertEqual(subject.state(for: url), .unavailableOffline)
    }

    func testFailedImageDoesNotAutomaticallyRetryAcrossOfflineOnlineTransitions() async {
        let log = RequestRecorder()
        stub(log: log, status: 500)
        let subject = loader()
        await subject.loadIfNeeded(url)
        await subject.loadIfNeeded(url, allowsNetwork: false)
        await subject.loadIfNeeded(url)
        XCTAssertEqual(log.methods, ["GET"])
        await subject.retry(url)
        XCTAssertEqual(log.methods, ["GET", "GET"])
    }

    func testPreparedImagesAreReusedWithoutBodyOrModeTransitionDecoding() async {
        actor DecodeCounter {
            var count = 0
            func record() { count += 1 }
        }
        let counter = DecodeCounter()
        let log = RequestRecorder()
        stub(log: log)
        let subject = ImageLoader(
            scopeProvider: { self.scope }, cache: ImageCacheStore(directory: directory),
            fetch: { url, cookies in
                try await ImageTransport(session: MockURLProtocol.makeSession()).data(for: url, cookies: cookies)
            },
            decode: { data in
                await counter.record()
                return displayedImage(from: data)
            }, cookieProvider: { _ in [] })
        await subject.loadIfNeeded(url)
        for _ in 0..<20 { XCTAssertNotNil(subject.image(for: url)) }
        await subject.loadIfNeeded(url, allowsNetwork: false)
        XCTAssertNotNil(subject.image(for: url))
        let decodes = await counter.count
        XCTAssertEqual(decodes, 1)
        XCTAssertEqual(log.methods, ["GET"])
    }

    func testOversizedSourceIsRejectedBeforeInvokingDecoder() async {
        actor DecodeCounter {
            var count = 0
            func record() { count += 1 }
        }
        let counter = DecodeCounter()
        // A PNG header advertises 10000 x 10000 pixels, with a valid IHDR CRC.
        // The deliberately tiny payload must never reach the thumbnail decoder.
        let bytes = Data([
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
            0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x27, 0x10, 0x00, 0x00, 0x27, 0x10,
            0x08, 0x06, 0x00, 0x00, 0x00, 0xba, 0x4e, 0x62, 0x27,
            0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
        ])
        let subject = ImageLoader(
            scopeProvider: { self.scope }, cache: ImageCacheStore(directory: directory),
            fetch: { _, _ in bytes },
            decode: { _ in
                await counter.record()
                return nil
            }, cookieProvider: { _ in [] })
        await subject.loadIfNeeded(url)
        XCTAssertEqual(subject.state(for: url), .failed)
        let decodes = await counter.count
        XCTAssertEqual(decodes, 0)
        XCTAssertNil(ImageCacheStore(directory: directory).cachedFileURL(for: url, scope: scope!))
    }

    func testConcurrentPreparedResultsSurviveDecodedCacheEviction() async throws {
        let bytes = testPNGData(width: 2048, height: 2048)
        let image = try XCTUnwrap(displayedImage(from: bytes))
        let memory = NSCache<NSURL, UIImage>()
        let subject = ImageLoader(
            scopeProvider: { self.scope }, cache: ImageCacheStore(directory: directory),
            decodedCache: memory, fetch: { _, _ in bytes }, decode: { _ in image }, cookieProvider: { _ in [] })
        let urls = (0..<5).map { URL(string: "\(origin)/media/large-\($0).png")! }
        let loads = urls.map { url in Task { await subject.loadIfNeeded(url) } }
        var delivered: [UIImage] = []
        for load in loads {
            let prepared: UIImage? = await load.value
            delivered.append(try XCTUnwrap(prepared))
        }
        // Five 2048px thumbnails exceed the 48 MiB reuse budget. A leaf's direct
        // result must remain valid even if all reuse entries disappear meanwhile.
        memory.removeAllObjects()
        XCTAssertEqual(delivered.count, 5)
        XCTAssertTrue(urls.allSatisfy { subject.image(for: $0) == nil })
        XCTAssertTrue(delivered.allSatisfy { $0.cgImage?.width == 2048 })
    }

    func testInvalidImageBytesAreNeverCached() async {
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: Data("<html>no</html>".utf8), error: nil)
        }
        let subject = loader()
        await subject.loadIfNeeded(url)
        XCTAssertEqual(subject.state(for: url), .failed)
        XCTAssertNil(ImageCacheStore(directory: directory).cachedFileURL(for: url, scope: scope!))
    }

    func testATransportFailureIsRetriedOnceWhenLoadingResumesOnline() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        let subject = loader()
        await subject.loadIfNeeded(url)
        XCTAssertEqual(subject.state(for: url), .failed)
        await subject.loadIfNeeded(url, allowsNetwork: false)
        XCTAssertEqual(subject.state(for: url), .failed, "still offline: no request, state kept")
        XCTAssertEqual(log.methods.count, 1)

        stub(log: log)
        await subject.loadIfNeeded(url)
        XCTAssertNotNil(subject.image(for: url))
        XCTAssertEqual(log.methods.count, 2)
    }

    func testAnAutomaticRetryThatFailsAgainIsRetryOnly() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.timedOut))
        }
        let subject = loader()
        await subject.loadIfNeeded(url)
        await subject.loadIfNeeded(url)
        await subject.loadIfNeeded(url)
        XCTAssertEqual(log.methods.count, 2)
        XCTAssertEqual(subject.state(for: url), .failed)
    }

    func testAContentFailureIsNotRetriedAutomatically() async {
        let log = RequestRecorder()
        stub(log: log, status: 404)
        let subject = loader()
        await subject.loadIfNeeded(url)
        XCTAssertEqual(subject.state(for: url), .failed)
        stub(log: log)
        await subject.loadIfNeeded(url)
        XCTAssertEqual(subject.state(for: url), .failed)
        XCTAssertEqual(log.methods.count, 1)
    }

    func testATransportFailureDoesNotBypassConsentOnRetry() async {
        let external = URL(string: "https://cdn.example.net/photo.png")!
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        let subject = loader()
        subject.approve(external)
        await subject.loadIfNeeded(external)
        XCTAssertEqual(subject.state(for: external), .failed)
        let other = URL(string: "https://cdn.example.net/other.png")!
        await subject.loadIfNeeded(other)
        XCTAssertEqual(subject.state(for: other), .requiresConsent)
        XCTAssertEqual(log.methods.count, 1)
    }
}
