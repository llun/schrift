import AVKit
import UIKit
import XCTest

@testable import Schrift

/// A media card's tap plays video and audio and previews image, file and PDF;
/// settings move to the card's Options button (editing only). Another site's
/// file is fetched only on that tap, over https, and never offline; an upload
/// on this server plays from the file the attachment loader downloads with
/// the session's cookies.
@MainActor
final class NativeMediaPlaybackTests: NativeEditingTestCase {
    private nonisolated static let origin = "https://example.test"
    private static let documentUUID = "11111111-1111-4111-8111-111111111111"
    private static let fileUUID = "22222222-2222-4222-8222-222222222222"
    private var windows: [UIWindow] = []
    private var directories: [URL] = []

    override func tearDown() async throws {
        for window in windows { window.isHidden = true }
        windows = []
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    private static func upload(_ ext: String) -> String {
        "\(origin)/media/\(documentUUID)/attachments/\(fileUUID).\(ext)"
    }

    private func route(_ node: String, _ url: String, offline: Bool = false, local: URL? = nil) -> NativeMediaTap {
        NativeMediaTap.route(node: node, url: url, serverOrigin: Self.origin, isOffline: offline, localFile: local)
    }

    private func display(_ url: String) throws -> AttachmentDisplay {
        try XCTUnwrap(parseAttachmentLink("[](\(url))", serverOrigin: Self.origin))
    }

    // MARK: - Routing

    func testVideoAndAudioPlayFromTheirSource() throws {
        let remote = try XCTUnwrap(URL(string: "https://interactive-examples.mdn.mozilla.net/media/flower.mp4"))
        XCTAssertEqual(route("video", remote.absoluteString), .play(.remote(remote)), "another site: streamed on tap")
        XCTAssertEqual(
            route("audio", Self.upload("mp3")), .play(.attachment(try display(Self.upload("mp3")))),
            "this server's upload: through the attachment loader")
        let local = URL(fileURLWithPath: "/tmp/clip.mov")
        XCTAssertEqual(
            route("video", Self.upload("mp4"), local: local), .play(.local(local)), "a queued upload plays its bytes")
    }

    func testImageFileAndPDFPreview() throws {
        let image = try XCTUnwrap(URL(string: "https://images.example/harbour.png"))
        XCTAssertEqual(route("image", image.absoluteString), .preview(.image(image)), "images: the image loader")
        XCTAssertEqual(route("pdf", Self.upload("pdf")), .preview(.attachment(try display(Self.upload("pdf")))))
        let file = try XCTUnwrap(URL(string: "https://files.example/notes.txt"))
        XCTAssertEqual(route("file", file.absoluteString), .preview(.remote(file)))
    }

    func testABlockWithNothingToShowOpensItsInspector() {
        for node in ["image", "video", "audio", "file", "pdf"] {
            XCTAssertEqual(route(node, ""), .inspector, "\(node) without a url: its inspector uploads or links")
        }
        XCTAssertEqual(route(MediaBlock.uploadLoader, Self.upload("png")), .inspector, "a peer's upload")
        XCTAssertEqual(route("file", Self.upload("html")), .inspector, "QuickLook never renders web content")
        XCTAssertEqual(
            route("file", "", local: URL(fileURLWithPath: "/tmp/page.html")), .inspector,
            "nor a queued upload of it")
    }

    func testAnotherSitesCleartextOrNonMediaURLIsNeverFetched() {
        for url in [
            "http://media.example/clip.mp4", "javascript:alert(1)", "file:///etc/hosts", "data:video/mp4;base64,AAAA",
            "https://user@media.example/clip.mp4",
        ] {
            XCTAssertEqual(route("video", url), .inspector, url)
            XCTAssertEqual(route("pdf", url), .inspector, url)
        }
    }

    /// A playlist's entries are fetched by the player itself, past every guard here, so none plays,
    /// wherever it comes from; nor does markup.
    func testAPlaylistOrMarkupNeverReachesThePlayer() throws {
        for url in ["https://media.example/live.m3u8", "https://media.example/mix.m3u", Self.upload("m3u8")] {
            XCTAssertEqual(route("video", url), .inspector, url)
            XCTAssertEqual(route("audio", url), .inspector, url)
        }
        for name in ["live.m3u8", "mix.m3u", "page.xhtm"] {
            XCTAssertEqual(route("video", "", local: URL(fileURLWithPath: "/tmp/\(name)")), .inspector, name)
        }
        XCTAssertNil(
            NativeMediaPresenter.playableExtension(mimeType: "application/vnd.apple.mpegurl", pathExtension: "mp4"))
        XCTAssertNil(NativeMediaPresenter.playableExtension(mimeType: "application/x-mpegURL", pathExtension: "mp4"))
        XCTAssertNil(NativeMediaPresenter.playableExtension(mimeType: "text/html", pathExtension: "mp4"))
        XCTAssertNil(
            NativeMediaPresenter.playableExtension(mimeType: "application/octet-stream", pathExtension: "m3u8"))
        XCTAssertEqual(NativeMediaPresenter.playableExtension(mimeType: "video/mp4", pathExtension: ""), "mp4")
        XCTAssertEqual(
            NativeMediaPresenter.playableExtension(mimeType: "application/octet-stream", pathExtension: "MOV"), "mov")
    }

    func testOfflineAnotherSitesFileIsANoticeButAnUploadAsksItsCache() throws {
        XCTAssertEqual(route("video", "https://media.example/clip.mp4", offline: true), .offline)
        XCTAssertEqual(route("file", "https://files.example/notes.txt", offline: true), .offline)
        XCTAssertEqual(
            route("video", Self.upload("mp4"), offline: true), .play(.attachment(try display(Self.upload("mp4")))),
            "a cached upload still plays offline")
    }

    // MARK: - The card

    private func mediaBlock(_ node: String, _ id: String, url: String) -> BlockNoteBlock {
        let fields = (MediaBlock.schemas[node] ?? []).map { field in
            (key: field.key, value: field.key == "url" ? YAnyValue.string(url) : field.value)
        }
        return BlockNoteBlock(node: node, props: fields, runs: [], id: id)
    }

    private func show(_ view: NativeTextView) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(view)
        view.frame = window.bounds
        window.isHidden = false
        windows.append(window)
        view.layoutIfNeeded()
        return window
    }

    private func card(_ view: NativeTextView, _ id: String) throws -> NativeAttachmentView {
        try XCTUnwrap(view.blockControls.visibleAttachmentViews.first { $0.content.blockID == id }, id)
    }

    func testACardTapPlaysOrPreviewsAndAnEmptyBlockOpensItsInspector() async throws {
        let remote = "https://media.example/clip.mp4"
        let harness = try await makeHarness([
            paragraph("lead", "Media"), mediaBlock("video", "clip", url: remote),
            mediaBlock("pdf", "doc", url: Self.upload("pdf")), mediaBlock("audio", "empty", url: ""),
        ])
        addTeardownBlock { await harness.close() }
        harness.view.blockControls.serverOrigin = Self.origin
        _ = show(harness.view)
        var shown: [NativeMediaTap] = []
        var inspected: [String] = []
        harness.view.blockControls.onShowMedia = { tap, _ in shown.append(tap) }
        harness.view.blockControls.onOpenMedia = { inspected.append($0) }

        XCTAssertTrue(try card(harness.view, "clip").accessibilityActivate())
        XCTAssertTrue(try card(harness.view, "doc").accessibilityActivate())
        XCTAssertTrue(try card(harness.view, "empty").accessibilityActivate())

        XCTAssertEqual(
            shown,
            [
                .play(.remote(try XCTUnwrap(URL(string: remote)))),
                .preview(.attachment(try display(Self.upload("pdf")))),
            ])
        XCTAssertEqual(inspected, ["empty"], "only the block with nothing to show opens its inspector")
    }

    private func texts(in view: UIView) -> [String] {
        view.subviews.flatMap { subview in ((subview as? UILabel)?.text).map { [$0] } ?? texts(in: subview) }
    }

    /// An audio, file or PDF card on another site says where a tap goes; this server's upload does not.
    func testAnotherSitesAudioFileOrPDFCardNamesItsHost() async throws {
        let harness = try await makeHarness([
            paragraph("lead", "Media"), mediaBlock("audio", "song", url: "https://media.example/song.mp3"),
            mediaBlock("file", "notes", url: "https://files.example/notes.txt"),
            mediaBlock("pdf", "paper", url: "https://papers.example:8443/paper.pdf"),
            mediaBlock("pdf", "upload", url: Self.upload("pdf")),
        ])
        addTeardownBlock { await harness.close() }
        harness.view.blockControls.serverOrigin = Self.origin
        _ = show(harness.view)

        for (id, host) in [("song", "media.example"), ("notes", "files.example"), ("paper", "papers.example")] {
            let card = try card(harness.view, id)
            XCTAssertTrue(texts(in: card).contains(host), "\(id): \(texts(in: card))")
            XCTAssertEqual(card.accessibilityValue, host, "VoiceOver hears it too")
        }
        let upload = try card(harness.view, "upload")
        XCTAssertFalse(texts(in: upload).contains("example.test"), "\(texts(in: upload))")
        XCTAssertTrue(texts(in: upload).contains(NativeEditorLabels().kind("pdf")))
    }

    func testTheOptionsButtonOpensTheInspectorWhileEditing() async throws {
        let harness = try await makeHarness([
            paragraph("lead", "Media"), mediaBlock("video", "clip", url: Self.upload("mp4")),
        ])
        addTeardownBlock { await harness.close() }
        _ = show(harness.view)
        var inspected: [String] = []
        harness.view.blockControls.onOpenMedia = { inspected.append($0) }
        let button = try XCTUnwrap(harness.view.blockControls.mediaOptionButtons["clip"], "editing shows Options")
        XCTAssertEqual(button.accessibilityLabel, NativeEditorLabels().mediaOptions)
        XCTAssertGreaterThanOrEqual(button.bounds.width, DocsSpacing.rowMinHeight, "a 44 pt target")
        XCTAssertGreaterThanOrEqual(button.bounds.height, DocsSpacing.rowMinHeight)
        let cardFrame = try card(harness.view, "clip").convert(try card(harness.view, "clip").bounds, to: harness.view)
        XCTAssertEqual(button.frame.maxX, cardFrame.maxX, accuracy: 0.5, "on the card's trailing corner")
        XCTAssertEqual(button.frame.minY, cardFrame.minY, accuracy: 0.5)
        button.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(inspected, ["clip"])
    }

    func testTheReaderHasNoOptionsButtonButStillPlays() async throws {
        let blocks = [paragraph("lead", "Media"), mediaBlock("video", "clip", url: Self.upload("mp4"))]
        let reader = try await NativeEditorSession.inspect(
            state: BlockNoteYjs.encode(blocks, clientID: Self.seedClientID))
        addTeardownBlock { await reader.close().value }
        reader.textView.blockControls.serverOrigin = Self.origin
        _ = show(reader.textView)
        var shown: [NativeMediaTap] = []
        reader.textView.blockControls.onShowMedia = { tap, _ in shown.append(tap) }
        XCTAssertTrue(reader.textView.blockControls.mediaOptionButtons.isEmpty, "reading has no settings")
        XCTAssertTrue(try card(reader.textView, "clip").accessibilityActivate())
        XCTAssertEqual(shown, [.play(.attachment(try display(Self.upload("mp4"))))])
    }

    func testTheBlockMenuOffersOptionsOnlyOnAMediaBlock() async throws {
        let harness = try await makeHarness([
            paragraph("lead", "Media"), mediaBlock("audio", "song", url: Self.upload("mp3")),
        ])
        addTeardownBlock { await harness.close() }
        setSelection(harness, NSRange(location: try location(harness.session, "lead", 1), length: 0))
        XCTAssertNil(harness.input.mediaOptionsTarget())
        setSelection(harness, NSRange(location: try location(harness.session, "song", 0), length: 0))
        XCTAssertEqual(harness.input.mediaOptionsTarget(), "song")
    }

    // MARK: - Showing

    /// An attachment loader over the app's client, whose session holds `cookie` (if any).
    private func attachmentLoader(cookie: HTTPCookie?) -> (AttachmentLoader, URLSession) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeMediaPlaybackTests.\(UUID().uuidString)", isDirectory: true)
        directories.append(directory)
        let session = MockURLProtocol.makeSession()
        if let cookie { session.configuration.httpCookieStorage?.setCookie(cookie) }
        let client = DocsAPIClient(
            baseURL: URL(string: "\(Self.origin)/api/v1.0/")!, session: session, cookieProvider: { [] })
        return (
            AttachmentLoader(
                client: client, serverOrigin: Self.origin, cache: AttachmentCacheStore(directory: directory)),
            session
        )
    }

    /// The same-origin path: the bytes come from the server on the client's session (whose
    /// cookies URLSession attaches; a mock protocol never sees that header, so the test checks the
    /// request lets it and the session holds a cookie for it), on a path with no query, and what
    /// plays is the cached local file, never a server URL.
    func testAnUploadOnThisServerPlaysFromTheFileItsSessionDownloaded() async throws {
        let harness = try await makeHarness([paragraph("lead", "Media")])
        addTeardownBlock { await harness.close() }
        let cookie = try XCTUnwrap(
            HTTPCookie(properties: [
                .domain: "example.test", .path: "/", .name: "sessionid", .value: "fake", .secure: true,
            ]))
        let (loader, session) = attachmentLoader(cookie: cookie)
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 200, headers: [:], body: Data([0, 0, 0, 0x18]), error: nil)
        }
        let controls: NativeBlockControls = harness.view.blockControls
        controls.serverOrigin = Self.origin
        controls.attachments = loader

        let resolved = await NativeMediaPresenter.resolve(
            .attachment(try display(Self.upload("mp4"))), controls: controls)

        guard case .file(let file) = resolved else { return XCTFail("expected a file, got \(resolved)") }
        XCTAssertTrue(file.isFileURL, "the player gets the cached file, never the server URL")
        XCTAssertEqual(file.pathExtension, "mp4")
        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/media/\(Self.documentUUID)/attachments/\(Self.fileUUID).mp4")
        XCTAssertNil(request.url?.query, "nothing authenticating in the URL")
        XCTAssertNil(request.url?.user)
        XCTAssertTrue(request.httpShouldHandleCookies, "URLSession attaches the session's cookies")
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(
            session.configuration.httpCookieStorage?.cookies(for: url)?.map(\.name), ["sessionid"],
            "the session's cookie applies to this request")
        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "/media/"), 1)
    }

    func testOfflineAnUncachedUploadIsANoticeAndRequestsNothing() async throws {
        let harness = try await makeHarness([paragraph("lead", "Media")])
        addTeardownBlock { await harness.close() }
        let (loader, _) = attachmentLoader(cookie: nil)
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 200, headers: [:], body: Data([1]), error: nil)
        }
        let controls: NativeBlockControls = harness.view.blockControls
        controls.serverOrigin = Self.origin
        controls.attachments = loader
        controls.isOffline = true

        let resolved = await NativeMediaPresenter.resolve(
            .attachment(try display(Self.upload("mp4"))), controls: controls)

        XCTAssertEqual(resolved, NativeMediaPresenter.Resolution.notice(NativeEditorLabels().mediaOffline))
        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "/media/"), 0)
    }

    /// The client a test's remote fetch goes through: the production configuration, mock transport.
    private func remoteMedia() -> RemoteMediaClient {
        let configuration = RemoteMediaClient.configuration()
        configuration.protocolClasses = [MockURLProtocol.self]
        return RemoteMediaClient(session: URLSession(configuration: configuration))
    }

    /// `AVURLAsset` sends matching cookies from the shared storage whatever its options say, so a URL on
    /// this server's host that isn't an upload (another path, an explicit :443) must never reach the
    /// player: it downloads with no cookies and the player gets the local file.
    func testThisHostsNonUploadURLDownloadsWithoutCookiesAndPlaysTheFile() async throws {
        let harness = try await makeHarness([paragraph("lead", "Media")])
        addTeardownBlock { await harness.close() }
        let controls: NativeBlockControls = harness.view.blockControls
        controls.serverOrigin = Self.origin
        controls.remoteMedia = remoteMedia()
        let configuration = RemoteMediaClient.configuration()
        XCTAssertNil(configuration.httpCookieStorage, "no cookie storage, so no session cookie")
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(
                statusCode: 200, headers: ["Content-Type": "video/mp4"], body: Data([0, 0, 0, 0x18]), error: nil)
        }

        for url in ["\(Self.origin)/other/clip.mp4", "https://example.test:443/media/clip.mp4"] {
            let parsed = try XCTUnwrap(URL(string: url))
            let tap = route("video", url)
            XCTAssertEqual(tap, .play(.remote(parsed)), url)
            guard case .play(let source) = tap else { continue }

            let resolved = await NativeMediaPresenter.resolve(source, controls: controls)

            guard case .file(let file) = resolved else { return XCTFail("\(url): expected a file, got \(resolved)") }
            XCTAssertTrue(file.isFileURL, "\(url): the player never gets a remote URL")
            XCTAssertEqual(file.pathExtension, "mp4")
            XCTAssertEqual(try Data(contentsOf: file), Data([0, 0, 0, 0x18]))
            let request = try XCTUnwrap(MockURLProtocol.lastRequest)
            XCTAssertEqual(request.url, parsed)
            XCTAssertFalse(request.httpShouldHandleCookies, "\(url): no cookies attached")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        }
        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "clip.mp4"), 2)
    }

    func testRemoteMediaRefusesCleartextRedirectsAndBodiesOverTheCap() async throws {
        let delegate = MediaDownloadDelegate(
            destination: URL(fileURLWithPath: "/tmp/unused"), byteLimit: 8, external: true)
        let session = URLSession(configuration: RemoteMediaClient.configuration())
        let source = try XCTUnwrap(URL(string: "https://media.example/clip.mp4"))
        let response = try XCTUnwrap(HTTPURLResponse(url: source, statusCode: 302, httpVersion: nil, headerFields: nil))
        for (target, allowed) in [
            ("http://media.example/clip.mp4", false), ("https://user@cdn.example/clip.mp4", false),
            ("https://cdn.example/clip.mp4", true),
        ] {
            let proposed = URLRequest(url: try XCTUnwrap(URL(string: target)))
            let result: URLRequest? = await withCheckedContinuation { continuation in
                delegate.urlSession(
                    session, task: session.dataTask(with: source), willPerformHTTPRedirection: response,
                    newRequest: proposed
                ) { continuation.resume(returning: $0) }
            }
            XCTAssertEqual(result != nil, allowed, target)
        }

        MockURLProtocol.stubHandler = { _ in
            .init(
                statusCode: 200, headers: ["Content-Type": "video/mp4"], body: Data(repeating: 1, count: 9), error: nil)
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeMediaPlaybackTests.\(UUID().uuidString).mp4")
        directories.append(destination)
        do {
            _ = try await remoteMedia().download(source, to: destination, byteLimit: 8)
            XCTFail("a body over the cap must be refused")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "nothing over the cap lands")

        MockURLProtocol.stubHandler = { _ in
            .init(
                statusCode: 200, headers: ["Content-Type": "application/vnd.apple.mpegurl"],
                body: Data("#EXTM3U".utf8), error: nil)
        }
        let harness = try await makeHarness([paragraph("lead", "Media")])
        addTeardownBlock { await harness.close() }
        harness.view.blockControls.remoteMedia = remoteMedia()
        let resolved = await NativeMediaPresenter.resolve(.remote(source), controls: harness.view.blockControls)
        XCTAssertEqual(resolved, .notice(NativeEditorLabels().mediaFailed), "a served playlist never plays")
    }

    func testAPlayerClosedBeforeItsFileArrivesNeverPlays() throws {
        let file = try XCTUnwrap(NativeMediaPresenter.stage(Data([0, 0, 0, 0x18]), fileExtension: "mp4"))
        let player = AVPlayerViewController()

        NativeMediaPresenter.start(file, in: player)

        XCTAssertNil(player.player, "a player no longer presented never starts")
    }

    /// Sign-out and an account switch (`SessionStore.forgetSignedInIdentity`) stop the player and
    /// delete what was staged for it.
    func testEndingTheSessionStopsThePlayerAndDeletesStagedFiles() async throws {
        let harness = try await makeHarness([paragraph("lead", "Media"), mediaBlock("video", "clip", url: "")])
        addTeardownBlock { await harness.close() }
        let window = show(harness.view)
        let file = try XCTUnwrap(NativeMediaPresenter.stage(Data([0, 0, 0, 0x18]), fileExtension: "mp4"))
        NativeMediaPresenter.show(
            .play(.local(file)), from: try card(harness.view, "clip"), controls: harness.view.blockControls)
        let player = try XCTUnwrap(window.rootViewController?.presentedViewController as? AVPlayerViewController)
        await waitUntil { player.player?.currentItem != nil }
        let avPlayer = try XCTUnwrap(player.player)
        XCTAssertTrue(NativeMediaPresenter.activePlayer === player)

        NativeMediaPresenter.endSession()

        XCTAssertEqual(avPlayer.rate, 0, "paused")
        XCTAssertNil(avPlayer.currentItem)
        XCTAssertNil(NativeMediaPresenter.activePlayer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: NativeMediaPresenter.stagingDirectory.path))
        await waitUntil { window.rootViewController?.presentedViewController == nil }
    }

    func testPlayingPresentsTheSystemPlayerOverTheCard() async throws {
        let harness = try await makeHarness([paragraph("lead", "Media"), mediaBlock("video", "clip", url: "")])
        addTeardownBlock { await harness.close() }
        let window = show(harness.view)
        let file = try XCTUnwrap(NativeMediaPresenter.stage(Data([0, 0, 0, 0x18]), fileExtension: "mp4"))

        NativeMediaPresenter.show(
            .play(.local(file)), from: try card(harness.view, "clip"), controls: harness.view.blockControls)

        let player = try XCTUnwrap(window.rootViewController?.presentedViewController as? AVPlayerViewController)
        XCTAssertEqual(player.view.accessibilityIdentifier, NativeMediaPresenter.playerIdentifier)
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback, "plays with the silent switch on")
        await waitUntil { player.player != nil }
        XCTAssertEqual((player.player?.currentItem?.asset as? AVURLAsset)?.url, file)
        window.rootViewController?.dismiss(animated: false)
    }

    /// Two previews close together: staging the second keeps the file the first still shows.
    func testStagingAnotherPreviewKeepsAnOpenPreviewsFile() throws {
        NativeMediaPresenter.endSession()
        defer { NativeMediaPresenter.endSession() }
        let first = try XCTUnwrap(NativeMediaPresenter.stage(Data([1, 2, 3]), fileExtension: "png"))
        let preview = NativeMediaPreviewController(url: first)
        let second = try XCTUnwrap(NativeMediaPresenter.stage(Data([4, 5, 6]), fileExtension: "png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path), "the open preview's file stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        NativeMediaPresenter.openPreviewFiles.remove(first)
        _ = try XCTUnwrap(NativeMediaPresenter.stage(Data([7]), fileExtension: "png"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "a closed preview's file is pruned")
        withExtendedLifetime(preview) {}
    }

    /// A video left playing (as in picture in picture, after its controller went away) stops at sign-out.
    func testEndingTheSessionStopsAPlayerWhoseControllerIsGone() throws {
        NativeMediaPresenter.endSession()
        let file = try XCTUnwrap(NativeMediaPresenter.stage(Data([0]), fileExtension: "mp4"))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let player = AVPlayerViewController()
        host.present(player, animated: false)
        NativeMediaPresenter.adoptForTesting(player)
        NativeMediaPresenter.start(file, in: player)
        let playback = try XCTUnwrap(player.player)
        player.player = nil
        host.dismiss(animated: false)
        NativeMediaPresenter.endSession()
        XCTAssertNil(playback.currentItem, "the detached player was stopped and emptied")
    }
}
