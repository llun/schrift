import AVFoundation
import CoreMedia
import CoreVideo
import UIKit
import XCTest

@testable import Schrift

@MainActor
final class VideoPosterTests: NativeEditingTestCase {
    private static let origin = "https://example.test"
    private static let documentID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private static let fileID = UUID(uuidString: "66666666-7777-4888-8999-aaaaaaaaaaaa")!
    private static let ownerID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!

    private var cleanup: [URL] = []

    override func tearDown() async throws {
        MockURLProtocol.reset()
        for url in cleanup { try? FileManager.default.removeItem(at: url) }
        cleanup = []
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func tempDir(_ label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("VideoPosterTests-\(label)-\(UUID())")
        cleanup.append(dir)
        return dir
    }

    private func scope(origin: String = origin) -> ImageCacheScope {
        ImageCacheScope(serverOrigin: origin, sessionID: "session-\(UUID().uuidString)")
    }

    private func videoBlock(
        _ id: String,
        url: String,
        name: String = "clip.mp4",
        caption: String = "",
        showPreview: Bool? = true,
        previewWidth: YAnyValue = .undefined
    ) -> BlockNoteBlock {
        var props: [(String, YAnyValue)] = [
            ("backgroundColor", .string("default")),
            ("caption", .string(caption)),
            ("name", .string(name)),
            ("previewWidth", previewWidth),
            ("textAlignment", .string("left")),
            ("url", .string(url)),
        ]
        if let showPreview {
            props.append(("showPreview", .bool(showPreview)))
        }
        return BlockNoteBlock(node: "video", props: props, runs: [], id: id)
    }

    private nonisolated static func makeTestVideoData(
        width: Int,
        height: Int,
        transform: CGAffineTransform = .identity,
        fileType: AVFileType = .mp4
    ) async throws -> Data {
        let ext: String =
            switch fileType {
            case .mov: "mov"
            case .mobile3GPP: "3gp"
            default: "mp4"
            }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("synth-\(UUID()).\(ext)")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.transform = transform
        input.expectsMediaDataInRealTime = false

        let pixelAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pixelAttrs
        )
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), "writer starts cleanly")
        writer.startSession(atSourceTime: .zero)

        let timestamps = [
            CMTime.zero,
            CMTime(seconds: 0.2, preferredTimescale: 600),
            CMTime(seconds: 0.4, preferredTimescale: 600),
        ]
        for (frameIndex, time) in timestamps.enumerated() {
            var spin = 0
            while !input.isReadyForMoreMediaData && spin < 1000 {
                spin += 1
                try? await Task.sleep(for: .milliseconds(2))
            }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                pixelAttrs as CFDictionary, &buffer
            )
            XCTAssertEqual(status, kCVReturnSuccess)
            let pixelBuffer = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                let fill: UInt8 = frameIndex == 0 ? 0x33 : 0xCC
                memset(base, Int32(fill), bytesPerRow * height)
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: time))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
        return try Data(contentsOf: url)
    }

    @MainActor
    private final class StubTransport {
        var urls: [URL] = []
        let responder: (URL) async throws -> (data: Data, mimeType: String?)

        init(responder: @escaping (URL) async throws -> (data: Data, mimeType: String?)) {
            self.responder = responder
        }

        func fetch(_ url: URL, cookies _: [HTTPCookie]) async throws -> (data: Data, mimeType: String?) {
            urls.append(url)
            let result = try await responder(url)
            if result.data.count > VideoPosterLoader.maxAutoFetchBytes {
                throw URLError(.dataLengthExceedsMaximum)
            }
            return result
        }
    }

    private func makeLoader(
        scope: ImageCacheScope,
        cacheDir: URL? = nil,
        attachmentDir: URL? = nil,
        scratchDir: URL? = nil,
        transport: StubTransport
    ) -> (loader: VideoPosterLoader, cache: ImageCacheStore, attachments: AttachmentCacheStore) {
        let cache = ImageCacheStore(directory: cacheDir ?? tempDir("posters"))
        let attachments = AttachmentCacheStore(directory: attachmentDir ?? tempDir("attachments"))
        let scratch = scratchDir ?? tempDir("scratch")
        let loader = VideoPosterLoader(
            cache: cache,
            attachmentCache: attachments,
            fetch: { [transport] url, cookies in try await transport.fetch(url, cookies: cookies) },
            cookieProvider: { _ in [] },
            scopeProvider: { scope },
            scratchDirectory: scratch
        )
        return (loader, cache, attachments)
    }

    private func attachment(_ session: NativeEditorSession, _ id: String) throws -> NativeBlockAttachment {
        let entry = try XCTUnwrap(session.surface.rangeIndex.entry(for: id))
        let value = session.textView.textStorage.attribute(.attachment, at: entry.range.location, effectiveRange: nil)
        return try XCTUnwrap(value as? NativeBlockAttachment)
    }

    private func realized(_ session: NativeEditorSession, _ id: String) -> NativeAttachmentView? {
        session.textView.blockControls.visibleAttachmentViews.first { $0.content.blockID == id }
    }

    private func host(_ view: UIView, width: CGFloat = 390, height: CGFloat = 800) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.frame = window.bounds
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.layoutIfNeeded()
        return window
    }

    private func labels(in view: UIView) -> [UILabel] {
        var result: [UILabel] = []
        var queue = view.subviews
        while let next = queue.popLast() {
            if let label = next as? UILabel { result.append(label) }
            queue += next.subviews
        }
        return result
    }

    // MARK: - Tests

    func testVideoPreviewProjectionRules() async throws {
        let blocks = [
            videoBlock(
                "shown", url: "\(Self.origin)/media/demo.mp4", name: "clip.mp4", caption: "My Caption",
                showPreview: true),
            videoBlock("defaultPreview", url: "\(Self.origin)/media/noflag.mp4", name: "noflag.mp4", showPreview: nil),
            videoBlock("hidden", url: "\(Self.origin)/media/hidden.mp4", name: "hidden.mp4", showPreview: false),
            videoBlock("empty", url: "", name: "pending.mp4", showPreview: true),
        ]
        let harness = try await makeHarness(blocks)
        addTeardownBlock { await harness.close() }

        XCTAssertEqual(
            try attachment(harness.session, "shown").content.preview,
            .video(url: "\(Self.origin)/media/demo.mp4", label: "My Caption", previewWidth: nil)
        )
        XCTAssertEqual(
            try attachment(harness.session, "defaultPreview").content.preview,
            .video(url: "\(Self.origin)/media/noflag.mp4", label: "noflag.mp4", previewWidth: nil)
        )
        XCTAssertEqual(
            try attachment(harness.session, "hidden").content.preview,
            .file(node: "video", name: "hidden.mp4", url: "\(Self.origin)/media/hidden.mp4")
        )
        XCTAssertEqual(
            try attachment(harness.session, "empty").content.preview,
            .file(node: "video", name: "pending.mp4", url: "")
        )
    }

    func testVideoCardPosterLoadPlayBadgeCaptionPillAndAspectRatioRefresh() async throws {
        let mp4 = try await Self.makeTestVideoData(width: 320, height: 160)
        let videoURL =
            "\(Self.origin)/media/\(Self.documentID.uuidString.lowercased())/attachments/\(Self.fileID.uuidString.lowercased()).mp4"
        let harness = try await makeHarness([
            videoBlock("vid", url: videoURL, name: "clip.mp4", caption: "Demo Clip"),
            paragraph("below", "After video"),
        ])
        addTeardownBlock { await harness.close() }

        let transport = StubTransport { _ in (mp4, "video/mp4") }
        let (loader, _, _) = makeLoader(scope: scope(), transport: transport)
        harness.view.blockControls.posters = loader
        harness.view.blockControls.serverOrigin = Self.origin
        let window = host(harness.view)
        defer { window.isHidden = true }

        let before = try attachment(harness.session, "vid")
        XCTAssertEqual(before.content.size.height, NativeAttachmentLayout.placeholderImageHeight)
        let view = try XCTUnwrap(realized(harness.session, "vid"))
        await view.loadTask?.value
        harness.view.layoutIfNeeded()

        let usable = harness.session.surface.attachmentGeometry.usableWidth
        let refreshedAttachment = try attachment(harness.session, "vid")
        XCTAssertEqual(refreshedAttachment.content.size.height, ceil(usable / 2), accuracy: 1)

        let refreshedView = try XCTUnwrap(realized(harness.session, "vid"))
        let loadedPoster = try XCTUnwrap(refreshedView.imageView?.image)
        XCTAssertEqual(loadedPoster.size.width / loadedPoster.size.height, 2.0, accuracy: 0.05)
        XCTAssertNil(refreshedView.loadTask)
        XCTAssertEqual(transport.urls.count, 1)

        let playBadge = try XCTUnwrap(refreshedView.videoPlayBadge)
        XCTAssertFalse(playBadge.isHidden)
        XCTAssertEqual(playBadge.bounds.size, CGSize(width: 44, height: 44))

        let pill = try XCTUnwrap(refreshedView.videoCaptionPill)
        XCTAssertFalse(pill.isHidden)
        let pillLabel = try XCTUnwrap(labels(in: pill).first)
        XCTAssertEqual(pillLabel.text, "Demo Clip")
        XCTAssertEqual(pillLabel.tag, 2)
        refreshedView.applyTheme()
        XCTAssertEqual(pillLabel.textColor, .white, "theme updates keep white text on caption pill")
    }

    func testPortraitPreferredTransformIsApplied() async throws {
        // 320x160 coded pixels rotated 90 degrees clockwise => 160x320 portrait display (~0.5 ratio).
        let mov = try await Self.makeTestVideoData(
            width: 320, height: 160,
            transform: CGAffineTransform(rotationAngle: .pi / 2),
            fileType: .mov
        )
        let videoURL = URL(string: "\(Self.origin)/media/portrait.mov")!
        let transport = StubTransport { _ in (mov, "video/quicktime") }
        let (loader, _, _) = makeLoader(scope: scope(), transport: transport)

        let loadedPoster = await loader.loadIfNeeded(videoURL)
        let poster = try XCTUnwrap(loadedPoster)
        XCTAssertGreaterThan(poster.size.height, poster.size.width)
        let ratio = try XCTUnwrap(loader.posterAspectRatio(for: videoURL))
        XCTAssertEqual(ratio, 0.5, accuracy: 0.05)
    }

    func testDiskCacheHitSkipsSecondNetworkFetch() async throws {
        let mp4 = try await Self.makeTestVideoData(width: 240, height: 160)
        let cacheDir = tempDir("shared-poster-cache")
        let sharedScope = scope()
        let videoURL = "\(Self.origin)/media/cached.mp4"

        let firstTransport = StubTransport { _ in (mp4, "video/mp4") }
        let (firstLoader, _, _) = makeLoader(scope: sharedScope, cacheDir: cacheDir, transport: firstTransport)
        let firstHarness = try await makeHarness([videoBlock("vid", url: videoURL)])
        addTeardownBlock { await firstHarness.close() }
        firstHarness.view.blockControls.posters = firstLoader
        firstHarness.view.blockControls.serverOrigin = Self.origin
        let w1 = host(firstHarness.view)
        defer { w1.isHidden = true }
        let firstView = try XCTUnwrap(realized(firstHarness.session, "vid"))
        await firstView.loadTask?.value
        XCTAssertEqual(firstTransport.urls.count, 1)

        // Second session + fresh loader sharing disk cache must issue 0 network requests.
        let secondTransport = StubTransport { _ in (Data(), nil) }
        let (secondLoader, _, _) = makeLoader(scope: sharedScope, cacheDir: cacheDir, transport: secondTransport)
        let secondHarness = try await makeHarness([videoBlock("vid", url: videoURL)])
        addTeardownBlock { await secondHarness.close() }
        secondHarness.view.blockControls.posters = secondLoader
        secondHarness.view.blockControls.serverOrigin = Self.origin
        let w2 = host(secondHarness.view)
        defer { w2.isHidden = true }
        let secondView = try XCTUnwrap(realized(secondHarness.session, "vid"))
        await secondView.loadTask?.value

        XCTAssertNotNil(secondView.imageView?.image)
        XCTAssertEqual(secondTransport.urls.count, 0)
    }

    func testOfflineExtractsFromAttachmentCacheStoreWithZeroNetwork() async throws {
        let mp4 = try await Self.makeTestVideoData(width: 320, height: 180)
        let attachmentURL =
            "\(Self.origin)/media/\(Self.documentID.uuidString.lowercased())/attachments/\(Self.fileID.uuidString.lowercased()).mp4"
        let display = try XCTUnwrap(parseAttachmentLink("[video](\(attachmentURL))", serverOrigin: Self.origin))

        let attachmentDir = tempDir("attachments")
        let attachments = AttachmentCacheStore(directory: attachmentDir)
        XCTAssertNotNil(attachments.store(mp4, for: display))

        let transport = StubTransport { _ in throw URLError(.notConnectedToInternet) }
        let (loader, _, _) = makeLoader(scope: scope(), attachmentDir: attachmentDir, transport: transport)

        let harness = try await makeHarness([videoBlock("vid", url: attachmentURL)])
        addTeardownBlock { await harness.close() }
        harness.view.blockControls.posters = loader
        harness.view.blockControls.serverOrigin = Self.origin
        harness.view.blockControls.isOffline = true
        let window = host(harness.view)
        defer { window.isHidden = true }

        let view = try XCTUnwrap(realized(harness.session, "vid"))
        await view.loadTask?.value
        XCTAssertNotNil(view.imageView?.image, "offline video extracts from AttachmentCacheStore")
        XCTAssertTrue(transport.urls.isEmpty)
    }

    func testDocumentSaveCoordinatorUploadSeedsAttachmentCache() async throws {
        let mp4 = try await Self.makeTestVideoData(width: 320, height: 160)
        let directory = tempDir("coordinator")
        let suite = "VideoPosterTests.Upload.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        SignedInUserStore(userDefaults: defaults).remember(Self.ownerID)
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let replicaScope = ReplicaScope(
            serverOrigin: Self.origin, ownerUserID: Self.ownerID, org: "docs", documentID: Self.documentID)
        let replicaStore = ReplicaStore(directory: directory)
        let seedState = BlockNoteYjs.encode(
            [videoBlock("vid", url: "", name: "upload.mp4", showPreview: true)],
            clientID: Self.seedClientID
        )
        _ = try replicaStore.create(for: replicaScope, checkpoint: seedState)
        var abilities = DocumentAbilities()
        abilities.update = true
        let doc = Document(
            id: Self.documentID, title: "Doc", excerpt: nil, abilities: abilities, linkReach: .restricted,
            linkRole: .reader, isFavorite: false, depth: 1, numchild: 0, path: "0001", createdAt: Date(),
            updatedAt: Date(), userRole: nil, creator: nil)
        DocumentCacheStore(userDefaults: defaults).saveRecentDocuments([doc], fetchedFor: Self.ownerID)

        let docIDLower = Self.documentID.uuidString.lowercased()
        let uploadedRelativePath = "/media/\(docIDLower)/attachments/\(Self.fileID.uuidString.lowercased()).mp4"
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            switch request.httpMethod {
            case "POST" where url.contains("attachment-upload"):
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data(#"{"file": "/api/v1.0/documents/x/media-check/?key=k.mp4"}"#.utf8), error: nil)
            case "GET" where url.contains("media-check"):
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data(#"{"status":"ready","file":"\#(uploadedRelativePath)"}"#.utf8), error: nil)
            case "GET" where url.hasSuffix("documents/\(docIDLower)/"):
                let json = """
                    {"id": "\(docIDLower)", "title": "Doc", "excerpt": null,
                     "abilities": {"update": true}, "computed_link_reach": "restricted", "computed_link_role": null,
                     "created_at": "2026-01-15T10:30:00Z", "creator": null, "depth": 1, "link_role": "reader",
                     "link_reach": "restricted", "numchild": 0, "path": "0001", "updated_at": "2026-01-15T10:30:00Z",
                     "user_role": "owner", "is_favorite": false}
                    """
                return .init(statusCode: 200, headers: [:], body: Data(json.utf8), error: nil)
            default:
                return .init(statusCode: 404, headers: [:], body: Data(), error: nil)
            }
        }

        let attachmentCacheDir = tempDir("seeded-attachment-cache")
        let attachmentCache = AttachmentCacheStore(directory: attachmentCacheDir)
        let client = DocsAPIClient(
            baseURL: URL(string: Self.origin + "/api/v1.0/")!,
            session: MockURLProtocol.makeSession(),
            cookieProvider: { [] }
        )
        let coordinator = DocumentSaveCoordinator(
            client: client,
            draftStore: PendingDraftStore(userDefaults: defaults),
            replicaStore: replicaStore,
            contentCache: DocumentContentCacheStore(directory: directory.appendingPathComponent("cache")),
            createStore: PendingDocumentCreateStore(userDefaults: defaults),
            attachmentStore: PendingAttachmentStore(
                userDefaults: defaults, directory: directory.appendingPathComponent("pending")),
            attachmentCache: attachmentCache,
            listCache: DocumentCacheStore(userDefaults: defaults),
            childrenCache: DocumentChildrenCacheStore(userDefaults: defaults),
            serverOrigin: Self.origin,
            mediaCheckMaxAttempts: 1,
            mediaCheckRetryInterval: .milliseconds(1),
            backgroundTasks: .noop
        )
        let registry = NativeSessionRegistry()
        coordinator.nativeSessions = registry
        coordinator.nativeEditorEnabled = { true }
        coordinator.nativeCommitAttempts = 5
        coordinator.nativeCommitInterval = .milliseconds(10)
        addTeardownBlock { await registry.closeAll().value }

        let target = NativeMediaTarget(
            org: "docs", blockID: "vid", slot: MediaBlock.Slot(node: "video", url: ""),
            fileName: "upload.mp4", contentType: "video/mp4")
        let queued = coordinator.queueNativeAttachment(scope: replicaScope, target: target, data: mp4)
        XCTAssertNotNil(queued)

        await waitUntil { coordinator.nativeAttachment(scope: replicaScope, blockID: "vid") == nil }

        let expectedURL = "\(Self.origin)\(uploadedRelativePath)"
        let display = try XCTUnwrap(parseAttachmentLink("[video](\(expectedURL))", serverOrigin: Self.origin))
        XCTAssertNotNil(attachmentCache.cachedFileURL(for: display), "video upload seeds AttachmentCacheStore")

        // Render with zero-download transport: poster extracts from seeded cache.
        let zeroDownload = StubTransport { _ in throw URLError(.badURL) }
        let (loader, _, _) = makeLoader(scope: scope(), attachmentDir: attachmentCacheDir, transport: zeroDownload)
        let loadedPoster = await loader.loadIfNeeded(URL(string: expectedURL)!, allowsNetwork: false)
        let poster = try XCTUnwrap(loadedPoster)
        XCTAssertEqual(poster.size.width / poster.size.height, 2.0, accuracy: 0.05)
        XCTAssertTrue(zeroDownload.urls.isEmpty)
    }

    func testExternalVideoWaitsForTapAndHidesBadgeUntilApproved() async throws {
        let mp4 = try await Self.makeTestVideoData(width: 240, height: 180)
        let externalURL = "https://elsewhere.example/ext.mp4"
        let harness = try await makeHarness([
            videoBlock("ext", url: externalURL, name: "ext.mp4", caption: "External Clip")
        ])
        addTeardownBlock { await harness.close() }

        let transport = StubTransport { _ in (mp4, "video/mp4") }
        let (loader, _, _) = makeLoader(scope: scope(), transport: transport)
        harness.view.blockControls.posters = loader
        harness.view.blockControls.serverOrigin = Self.origin
        let window = host(harness.view)
        defer { window.isHidden = true }

        let view = try XCTUnwrap(realized(harness.session, "ext"))
        await view.loadTask?.value
        XCTAssertTrue(transport.urls.isEmpty, "external video does not fetch before tap")
        XCTAssertNotNil(view.loadButton)
        XCTAssertTrue(view.videoPlayBadge?.isHidden == true, "play badge hidden behind consent overlay")
        XCTAssertTrue(view.videoCaptionPill?.isHidden == true, "caption pill hidden behind consent overlay")
        XCTAssertEqual(view.loadButton?.configuration?.title, "External video · tap to load")
        XCTAssertEqual(view.accessibilityValue, "External video from elsewhere.example. Tap to load.")

        view.approveAndLoad()
        await view.loadTask?.value
        harness.view.layoutIfNeeded()
        XCTAssertEqual(transport.urls, [URL(string: externalURL)!])
        let updated = try XCTUnwrap(realized(harness.session, "ext"))
        XCTAssertNotNil(updated.imageView?.image)
        XCTAssertNil(updated.loadButton)
        XCTAssertFalse(try XCTUnwrap(updated.videoPlayBadge).isHidden)
        XCTAssertFalse(try XCTUnwrap(updated.videoCaptionPill).isHidden)
        XCTAssertTrue(updated.accessibilityTraits.contains(.button))
    }

    func testSessionOriginMismatchIsolatesCacheAndRequests() async throws {
        let mp4 = try await Self.makeTestVideoData(width: 240, height: 180)
        let urlString = "\(Self.origin)/media/clip.mp4"
        let harness = try await makeHarness([videoBlock("vid", url: urlString)])
        addTeardownBlock { await harness.close() }

        let transport = StubTransport { _ in (mp4, "video/mp4") }
        let (loader, _, _) = makeLoader(scope: scope(origin: Self.origin), transport: transport)
        _ = await loader.loadIfNeeded(URL(string: urlString)!)
        XCTAssertEqual(transport.urls.count, 1)

        harness.view.blockControls.posters = loader
        harness.view.blockControls.serverOrigin = "https://other.example"
        let window = host(harness.view)
        defer { window.isHidden = true }

        let view = try XCTUnwrap(realized(harness.session, "vid"))
        await view.loadTask?.value
        XCTAssertNil(view.imageView?.image)
        XCTAssertEqual(view.imageStatus?.text, "Video available when online")
        XCTAssertTrue(view.videoPlayBadge?.isHidden == true)
        XCTAssertEqual(transport.urls.count, 1)
    }

    func testOversizeVideoSkipsWithoutErrorAndRecoversFromAttachmentCache() async throws {
        let mp4 = try await Self.makeTestVideoData(width: 320, height: 160)
        let attachmentURL =
            "\(Self.origin)/media/\(Self.documentID.uuidString.lowercased())/attachments/\(Self.fileID.uuidString.lowercased()).mp4"
        let attachmentDir = tempDir("attachments")

        let transport = StubTransport { _ in throw URLError(.dataLengthExceedsMaximum) }
        let (loader, _, attachments) = makeLoader(
            scope: scope(), attachmentDir: attachmentDir, transport: transport)

        let harness = try await makeHarness([videoBlock("vid", url: attachmentURL, name: "big.mp4")])
        addTeardownBlock { await harness.close() }
        harness.view.blockControls.posters = loader
        harness.view.blockControls.serverOrigin = Self.origin
        let window = host(harness.view)
        defer { window.isHidden = true }

        let view = try XCTUnwrap(realized(harness.session, "vid"))
        await view.loadTask?.value
        XCTAssertNil(view.imageView?.image)
        XCTAssertTrue(view.imageStatus?.isHidden == true, "oversize video keeps clean card with no error text")
        XCTAssertFalse(try XCTUnwrap(view.videoPlayBadge).isHidden)
        XCTAssertEqual(transport.urls.count, 1)

        // Subsequent load attempt does not re-fetch from network.
        let second = await loader.loadIfNeeded(URL(string: attachmentURL)!)
        XCTAssertNil(second)
        XCTAssertEqual(transport.urls.count, 1)

        // Once QuickLook / AttachmentCacheStore populates the local file, poster resolves without network.
        let display = try XCTUnwrap(parseAttachmentLink("[video](\(attachmentURL))", serverOrigin: Self.origin))
        XCTAssertNotNil(attachments.store(mp4, for: display))
        let recovered = await loader.loadIfNeeded(URL(string: attachmentURL)!)
        XCTAssertNotNil(recovered)
        XCTAssertEqual(transport.urls.count, 1)
    }

    func testCorruptVideoKeepsCleanCardWithoutRetryLoop() async throws {
        let videoURL = "\(Self.origin)/media/corrupt.mp4"
        let transport = StubTransport { _ in (Data([0x00, 0x01, 0x02, 0x03]), "video/mp4") }
        let (loader, _, _) = makeLoader(scope: scope(), transport: transport)

        let harness = try await makeHarness([videoBlock("vid", url: videoURL, name: "corrupt.mp4")])
        addTeardownBlock { await harness.close() }
        harness.view.blockControls.posters = loader
        harness.view.blockControls.serverOrigin = Self.origin
        let window = host(harness.view)
        defer { window.isHidden = true }

        let view = try XCTUnwrap(realized(harness.session, "vid"))
        await view.loadTask?.value
        XCTAssertNil(view.imageView?.image)
        XCTAssertTrue(view.imageStatus?.isHidden == true)
        XCTAssertFalse(try XCTUnwrap(view.videoPlayBadge).isHidden)
        XCTAssertEqual(transport.urls.count, 1)

        _ = await loader.loadIfNeeded(URL(string: videoURL)!)
        XCTAssertEqual(transport.urls.count, 1, "failed extraction is not retried automatically")
    }

    func testLeavingWindowCancelsInFlightTask() async throws {
        final class GateBox: @unchecked Sendable {
            var started = false
            var continuation: CheckedContinuation<(data: Data, mimeType: String?), Error>?
            func resumeCanceled() {
                continuation?.resume(throwing: CancellationError())
                continuation = nil
            }
        }
        let gate = GateBox()
        let videoURL = "\(Self.origin)/media/slow.mp4"
        let transport = StubTransport { _ in
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    Task { @MainActor in
                        gate.started = true
                        gate.continuation = continuation
                    }
                }
            } onCancel: {
                Task { @MainActor in
                    gate.resumeCanceled()
                }
            }
        }
        let (loader, _, _) = makeLoader(scope: scope(), transport: transport)
        let harness = try await makeHarness([videoBlock("vid", url: videoURL)])
        addTeardownBlock { await harness.close() }
        harness.view.blockControls.posters = loader
        harness.view.blockControls.serverOrigin = Self.origin
        let window = host(harness.view)
        defer { window.isHidden = true }

        await waitUntil { gate.started }
        let view = try XCTUnwrap(realized(harness.session, "vid"))
        XCTAssertNotNil(view.loadTask)

        harness.view.removeFromSuperview()
        XCTAssertNil(view.loadTask, "moving out of window cancels in-flight task")
        gate.resumeCanceled()
    }

    func testCookiesSentOnlyForSameOriginAndNeverOffOrigin() async throws {
        let mp4 = try await Self.makeTestVideoData(width: 160, height: 120)
        let sessionCookie = try XCTUnwrap(
            HTTPCookie(properties: [
                .name: "session",
                .value: "secret",
                .domain: "example.test",
                .path: "/",
            ]))
        var sentCookies: [(URL, [HTTPCookie])] = []
        var cookieQueries: [URL] = []
        let activeScope = scope()

        let loader = VideoPosterLoader(
            cache: ImageCacheStore(directory: tempDir("posters")),
            attachmentCache: AttachmentCacheStore(directory: tempDir("attachments")),
            fetch: { url, cookies in
                sentCookies.append((url, cookies))
                return (mp4, "video/mp4")
            },
            cookieProvider: { url in
                cookieQueries.append(url)
                return [sessionCookie]
            },
            scopeProvider: { activeScope },
            scratchDirectory: tempDir("scratch")
        )

        let sameOriginURL = URL(string: "\(Self.origin)/media/same.mp4")!
        let sameImage = await loader.loadIfNeeded(sameOriginURL)
        XCTAssertNotNil(sameImage)

        let offOriginURL = URL(string: "https://cdn.other.test/video.mp4")!
        loader.approve(offOriginURL)
        let offImage = await loader.loadIfNeeded(offOriginURL)
        XCTAssertNotNil(offImage)

        XCTAssertEqual(sentCookies.count, 2)
        XCTAssertEqual(sentCookies[0].0, sameOriginURL)
        XCTAssertEqual(sentCookies[0].1.map(\.name), ["session"])
        XCTAssertEqual(sentCookies[1].0, offOriginURL)
        XCTAssertTrue(sentCookies[1].1.isEmpty, "off-origin approved video must never receive cookies")
        XCTAssertEqual(cookieQueries, [sameOriginURL], "cookieProvider must not be queried off-origin")
    }

    func testAccountScopeSwitchDuringFetchDropsBytesAndCachesNothing() async throws {
        let mp4 = try await Self.makeTestVideoData(width: 160, height: 120)
        let attachmentURLString =
            "\(Self.origin)/media/\(Self.documentID.uuidString.lowercased())/attachments/\(Self.fileID.uuidString.lowercased()).mp4"
        let attachmentURL = URL(string: attachmentURLString)!

        let scopeA = scope(origin: Self.origin)
        let scopeB = scope(origin: Self.origin)
        var activeScope = scopeA

        let cache = ImageCacheStore(directory: tempDir("posters"))
        let attachments = AttachmentCacheStore(directory: tempDir("attachments"))
        let loader = VideoPosterLoader(
            cache: cache,
            attachmentCache: attachments,
            fetch: { _, _ in
                activeScope = scopeB
                return (mp4, "video/mp4")
            },
            cookieProvider: { _ in [] },
            scopeProvider: { activeScope },
            scratchDirectory: tempDir("scratch")
        )

        let result = await loader.loadIfNeeded(attachmentURL)
        XCTAssertNil(result, "stale fetch after account switch must return nil")

        let display = try XCTUnwrap(parseAttachmentLink("[video](\(attachmentURLString))", serverOrigin: Self.origin))
        XCTAssertNil(attachments.cachedFileURL(for: display), "stale bytes must not populate AttachmentCacheStore")
        let posterKey = VideoPosterLoader.posterKey(for: attachmentURL)
        XCTAssertNil(cache.cachedFileURL(forKey: posterKey, scope: scopeA))
        XCTAssertNil(cache.cachedFileURL(forKey: posterKey, scope: scopeB))
        XCTAssertNil(loader.poster(for: attachmentURL))
    }

    func testAccountScopeSwitchDuringExtractionDropsPosterAndCachesNothing() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let testImage = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let jpegData = try XCTUnwrap(testImage.jpegData(compressionQuality: 0.9))

        let videoURL = URL(string: "\(Self.origin)/media/extract-switch.mp4")!
        let scopeA = scope(origin: Self.origin)
        let scopeB = scope(origin: Self.origin)
        var activeScope = scopeA

        let cache = ImageCacheStore(directory: tempDir("posters"))
        let attachments = AttachmentCacheStore(directory: tempDir("attachments"))
        let loader = VideoPosterLoader(
            cache: cache,
            attachmentCache: attachments,
            fetch: { _, _ in (Data([0x00, 0x01, 0x02]), "video/mp4") },
            cookieProvider: { _ in [] },
            scopeProvider: { activeScope },
            extractPoster: { _, _ in
                await MainActor.run { activeScope = scopeB }
                return jpegData
            },
            scratchDirectory: tempDir("scratch")
        )

        let result = await loader.loadIfNeeded(videoURL)
        XCTAssertNil(result, "stale extraction after account switch must return nil")

        let posterKey = VideoPosterLoader.posterKey(for: videoURL)
        XCTAssertNil(cache.cachedFileURL(forKey: posterKey, scope: scopeA), "must not cache poster under stale scopeA")
        XCTAssertNil(
            cache.cachedFileURL(forKey: posterKey, scope: scopeB), "must not cache poster under switched scopeB")
        XCTAssertNil(loader.poster(for: videoURL))
    }

    // MARK: - S2 & S3 Security Tests

    func testS2MemoryCacheIsScopedByOriginAndSessionAndSwitchClearsAttachmentCache() async throws {
        let mp4 = try await Self.makeTestVideoData(width: 160, height: 120)
        let attachmentURLString =
            "\(Self.origin)/media/\(Self.documentID.uuidString.lowercased())/attachments/\(Self.fileID.uuidString.lowercased()).mp4"
        let attachmentURL = URL(string: attachmentURLString)!
        let display = try XCTUnwrap(parseAttachmentLink("[video](\(attachmentURLString))", serverOrigin: Self.origin))

        let scopeA = ImageCacheScope(serverOrigin: Self.origin, sessionID: "session-a")
        let scopeB = ImageCacheScope(serverOrigin: Self.origin, sessionID: "session-b")
        let scopeOtherOrigin = ImageCacheScope(serverOrigin: "https://other.test", sessionID: "session-a")
        var activeScope = scopeA

        var fetchCount = 0
        let cache = ImageCacheStore(directory: tempDir("posters"))
        let attachments = AttachmentCacheStore(directory: tempDir("attachments"))
        let loader = VideoPosterLoader(
            cache: cache,
            attachmentCache: attachments,
            fetch: { _, _ in
                fetchCount += 1
                return (mp4, "video/mp4")
            },
            cookieProvider: { _ in [] },
            scopeProvider: { activeScope },
            scratchDirectory: tempDir("scratch")
        )

        let posterA = await loader.loadIfNeeded(attachmentURL)
        XCTAssertNotNil(posterA)
        XCTAssertNotNil(loader.poster(for: attachmentURL))
        XCTAssertNotNil(attachments.cachedFileURL(for: display))
        XCTAssertEqual(fetchCount, 1)

        // Switching to a different session on the same origin must NOT hit Account A's memory or attachment cache.
        activeScope = scopeB
        XCTAssertNil(loader.poster(for: attachmentURL), "memory cache must be isolated by sessionID")
        XCTAssertNil(attachments.cachedFileURL(for: display), "attachment cache must not persist across scope switch")

        // Switching back to a different origin with the same sessionID also must not hit memory cache.
        activeScope = scopeA
        _ = await loader.loadIfNeeded(attachmentURL)
        XCTAssertNotNil(loader.poster(for: attachmentURL))
        activeScope = scopeOtherOrigin
        XCTAssertNil(loader.poster(for: attachmentURL), "memory cache must be isolated by serverOrigin")
    }

    func testS2AccountScopeSwitchDuringExtractionDoesNotPopulateAttachmentCache() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let testImage = renderer.image { ctx in
            UIColor.systemGreen.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let jpegData = try XCTUnwrap(testImage.jpegData(compressionQuality: 0.9))

        let attachmentURLString =
            "\(Self.origin)/media/\(Self.documentID.uuidString.lowercased())/attachments/\(Self.fileID.uuidString.lowercased()).mp4"
        let attachmentURL = URL(string: attachmentURLString)!
        let display = try XCTUnwrap(parseAttachmentLink("[video](\(attachmentURLString))", serverOrigin: Self.origin))

        let scopeA = scope(origin: Self.origin)
        let scopeB = scope(origin: Self.origin)
        var activeScope = scopeA

        let cache = ImageCacheStore(directory: tempDir("posters"))
        let attachments = AttachmentCacheStore(directory: tempDir("attachments"))
        let loader = VideoPosterLoader(
            cache: cache,
            attachmentCache: attachments,
            fetch: { _, _ in (Data([0x00, 0x01, 0x02]), "video/mp4") },
            cookieProvider: { _ in [] },
            scopeProvider: { activeScope },
            extractPoster: { _, _ in
                await MainActor.run { activeScope = scopeB }
                return jpegData
            },
            scratchDirectory: tempDir("scratch")
        )

        let result = await loader.loadIfNeeded(attachmentURL)
        XCTAssertNil(result)
        XCTAssertNil(
            attachments.cachedFileURL(for: display),
            "attachment cache must not be populated before post-extraction scope recheck")
    }

    func testS3M3U8AndDisallowedMIMETypesNeverTriggerAVAssetFetch() async throws {
        // 1. AVURLAsset options always forbid all external references and filter MIME types.
        let hlsOptions = VideoPosterLoader.avURLAssetOptions(mimeType: "application/vnd.apple.mpegurl")
        XCTAssertEqual(
            hlsOptions[AVURLAssetReferenceRestrictionsKey] as? UInt,
            AVAssetReferenceRestrictions.forbidAll.rawValue)
        XCTAssertNil(hlsOptions[AVURLAssetOverrideMIMETypeKey])

        let mp4Options = VideoPosterLoader.avURLAssetOptions(mimeType: "video/mp4; codecs=\"avc1.42E01E\"")
        XCTAssertEqual(
            mp4Options[AVURLAssetReferenceRestrictionsKey] as? UInt,
            AVAssetReferenceRestrictions.forbidAll.rawValue)
        XCTAssertEqual(mp4Options[AVURLAssetOverrideMIMETypeKey] as? String, "video/mp4")

        // 2. Cached .m3u8 attachment file must be rejected before AVURLAsset runs.
        let m3u8URLString =
            "\(Self.origin)/media/\(Self.documentID.uuidString.lowercased())/attachments/\(Self.fileID.uuidString.lowercased()).m3u8"
        let m3u8URL = URL(string: m3u8URLString)!
        let m3u8Display = try XCTUnwrap(parseAttachmentLink("[video](\(m3u8URLString))", serverOrigin: Self.origin))
        let playlist = Data(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:10
            #EXTINF:10.0,
            https://attacker.example/segment.ts
            #EXT-X-ENDLIST
            """.utf8)

        let attachmentDir = tempDir("attachments-m3u8")
        let attachments = AttachmentCacheStore(directory: attachmentDir)
        XCTAssertNotNil(attachments.store(playlist, for: m3u8Display))

        let transport = StubTransport { _ in (playlist, "application/vnd.apple.mpegurl") }
        let (loader, _, _) = makeLoader(scope: scope(), attachmentDir: attachmentDir, transport: transport)
        let m3u8Result = await loader.loadIfNeeded(m3u8URL)
        XCTAssertNil(m3u8Result, ".m3u8 in AttachmentCacheStore must never produce a poster")

        // 3. .mp4 URL served with application/vnd.apple.mpegurl MIME type must not override MIME to HLS.
        let disguisedURL = URL(string: "\(Self.origin)/media/disguised.mp4")!
        let disguisedTransport = StubTransport { _ in (playlist, "application/vnd.apple.mpegurl") }
        let (disguisedLoader, _, _) = makeLoader(scope: scope(), transport: disguisedTransport)
        let disguisedResult = await disguisedLoader.loadIfNeeded(disguisedURL)
        XCTAssertNil(disguisedResult)
    }

    func testR3CachedVideoSupportsAdditionalAVFoundationExtensions() async throws {
        for ext in ["avi", "mkv", "ts", "mpeg", "ogv", "3gp", "mp4", "m4v", "mov", "webm"] {
            XCTAssertTrue(
                VideoPosterLoader.isSupportedVideoFileExtension(ext),
                "extension .\(ext) should be accepted for poster extraction")
        }
        for blocked in ["m3u8", "m3u", "pls", "html", "txt", "mp3", ""] {
            XCTAssertFalse(
                VideoPosterLoader.isSupportedVideoFileExtension(blocked),
                "extension .\(blocked) must remain rejected")
        }

        // End-to-end cached-file path with a real .3gp video in AttachmentCacheStore and real AVAssetImageGenerator.
        let video3GP = try await Self.makeTestVideoData(width: 160, height: 120, fileType: .mobile3GPP)
        let url3GPString =
            "\(Self.origin)/media/\(Self.documentID.uuidString.lowercased())/attachments/\(Self.fileID.uuidString.lowercased()).3gp"
        let url3GP = URL(string: url3GPString)!
        let display3GP = try XCTUnwrap(parseAttachmentLink("[video](\(url3GPString))", serverOrigin: Self.origin))

        let attachmentDir = tempDir("attachments-3gp")
        let attachments = AttachmentCacheStore(directory: attachmentDir)
        XCTAssertNotNil(attachments.store(video3GP, for: display3GP))

        let transport = StubTransport { _ in
            XCTFail("cached .3gp video must not hit network")
            return (Data(), nil)
        }
        let (loader, _, _) = makeLoader(scope: scope(), attachmentDir: attachmentDir, transport: transport)
        let poster = await loader.loadIfNeeded(url3GP, allowsNetwork: false)
        XCTAssertNotNil(poster, "cached .3gp video must produce a poster frame")
        XCTAssertTrue(transport.urls.isEmpty)
    }
}
