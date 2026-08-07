import XCTest

@testable import Schrift

@MainActor
final class AttachmentLoaderTests: XCTestCase {
    private let serverOrigin = "https://docs.example.org"
    private let documentUUID = "11111111-1111-4111-8111-111111111111"
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentLoaderTests.\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    private func makeCache() -> AttachmentCacheStore {
        AttachmentCacheStore(directory: directory)
    }

    private func makeLoader(cache: AttachmentCacheStore? = nil, serverOrigin origin: String? = nil) -> AttachmentLoader
    {
        let client = DocsAPIClient(
            baseURL: URL(string: "https://docs.example.org/api/v1.0/")!,
            session: MockURLProtocol.makeSession(),
            cookieProvider: { [] })
        return AttachmentLoader(
            client: client, serverOrigin: origin ?? serverOrigin, cache: cache ?? makeCache())
    }

    private func makeDisplay(
        fileUUID: String = "22222222-2222-4222-8222-222222222222",
        origin: String? = nil
    ) throws -> AttachmentDisplay {
        let base = origin ?? serverOrigin
        let url = "\(base)/media/\(documentUUID)/attachments/\(fileUUID).pdf"
        return try XCTUnwrap(parseAttachmentLink("[Report.pdf](\(url))", serverOrigin: base))
    }

    private func stub(_ payload: Data, delay: TimeInterval = 0, log: RequestRecorder? = nil) {
        MockURLProtocol.stubHandler = { request in
            log?.record(request)
            return .init(statusCode: 200, headers: [:], body: payload, error: nil, delay: delay)
        }
    }

    // MARK: - Downloading

    func testDownloadsCachesAndPublishesTheFileURL() async throws {
        let payload = Data([0x25, 0x50, 0x44, 0x46, 0x00, 0xFF])
        let log = RequestRecorder()
        stub(payload, log: log)
        let loader = makeLoader()
        let display = try makeDisplay()

        await loader.loadIfNeeded(display)

        guard case .cached(let url) = loader.state(for: display) else {
            return XCTFail("Expected .cached, got \(String(describing: loader.state(for: display)))")
        }
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertEqual(url.lastPathComponent, "22222222-2222-4222-8222-222222222222.pdf")
        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "/media/"), 1)
    }

    func testTheDownloadTargetsTheRootedMediaPath() async throws {
        let log = RequestRecorder()
        stub(Data([1]), log: log)

        await makeLoader().loadIfNeeded(try makeDisplay())

        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "GET")
        XCTAssertEqual(
            MockURLProtocol.lastRequest?.url?.absoluteString,
            "https://docs.example.org/media/\(documentUUID)/attachments/22222222-2222-4222-8222-222222222222.pdf")
    }

    func testAnAlreadyCachedAttachmentIssuesNoRequest() async throws {
        let cache = makeCache()
        let display = try makeDisplay()
        _ = cache.store(Data([1, 2, 3]), for: display)
        let log = RequestRecorder()
        stub(Data([9]), log: log)

        let loader = makeLoader(cache: cache)
        await loader.loadIfNeeded(display)

        XCTAssertTrue(log.methods.isEmpty, "a disk hit must not hit the network")
        guard case .cached(let url) = loader.state(for: display) else {
            return XCTFail("Expected .cached, got \(String(describing: loader.state(for: display)))")
        }
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
    }

    /// Eviction can delete a cached file while a card still holds `.cached` for
    /// it. Without re-checking the disk the card would open QuickLook on nothing
    /// and never recover, because `loadIfNeeded` short-circuits on `.cached`.
    func testAnEvictedCachedAttachmentIsDownloadedAgain() async throws {
        let cache = makeCache()
        let display = try makeDisplay()
        let loader = makeLoader(cache: cache)
        stub(Data([1, 2, 3]))
        await loader.loadIfNeeded(display)
        guard case .cached(let first) = loader.state(for: display) else {
            return XCTFail("Expected .cached after the first load")
        }

        // Something else fills the cache and this file is evicted.
        try FileManager.default.removeItem(at: first)
        stub(Data([4, 5, 6]))
        await loader.loadIfNeeded(display)

        guard case .cached(let second) = loader.state(for: display) else {
            return XCTFail("Expected .cached again, got \(String(describing: loader.state(for: display)))")
        }
        XCTAssertEqual(try Data(contentsOf: second), Data([4, 5, 6]))
    }

    /// The store's recency is last *use*, so a card the reader keeps returning
    /// to has to bump it — not just the first load of the session.
    func testLoadingAnAlreadyCachedAttachmentBumpsItsRecency() async throws {
        let cache = makeCache()
        let display = try makeDisplay()
        let loader = makeLoader(cache: cache)
        stub(Data([1]))
        await loader.loadIfNeeded(display)
        let file = directory.appendingPathComponent(attachmentFileName(for: display), isDirectory: false)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: file.path)

        await loader.loadIfNeeded(display)

        let mtime = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        XCTAssertGreaterThan(mtime.timeIntervalSinceNow, -60, "a re-load must refresh the entry's recency")
    }

    func testASecondLoadOfTheSameAttachmentIssuesNoSecondRequest() async throws {
        let log = RequestRecorder()
        stub(Data([1]), log: log)
        let loader = makeLoader()
        let display = try makeDisplay()

        await loader.loadIfNeeded(display)
        await loader.loadIfNeeded(display)

        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "/media/"), 1)
    }

    /// Two cards showing the same attachment — the reason the loader is
    /// app-scoped rather than per-view.
    func testConcurrentLoadsOfTheSameAttachmentDownloadOnce() async throws {
        let log = RequestRecorder()
        stub(Data([1, 2, 3]), delay: 0.15, log: log)
        let loader = makeLoader()
        let display = try makeDisplay()

        async let first: Void = loader.loadIfNeeded(display)
        async let second: Void = loader.loadIfNeeded(display)
        _ = await (first, second)

        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "/media/"), 1)
        guard case .cached = loader.state(for: display) else {
            return XCTFail("Expected .cached, got \(String(describing: loader.state(for: display)))")
        }
    }

    func testDistinctAttachmentsGetDistinctStates() async throws {
        stub(Data([1]))
        let loader = makeLoader()
        let first = try makeDisplay()
        let second = try makeDisplay(fileUUID: "33333333-3333-4333-8333-333333333333")

        await loader.loadIfNeeded(first)
        XCTAssertNil(loader.state(for: second))

        await loader.loadIfNeeded(second)
        guard case .cached(let firstURL) = loader.state(for: first),
            case .cached(let secondURL) = loader.state(for: second)
        else { return XCTFail("Expected both cached") }
        XCTAssertNotEqual(firstURL, secondURL)
    }

    // MARK: - Failure and retry

    func testAFailedDownloadPublishesFailed() async throws {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        let loader = makeLoader()
        let display = try makeDisplay()

        await loader.loadIfNeeded(display)

        XCTAssertEqual(loader.state(for: display), .failed)
    }

    func testForbiddenPublishesFailedRatherThanCachingAnErrorBody() async throws {
        // A 403 body is JSON, not the attachment: caching it would make the
        // card preview an error page forever.
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 403, headers: [:], body: Data(#"{"detail":"nope"}"#.utf8), error: nil)
        }
        let cache = makeCache()
        let display = try makeDisplay()

        await makeLoader(cache: cache).loadIfNeeded(display)

        XCTAssertNil(cache.cachedFileURL(for: display))
    }

    /// Auto-retrying on every reappear would hammer a failing server as the user
    /// scrolls; the card's retry affordance is the way back.
    func testLoadIfNeededDoesNotAutomaticallyRetryAFailure() async throws {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }
        let loader = makeLoader()
        let display = try makeDisplay()

        await loader.loadIfNeeded(display)
        await loader.loadIfNeeded(display)

        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "/media/"), 1)
        XCTAssertEqual(loader.state(for: display), .failed)
    }

    func testRetryAfterAFailureCanSucceed() async throws {
        let attempts = Counter()
        MockURLProtocol.stubHandler = { _ in
            attempts.next() == 1
                ? .init(statusCode: 500, headers: [:], body: Data(), error: nil)
                : .init(statusCode: 200, headers: [:], body: Data([7, 7]), error: nil)
        }
        let loader = makeLoader()
        let display = try makeDisplay()

        await loader.loadIfNeeded(display)
        XCTAssertEqual(loader.state(for: display), .failed)

        await loader.retry(display)

        guard case .cached(let url) = loader.state(for: display) else {
            return XCTFail("Expected .cached after retry, got \(String(describing: loader.state(for: display)))")
        }
        XCTAssertEqual(try Data(contentsOf: url), Data([7, 7]))
    }

    // MARK: - Origin

    /// Defense in depth: the classifier already refuses an off-origin url, but
    /// this is the layer that issues the request and its input is a freely
    /// constructible value type.
    func testAnOffOriginDisplayIsRefusedWithoutARequest() async throws {
        let log = RequestRecorder()
        stub(Data([1]), log: log)
        // Classified against a *different* server, then handed to this loader.
        let foreign = try makeDisplay(origin: "https://other.example.org")

        let loader = makeLoader()
        await loader.loadIfNeeded(foreign)

        XCTAssertEqual(loader.state(for: foreign), .failed)
        XCTAssertTrue(log.methods.isEmpty, "must not issue a request for an off-origin attachment")
    }

    func testAnEmptyServerOriginRefusesEverything() async throws {
        let log = RequestRecorder()
        stub(Data([1]), log: log)

        let loader = makeLoader(serverOrigin: "")
        let display = try makeDisplay()
        await loader.loadIfNeeded(display)

        XCTAssertEqual(loader.state(for: display), .failed)
        XCTAssertTrue(log.methods.isEmpty)
    }
}
