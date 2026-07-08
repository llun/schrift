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
    /// on it), then enters block editing.
    private func makeEditingViewModel(content: String = "Body text.") async -> EditorViewModel {
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
        XCTAssertTrue(viewModel.isDirty)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isUploadingPhoto)
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

    func testInsertPhotoInMarkdownModeInsertsMarkdownAtTheCaret() async throws {
        stubUploadPipeline()
        let viewModel = await makeEditingViewModel()
        viewModel.mode = .markdown
        viewModel.rawMarkdown = "Hello"
        viewModel.selection = NSRange(location: 5, length: 0)

        await viewModel.insertPhoto(loadingData: { testPNGData(width: 8, height: 8) })

        XCTAssertEqual(viewModel.rawMarkdown, "Hello![](\(expectedMediaURL))")
        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: - Readiness poll

    func testInsertPhotoFallsBackToKeyDerivedURLWhenMediaCheckNeverReady() async throws {
        stubUploadPipeline(mediaCheckStatus: "processing")
        let viewModel = await makeEditingViewModel()

        await viewModel.insertPhoto(loadingData: { testPNGData(width: 8, height: 8) })

        // The upload already succeeded — the URL must never be lost.
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
