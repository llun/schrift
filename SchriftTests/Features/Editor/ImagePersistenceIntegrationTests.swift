import SwiftUI
import XCTest

@testable import Schrift

@MainActor
final class ImagePersistenceIntegrationTests: XCTestCase {
    private var directory: URL!
    private let origin = "https://docs.example.org"
    private var scope: String? = "account-a"
    private var requests: [URL] = []

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        MockURLProtocol.reset()
        super.tearDown()
    }

    private var url: URL { URL(string: "\(origin)/media/photo.png?version=1")! }
    private var png: Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 12))
        return renderer.pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        }
    }

    private func loader(cache: ImageCacheStore? = nil) -> ImageLoader {
        ImageLoader(
            serverOrigin: origin, cache: cache ?? ImageCacheStore(directory: directory),
            scopeProvider: { self.scope },
            fetch: { url, _ in
                self.requests.append(url)
                return self.png
            })
    }

    func testOnlineDisplaySurvivesModeChangesReopeningAndColdOfflineLaunch() async throws {
        let first = loader()
        await first.loadIfNeeded(url, allowsNetwork: true)
        await first.loadIfNeeded(url, allowsNetwork: true)
        XCTAssertEqual(requests, [url])
        let cold = loader()
        await cold.loadIfNeeded(url, allowsNetwork: false)
        guard case .cached(let file) = cold.state(for: url) else { return XCTFail("Missing offline image") }
        XCTAssertNotNil(imageThumbnail(at: file))
        XCTAssertEqual(requests.count, 1)
    }

    func testUncachedOfflineImageHasAnExplicitStateAndNoRequest() async {
        let subject = loader()
        await subject.loadIfNeeded(url, allowsNetwork: false)
        XCTAssertEqual(subject.state(for: url), .unavailableOffline)
        XCTAssertTrue(requests.isEmpty)
        await subject.loadIfNeeded(url, allowsNetwork: true)
        guard case .cached = subject.state(for: url) else { return XCTFail("Reconnect did not load") }
    }

    func testExternalConsentIsRequiredForEveryExactURLButCachedBytesNeedNoNetworkConsent() async {
        let external = URL(string: "https://external.example/photo.png")!
        let changed = URL(string: "https://external.example/other.png")!
        let subject = loader()
        await subject.loadIfNeeded(external, allowsNetwork: true)
        XCTAssertEqual(subject.state(for: external), .requiresConsent)
        XCTAssertTrue(requests.isEmpty)
        await subject.loadIfNeeded(external, allowsNetwork: true, approvedURL: external)
        await subject.loadIfNeeded(changed, allowsNetwork: true, approvedURL: external)
        XCTAssertEqual(requests, [external])
        let cold = loader()
        await cold.loadIfNeeded(external, allowsNetwork: false)
        guard case .cached = cold.state(for: external) else { return XCTFail("Cached consented image lost") }
    }

    func testChangedURLsAndAccountsCannotReuseCachedBytesOrConsent() async {
        let subject = loader()
        await subject.loadIfNeeded(url, allowsNetwork: true)
        let changed = URL(string: "\(origin)/media/photo.png?version=2")!
        await subject.loadIfNeeded(changed, allowsNetwork: false)
        XCTAssertEqual(subject.state(for: changed), .unavailableOffline)
        scope = "account-b"
        XCTAssertEqual(subject.state(for: url), .idle)
        await subject.loadIfNeeded(url, allowsNetwork: false)
        XCTAssertEqual(subject.state(for: url), .unavailableOffline)
        scope = nil
        await subject.loadIfNeeded(url, allowsNetwork: true)
        XCTAssertEqual(subject.state(for: url), .unavailableOffline)
        XCTAssertEqual(requests.count, 1)
    }

    func testConcurrentRequestsJoinAndSurviveSurfaceCancellation() async {
        let gate = MockURLProtocol.ResponseGate()
        let log = RequestRecorder()
        let bytes = png
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 200, headers: [:], body: bytes, error: nil, releasedBy: gate)
        }
        let client = ImageDataClient(session: MockURLProtocol.makeSession(), cookieProvider: { _ in [] })
        let subject = ImageLoader(
            serverOrigin: origin, cache: ImageCacheStore(directory: directory),
            scopeProvider: { self.scope },
            fetch: { url, origin in try await client.data(for: url, serverOrigin: origin) })
        let reading = Task { await subject.loadIfNeeded(url, allowsNetwork: true) }
        await waitUntil { log.methods.count == 1 }
        let editing = Task { await subject.loadIfNeeded(url, allowsNetwork: true) }
        reading.cancel()
        gate.open()
        await editing.value
        await reading.value
        XCTAssertEqual(log.methods.count, 1)
        guard case .cached = subject.state(for: url) else { return XCTFail("Surface cancellation lost image") }
    }

    func testAccountChangeDuringDownloadCannotPublishOrPersistOldResponse() async {
        let gate = MockURLProtocol.ResponseGate()
        let log = RequestRecorder()
        let bytes = png
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 200, headers: [:], body: bytes, error: nil, releasedBy: gate)
        }
        let cache = ImageCacheStore(directory: directory)
        let client = ImageDataClient(session: MockURLProtocol.makeSession(), cookieProvider: { _ in [] })
        let subject = ImageLoader(
            serverOrigin: origin, cache: cache, scopeProvider: { self.scope },
            fetch: { url, origin in try await client.data(for: url, serverOrigin: origin) })
        let old = Task { await subject.loadIfNeeded(url, allowsNetwork: true) }
        await waitUntil { log.methods.count == 1 }
        scope = "account-b"
        gate.open()
        await old.value
        XCTAssertEqual(subject.state(for: url), .idle)
        XCTAssertNil(cache.cachedFileURL(for: url, serverOrigin: origin, scope: "account-a"))
    }

    func testEvictionInvalidatesStateAndStrictlyCapsBytesAndCount() async throws {
        let cache = ImageCacheStore(directory: directory, countLimit: 1, byteLimit: 4096)
        let subject = loader(cache: cache)
        await subject.loadIfNeeded(url, allowsNetwork: true)
        let other = URL(string: "\(origin)/media/other.png")!
        await subject.loadIfNeeded(other, allowsNetwork: true)
        await subject.loadIfNeeded(url, allowsNetwork: false)
        XCTAssertEqual(subject.state(for: url), .unavailableOffline)
        XCTAssertNil(cache.store(Data(repeating: 0, count: 4097), for: url, serverOrigin: origin, scope: "account-a"))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
    }

    func testFailureKeepsImageIdentityAndRetriesOnlyOnRequest() async {
        let subject = ImageLoader(
            serverOrigin: origin, cache: ImageCacheStore(directory: directory),
            scopeProvider: { self.scope },
            fetch: { url, _ in
                self.requests.append(url)
                if self.requests.count == 1 { throw URLError(.badServerResponse) }
                return self.png
            })
        await subject.loadIfNeeded(url, allowsNetwork: true)
        XCTAssertEqual(subject.state(for: url), .failed)
        await subject.loadIfNeeded(url, allowsNetwork: true)
        XCTAssertEqual(requests.count, 1)
        await subject.loadIfNeeded(url, allowsNetwork: true, retry: true)
        guard case .cached = subject.state(for: url) else { return XCTFail("Retry failed") }
        let markdown = "![photo](\(url.absoluteString))"
        let blocks = parseEditorBlocks(markdown, serverOrigin: origin)
        XCTAssertEqual(blocks.first?.kind, .image(alt: "photo", url: url.absoluteString))
        XCTAssertEqual(serializeMarkdown(blocks), markdown + "\n")
    }

    func testCacheRejectsInvalidImagesAndUsesReadRecencyForEviction() throws {
        let cache = ImageCacheStore(directory: directory, countLimit: 2)
        XCTAssertNil(cache.store(Data("not an image".utf8), for: url, serverOrigin: origin, scope: "account-a"))
        let first = try XCTUnwrap(cache.store(png, for: url, serverOrigin: origin, scope: "account-a"))
        let other = URL(string: "\(origin)/media/other.png")!
        let second = try XCTUnwrap(cache.store(png, for: other, serverOrigin: origin, scope: "account-a"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: first.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-300)], ofItemAtPath: second.path)
        XCTAssertNotNil(cache.cachedFileURL(for: url, serverOrigin: origin, scope: "account-a"))
        let third = URL(string: "\(origin)/media/third.png")!
        XCTAssertNotNil(cache.store(png, for: third, serverOrigin: origin, scope: "account-a"))
        XCTAssertNotNil(cache.cachedFileURL(for: url, serverOrigin: origin, scope: "account-a"))
        XCTAssertNil(cache.cachedFileURL(for: other, serverOrigin: origin, scope: "account-a"))
        let attributes = try first.resourceValues(forKeys: [.isExcludedFromBackupKey])
        let folderAttributes = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertTrue(attributes.isExcludedFromBackup == true || folderAttributes.isExcludedFromBackup == true)
    }

    func testServerIsolationAndExactURLKeyIncludesQueryAndDocumentPath() {
        let cache = ImageCacheStore(directory: directory)
        XCTAssertNotNil(cache.store(png, for: url, serverOrigin: origin, scope: "account-a"))
        XCTAssertNil(cache.cachedFileURL(for: url, serverOrigin: "https://other.example", scope: "account-a"))
        XCTAssertNil(
            cache.cachedFileURL(
                for: URL(string: "\(origin)/other/photo.png?version=1")!, serverOrigin: origin, scope: "account-a"))
    }
}
