import XCTest

@testable import Schrift

/// Captures the multipart upload request so its body can be asserted on — the
/// shared `RequestRecorder` only keeps methods and URLs, and `lastRequest` is
/// the media-check GET by the time the flow finishes.
private final class UploadCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URLRequest?

    func capture(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        stored = request
    }

    var request: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

@MainActor
final class EditorPhotoInsertionTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!
    private let attachmentUUID = "22222222-2222-4222-8222-222222222222"

    private var cacheDirectory: URL!
    private var childrenSuiteName: String!
    private var draftSuiteName: String!

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorPhotoInsertionTests-\(UUID().uuidString)", isDirectory: true)
        childrenSuiteName = "EditorPhotoInsertionTests.children.\(UUID().uuidString)"
        draftSuiteName = "EditorPhotoInsertionTests.drafts.\(UUID().uuidString)"
    }

    override func tearDown() {
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
        try? FileManager.default.removeItem(at: cacheDirectory)
        UserDefaults(suiteName: childrenSuiteName)?.removePersistentDomain(forName: childrenSuiteName)
        UserDefaults(suiteName: draftSuiteName)?.removePersistentDomain(forName: draftSuiteName)
        super.tearDown()
    }

    private var expectedMediaURL: String {
        "https://docs.example.org/media/\(documentID.uuidString.lowercased())/attachments/\(attachmentUUID).jpg"
    }

    private func makeViewModel() -> EditorViewModel {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let draftStore = PendingDraftStore(userDefaults: UserDefaults(suiteName: draftSuiteName)!)
        let contentCache = DocumentContentCacheStore(directory: cacheDirectory)
        let childrenCache = DocumentChildrenCacheStore(userDefaults: UserDefaults(suiteName: childrenSuiteName)!)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: draftStore, contentCache: contentCache, backgroundTasks: .noop)
        return EditorViewModel(
            client: client, documentID: documentID, title: "Doc", saveCoordinator: coordinator,
            contentCache: contentCache, childrenCache: childrenCache,
            mediaCheckRetryInterval: .zero)
    }

    /// Loads content so `hasLoadedContent` is true (both photo entry points guard
    /// on it), then enters block editing. The loaded body comes from the stub
    /// installed by `stubUploadPipeline(content:)`.
    private func makeEditingViewModel() async -> EditorViewModel {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.startEditing()
        return viewModel
    }

    private func formattedBody(content: String) -> Data {
        Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "\(content)", \
            "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
            """.utf8)
    }

    /// Routes by URL substring: the content GET, the multipart upload, then the
    /// media-check poll.
    private func stubUploadPipeline(
        mediaCheckStatus: String = "ready", uploadStatus: Int = 201, content: String = "Body text.",
        log: RequestRecorder? = nil, uploadCapture: UploadCapture? = nil
    ) {
        let docID = documentID.uuidString.lowercased()
        let attachment = attachmentUUID
        let contentBody = formattedBody(content: content)
        MockURLProtocol.stubHandler = { request in
            log?.record(request)
            let url = request.url?.absoluteString ?? ""
            if url.contains("attachment-upload") {
                uploadCapture?.capture(request)
                guard uploadStatus == 201 else {
                    return .init(statusCode: uploadStatus, headers: [:], body: Data(), error: nil)
                }
                let body =
                    "{\"file\": \"/api/v1.0/documents/\(docID)/media-check/?key=\(docID)%2Fattachments%2F\(attachment).jpg\"}"
                return .init(statusCode: 201, headers: [:], body: Data(body.utf8), error: nil)
            }
            if url.contains("media-check") {
                let body =
                    mediaCheckStatus == "ready"
                    ? "{\"status\": \"ready\", \"file\": \"/media/\(docID)/attachments/\(attachment).jpg\"}"
                    : "{\"status\": \"processing\"}"
                return .init(statusCode: 200, headers: [:], body: Data(body.utf8), error: nil)
            }
            if url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: contentBody, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
    }

    // MARK: - Happy path

    func testInsertPhotoUploadsAndInsertsImageBlockWithAbsoluteMediaURL() async throws {
        stubUploadPipeline()
        let viewModel = await makeEditingViewModel()
        let photo = testPNGData(width: 20, height: 10)

        await viewModel.insertPhoto(loadingData: { photo })

        XCTAssertTrue(viewModel.blocks.contains { $0.kind == .image(alt: "", url: expectedMediaURL) })
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isUploadingPhoto)
    }

    /// A pop leaves `mode` untouched (only `finishEditing` sets `.reading`), and the
    /// picker's Task is never cancelled — so the insert has to persist itself even
    /// from an ordinary blocks-mode session. Relying on `markDirty`'s debounce would
    /// lose the upload whenever the view model is released before it fires.
    func testInsertPhotoFlushesTheSaveImmediatelyFromBlocksMode() async throws {
        let log = RequestRecorder()
        stubUploadPipeline(log: log)
        let viewModel = await makeEditingViewModel()
        XCTAssertEqual(viewModel.mode, .blocks)

        await viewModel.insertPhoto(loadingData: { testPNGData(width: 8, height: 8) })

        XCTAssertFalse(viewModel.isDirty, "the save must reach the coordinator, not a debounce that dies with the view")
        await waitUntil { log.count(ofMethod: "PATCH", urlContaining: "/content/") == 1 }
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/content/"), 1)
    }

    func testInsertPhotoFlushesTheSaveImmediatelyFromMarkdownMode() async throws {
        let log = RequestRecorder()
        stubUploadPipeline(log: log)
        let viewModel = await makeEditingViewModel()
        viewModel.mode = .markdown
        viewModel.rawMarkdown = "Hello"
        viewModel.selection = NSRange(location: 5, length: 0)

        await viewModel.insertPhoto(loadingData: { testPNGData(width: 8, height: 8) })

        XCTAssertFalse(viewModel.isDirty)
        await waitUntil { log.count(ofMethod: "PATCH", urlContaining: "/content/") == 1 }
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/content/"), 1)
    }

    /// The bytes we upload must be a JPEG *and* be named `photo.jpg`: the backend
    /// magic-sniffs the content and stores the attachment under an `-unsafe` key
    /// (which never renders inline) when the two disagree. The picked photo here
    /// is a PNG, so this also proves the re-encode actually happened.
    func testInsertPhotoUploadsReEncodedJPEGNamedPhotoJPG() async throws {
        let log = RequestRecorder()
        let capture = UploadCapture()
        stubUploadPipeline(log: log, uploadCapture: capture)
        let viewModel = await makeEditingViewModel()

        await viewModel.insertPhoto(loadingData: { testPNGData(width: 20, height: 10) })

        XCTAssertEqual(log.count(ofMethod: "POST", urlContaining: "attachment-upload"), 1)
        let request = try XCTUnwrap(capture.request)
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))

        let body = try XCTUnwrap(bodyData(from: request))
        let bodyString = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyString.contains(#"name="file"; filename="photo.jpg""#))
        XCTAssertTrue(bodyString.contains("Content-Type: image/jpeg"))
        // JPEG SOI marker — the PNG input was re-encoded, not passed through.
        XCTAssertNotNil(body.range(of: Data([0xFF, 0xD8, 0xFF])))
        XCTAssertNil(body.range(of: Data([0x89, 0x50, 0x4E, 0x47])), "PNG signature must not survive")
    }

    /// The image lands where the caret was, with an editable paragraph after it
    /// (an image is a non-editable leaf, so the user must have somewhere to type).
    func testInsertPhotoReplacesTheFocusedEmptyParagraphAndAppendsATrailingParagraph() async throws {
        stubUploadPipeline()
        let viewModel = await makeEditingViewModel()
        viewModel.blocks = [EditorBlock(kind: .paragraph, text: "")]
        viewModel.focusedBlockID = viewModel.blocks[0].id

        await viewModel.insertPhoto(loadingData: { testPNGData(width: 8, height: 8) })

        XCTAssertEqual(viewModel.blocks.count, 2)
        XCTAssertEqual(viewModel.blocks[0].kind, .image(alt: "", url: expectedMediaURL))
        XCTAssertEqual(viewModel.blocks[1].kind, .paragraph)
        XCTAssertEqual(viewModel.focusedBlockID, viewModel.blocks[1].id)
    }

    func testInsertPhotoAfterANonEmptyFocusedBlockInsertsBelowIt() async throws {
        stubUploadPipeline()
        let viewModel = await makeEditingViewModel()
        viewModel.blocks = [
            EditorBlock(kind: .paragraph, text: "before"), EditorBlock(kind: .paragraph, text: "after"),
        ]
        viewModel.focusedBlockID = viewModel.blocks[0].id

        await viewModel.insertPhoto(loadingData: { testPNGData(width: 8, height: 8) })

        XCTAssertEqual(viewModel.blocks.map(\.text).first, "before")
        XCTAssertEqual(viewModel.blocks[1].kind, .image(alt: "", url: expectedMediaURL))
        XCTAssertEqual(viewModel.blocks[2].kind, .paragraph)
        XCTAssertEqual(viewModel.blocks[3].text, "after")
    }

    /// The inserted markdown must actually parse back as an `.image` block.
    /// `parseImageLine` is column-zero anchored and requires the line to end in
    /// `)`, so `Hello![](url)` would round-trip as literal text — the user would
    /// upload a photo and get raw `![](…)` characters in the reading view and on
    /// the web. The image therefore gets a line of its own.
    func testInsertPhotoInMarkdownModeInsertsAStandaloneImageLine() async throws {
        stubUploadPipeline()
        let viewModel = await makeEditingViewModel()
        viewModel.mode = .markdown
        viewModel.rawMarkdown = "Hello"
        viewModel.selection = NSRange(location: 5, length: 0)

        await viewModel.insertPhoto(loadingData: { testPNGData(width: 8, height: 8) })

        XCTAssertNil(viewModel.errorMessage)
        let blocks = parseEditorBlocks(viewModel.rawMarkdown)
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .image(alt: "", url: expectedMediaURL)])
    }

    func testInsertPhotoInMarkdownModeMidLineStillYieldsAStandaloneImage() async throws {
        stubUploadPipeline()
        let viewModel = await makeEditingViewModel()
        viewModel.mode = .markdown
        viewModel.rawMarkdown = "Hello"
        viewModel.selection = NSRange(location: 3, length: 0)  // "Hel|lo"

        await viewModel.insertPhoto(loadingData: { testPNGData(width: 8, height: 8) })

        let blocks = parseEditorBlocks(viewModel.rawMarkdown)
        XCTAssertEqual(
            blocks.map(\.kind), [.paragraph, .image(alt: "", url: expectedMediaURL), .paragraph])
        XCTAssertEqual(blocks.map(\.text), ["Hel", "", "lo"])
    }

    /// Neither Done nor a navigation pop cancels the picker's Task. The image must
    /// still land, `rawMarkdown` must stay in sync, and the save must be enqueued
    /// **immediately** — the autosave debounce is owned by this view model, which a
    /// pop has already released, so it would silently drop the finished upload.
    func testInsertPhotoAfterLeavingEditModeAppendsTheImageAndSavesImmediately() async throws {
        let log = RequestRecorder()
        stubUploadPipeline(log: log)
        let viewModel = await makeEditingViewModel()
        viewModel.blocks = [EditorBlock(kind: .paragraph, text: "Body")]
        viewModel.finishEditing()
        XCTAssertEqual(viewModel.mode, .reading)

        await viewModel.insertPhoto(loadingData: { testPNGData(width: 8, height: 8) })

        XCTAssertTrue(viewModel.blocks.contains { $0.kind == .image(alt: "", url: expectedMediaURL) })
        XCTAssertTrue(
            parseEditorBlocks(viewModel.rawMarkdown).contains { $0.kind == .image(alt: "", url: expectedMediaURL) },
            "rawMarkdown must not go stale, or a markdown-mode save would drop the image")
        XCTAssertFalse(viewModel.isDirty, "the save must be flushed to the coordinator, not left to the debounce")
        await waitUntil { log.count(ofMethod: "PATCH", urlContaining: "/content/") == 1 }
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/content/"), 1)
    }

    /// An `openInMarkdownMode` document's `blocks` are a deliberately lossy parse.
    /// Appending the image via `serializeMarkdown(blocks)` would rewrite the user's
    /// source — here turning an unterminated fence into an empty code block they
    /// never wrote — which is exactly what a full-overwrite save must never do.
    func testInsertPhotoAfterLeavingEditModePreservesALossyMarkdownSource() async throws {
        stubUploadPipeline(content: "Notes\\n```")
        let viewModel = await makeEditingViewModel()
        XCTAssertTrue(viewModel.openInMarkdownMode, "an unterminated fence must not round-trip")
        XCTAssertEqual(viewModel.mode, .markdown)
        viewModel.finishEditing()
        XCTAssertEqual(viewModel.mode, .reading)

        await viewModel.insertPhoto(loadingData: { testPNGData(width: 8, height: 8) })

        XCTAssertTrue(viewModel.rawMarkdown.hasPrefix("Notes\n```"), "the authored source must survive verbatim")
        XCTAssertTrue(viewModel.rawMarkdown.contains("![](\(expectedMediaURL))"))
        XCTAssertFalse(
            viewModel.rawMarkdown.contains("```\n```"),
            "serializing the lossy blocks would invent an empty code block")
        XCTAssertEqual(viewModel.currentMarkdown(), viewModel.rawMarkdown, "the save must carry the source, not blocks")
    }

    /// `openInMarkdownMode` is computed once, in `install()`. A document whose
    /// *loaded* source round-trips but whose *session-authored* source doesn't must
    /// still be saved from its source — so `currentMarkdown()` must not consult that
    /// flag. Here the fence is typed during the session, leaving the flag false.
    func testInsertPhotoPreservesALossySourceAuthoredDuringTheSession() async throws {
        stubUploadPipeline(content: "Notes")
        let viewModel = await makeEditingViewModel()
        XCTAssertFalse(viewModel.openInMarkdownMode, "the loaded source round-trips, so the flag stays false")

        viewModel.mode = .markdown
        viewModel.rawMarkdown = "Notes\n```"  // now lossy, but the flag is stale
        viewModel.finishEditing()
        XCTAssertEqual(viewModel.mode, .reading)

        await viewModel.insertPhoto(loadingData: { testPNGData(width: 8, height: 8) })

        XCTAssertTrue(viewModel.rawMarkdown.hasPrefix("Notes\n```"))
        XCTAssertFalse(
            viewModel.rawMarkdown.contains("```\n```"),
            "a stale openInMarkdownMode must not route the save through the lossy blocks")
        XCTAssertEqual(viewModel.currentMarkdown(), viewModel.rawMarkdown)
    }

    // MARK: - Readiness poll

    /// A ready-on-first-try attachment must be polled exactly once. Without this
    /// the ready path and the key-derived fallback are indistinguishable — both
    /// yield the same URL — so a regression that never polled, or polled forever,
    /// would still pass.
    func testReadyMediaCheckIsPolledExactlyOnce() async throws {
        let log = RequestRecorder()
        stubUploadPipeline(log: log)
        let viewModel = await makeEditingViewModel()

        await viewModel.insertPhoto(loadingData: { testPNGData(width: 8, height: 8) })

        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "media-check"), 1)
        XCTAssertTrue(viewModel.blocks.contains { $0.kind == .image(alt: "", url: expectedMediaURL) })
    }

    func testInsertPhotoFallsBackToKeyDerivedURLWhenMediaCheckNeverReady() async throws {
        let log = RequestRecorder()
        stubUploadPipeline(mediaCheckStatus: "processing", log: log)
        let viewModel = await makeEditingViewModel()

        await viewModel.insertPhoto(loadingData: { testPNGData(width: 8, height: 8) })

        // The poll is bounded: it gives up after a fixed number of attempts…
        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "media-check"), 5)
        // …and the upload already succeeded, so the URL must never be lost.
        XCTAssertTrue(viewModel.blocks.contains { $0.kind == .image(alt: "", url: expectedMediaURL) })
        XCTAssertNil(viewModel.errorMessage)
    }

    /// The upload succeeded but the response carried a path we can't derive a key
    /// from, so there is no URL to embed: fail loudly rather than insert garbage.
    func testInsertPhotoErrorsWhenTheUploadResponseHasNoUsableKey() async throws {
        MockURLProtocol.stubHandler = { [contentBody = formattedBody(content: "Body text.")] request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("attachment-upload") {
                let body = #"{"file": "/api/v1.0/documents/1/media-check/"}"#  // no ?key=
                return .init(statusCode: 201, headers: [:], body: Data(body.utf8), error: nil)
            }
            if url.contains("media-check") {
                return .init(statusCode: 200, headers: [:], body: Data(#"{"status": "processing"}"#.utf8), error: nil)
            }
            if url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: contentBody, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        let viewModel = await makeEditingViewModel()

        await viewModel.insertPhoto(loadingData: { testPNGData(width: 8, height: 8) })

        XCTAssertEqual(viewModel.errorMessage, "Couldn't add the photo. Please try again.")
        XCTAssertFalse(viewModel.blocks.contains { if case .image = $0.kind { return true } else { return false } })
    }

    func testMediaCheckServerErrorsStillFallBackToTheKeyDerivedURL() async throws {
        MockURLProtocol.stubHandler = { [contentBody = formattedBody(content: "Body text.")] request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("attachment-upload") {
                let docID = "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b"
                let body =
                    "{\"file\": \"/api/v1.0/documents/\(docID)/media-check/?key=\(docID)%2Fattachments%2F22222222-2222-4222-8222-222222222222.jpg\"}"
                return .init(statusCode: 201, headers: [:], body: Data(body.utf8), error: nil)
            }
            if url.contains("media-check") {
                return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
            }
            if url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: contentBody, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        let viewModel = await makeEditingViewModel()

        await viewModel.insertPhoto(loadingData: { testPNGData(width: 8, height: 8) })

        XCTAssertTrue(viewModel.blocks.contains { $0.kind == .image(alt: "", url: expectedMediaURL) })
        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: - Failure and cancellation

    func testInsertPhotoUploadFailureSetsFriendlyErrorAndInsertsNothing() async throws {
        stubUploadPipeline(uploadStatus: 400)
        let viewModel = await makeEditingViewModel()
        let blockCountBefore = viewModel.blocks.count

        await viewModel.insertPhoto(loadingData: { testPNGData(width: 8, height: 8) })

        XCTAssertEqual(viewModel.errorMessage, "Couldn't add the photo. Please try again.")
        XCTAssertEqual(viewModel.blocks.count, blockCountBefore)
        XCTAssertFalse(viewModel.blocks.contains { if case .image = $0.kind { return true } else { return false } })
        XCTAssertFalse(viewModel.isUploadingPhoto)
    }

    func testInsertPhotoForbiddenUploadShowsTheSameFriendlyError() async throws {
        stubUploadPipeline(uploadStatus: 403)
        let viewModel = await makeEditingViewModel()

        await viewModel.insertPhoto(loadingData: { testPNGData(width: 8, height: 8) })

        XCTAssertEqual(viewModel.errorMessage, "Couldn't add the photo. Please try again.")
    }

    func testInsertPhotoWithUndecodableDataSetsErrorAndUploadsNothing() async throws {
        let log = RequestRecorder()
        stubUploadPipeline(log: log)
        let viewModel = await makeEditingViewModel()

        await viewModel.insertPhoto(loadingData: { Data([0x00, 0x01, 0x02]) })

        XCTAssertEqual(viewModel.errorMessage, "Couldn't add the photo. Please try again.")
        XCTAssertEqual(log.count(ofMethod: "POST", urlContaining: "attachment-upload"), 0)
    }

    func testInsertPhotoCancelledPickerInsertsNothingAndShowsNoError() async throws {
        let log = RequestRecorder()
        stubUploadPipeline(log: log)
        let viewModel = await makeEditingViewModel()
        let blockCountBefore = viewModel.blocks.count

        await viewModel.insertPhoto(loadingData: { nil })

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.blocks.count, blockCountBefore)
        XCTAssertFalse(viewModel.isUploadingPhoto)
        XCTAssertEqual(log.count(ofMethod: "POST", urlContaining: "attachment-upload"), 0)
    }

    func testInsertPhotoThrowingLoaderSetsFriendlyError() async throws {
        struct PickerFailure: Error {}
        stubUploadPipeline()
        let viewModel = await makeEditingViewModel()

        await viewModel.insertPhoto(loadingData: { throw PickerFailure() })

        XCTAssertEqual(viewModel.errorMessage, "Couldn't add the photo. Please try again.")
        XCTAssertFalse(viewModel.isUploadingPhoto)
    }

    /// Editing may only begin once content has loaded; the same invariant guards
    /// photo insertion, or an upload could race an empty document into a save.
    func testInsertPhotoBeforeContentLoadsIsANoOp() async throws {
        let log = RequestRecorder()
        stubUploadPipeline(log: log)
        let viewModel = makeViewModel()

        await viewModel.insertPhoto(loadingData: { testPNGData(width: 8, height: 8) })

        XCTAssertTrue(viewModel.blocks.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(log.count(ofMethod: "POST", urlContaining: "attachment-upload"), 0)
    }

    // MARK: - Entry points

    func testRequestPhotoInsertionPresentsThePickerOnlyOnceLoaded() async throws {
        stubUploadPipeline()
        let notLoaded = makeViewModel()
        notLoaded.requestPhotoInsertion()
        XCTAssertFalse(notLoaded.isPhotoPickerPresented)

        let viewModel = await makeEditingViewModel()
        viewModel.requestPhotoInsertion()
        XCTAssertTrue(viewModel.isPhotoPickerPresented)
    }

    func testRequestPhotoInsertionIsIgnoredWhileAnUploadIsInFlight() async throws {
        stubUploadPipeline()
        let viewModel = await makeEditingViewModel()
        viewModel.isUploadingPhoto = true

        viewModel.requestPhotoInsertion()

        XCTAssertFalse(viewModel.isPhotoPickerPresented)
    }

    /// The formatting-bar button is disabled while uploading, but the slash menu
    /// stays live. Selecting Photo then must NOT consume the "/photo" the user
    /// typed, or the selection silently eats their text and opens nothing.
    func testSelectingThePhotoSlashItemWhileUploadingLeavesTheTypedTextIntact() async throws {
        stubUploadPipeline()
        let viewModel = await makeEditingViewModel()
        viewModel.blocks = [EditorBlock(kind: .paragraph, text: "/photo")]
        viewModel.focusedBlockID = viewModel.blocks[0].id
        viewModel.slashQueryText = "photo"
        viewModel.isUploadingPhoto = true

        viewModel.applySlashSelection(try XCTUnwrap(allSlashMenuItems.first { $0.action == .insertPhoto }))

        XCTAssertFalse(viewModel.isPhotoPickerPresented)
        XCTAssertEqual(viewModel.blocks[0].text, "/photo")
        XCTAssertEqual(viewModel.slashQueryText, "photo")
    }

    func testSelectingAConvertItemWhileUploadingStillWorks() async throws {
        stubUploadPipeline()
        let viewModel = await makeEditingViewModel()
        viewModel.blocks = [EditorBlock(kind: .paragraph, text: "/quote")]
        viewModel.focusedBlockID = viewModel.blocks[0].id
        viewModel.isUploadingPhoto = true

        viewModel.applySlashSelection(try XCTUnwrap(allSlashMenuItems.first { $0.id == "quote" }))

        XCTAssertEqual(viewModel.blocks[0].kind, .quote)
        XCTAssertEqual(viewModel.blocks[0].text, "")
    }

    func testSelectingThePhotoSlashItemPresentsThePickerAndConsumesTheQuery() async throws {
        stubUploadPipeline()
        let viewModel = await makeEditingViewModel()
        viewModel.blocks = [EditorBlock(kind: .paragraph, text: "/photo")]
        viewModel.focusedBlockID = viewModel.blocks[0].id
        viewModel.slashQueryText = "photo"

        let photoItem = try XCTUnwrap(allSlashMenuItems.first { $0.action == .insertPhoto })
        viewModel.applySlashSelection(photoItem)

        XCTAssertTrue(viewModel.isPhotoPickerPresented)
        XCTAssertEqual(viewModel.blocks[0].kind, .paragraph)
        XCTAssertEqual(viewModel.blocks[0].text, "")
        XCTAssertNil(viewModel.slashQueryText)
    }

    /// The whole slash flow: "/photo" leaves an empty paragraph, which the
    /// successful upload then replaces in place.
    func testSlashPhotoInsertionReplacesTheConsumedParagraph() async throws {
        stubUploadPipeline()
        let viewModel = await makeEditingViewModel()
        viewModel.blocks = [EditorBlock(kind: .paragraph, text: "/photo")]
        viewModel.focusedBlockID = viewModel.blocks[0].id
        viewModel.applySlashSelection(try XCTUnwrap(allSlashMenuItems.first { $0.action == .insertPhoto }))

        await viewModel.insertPhoto(loadingData: { testPNGData(width: 8, height: 8) })

        XCTAssertEqual(viewModel.blocks.count, 2)
        XCTAssertEqual(viewModel.blocks[0].kind, .image(alt: "", url: expectedMediaURL))
        XCTAssertEqual(viewModel.blocks[1].kind, .paragraph)
    }
}
