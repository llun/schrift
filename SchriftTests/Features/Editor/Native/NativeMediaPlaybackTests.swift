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
}
