import XCTest

@testable import Schrift

/// The picked-file fixture. File scope, and so not actor-isolated: it is called
/// from the `@Sendable` `loadingFile` closure the view model takes.
private func pickedPDF(named name: String = "Q3 report.pdf") -> PreparedAttachmentFile {
    PreparedAttachmentFile(fileName: name, contentType: "application/pdf", data: Data("%PDF-1.4\ncontent".utf8))
}

/// Captures the multipart upload request so its body can be asserted on — the
/// shared `RequestRecorder` only keeps methods and URLs, and `lastRequest` is
/// the media-check GET by the time the flow finishes.
private final class AttachmentUploadCapture: @unchecked Sendable {
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

/// The insert half of file attachments: pick → upload → poll → insert a
/// `.attachment` block, and every way that can go wrong.
///
/// Cloned from `EditorPhotoInsertionTests` deliberately — the two flows must
/// stay the same shape, so their tests do too.
@MainActor
final class EditorAttachmentInsertionTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let serverOrigin = "https://docs.example.org"
    private let documentID = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!
    private let attachmentUUID = "22222222-2222-4222-8222-222222222222"

    private var cacheDirectory: URL!
    private var childrenSuiteName: String!
    private var draftSuiteName: String!

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorAttachmentInsertionTests-\(UUID().uuidString)", isDirectory: true)
        childrenSuiteName = "EditorAttachmentInsertionTests.children.\(UUID().uuidString)"
        draftSuiteName = "EditorAttachmentInsertionTests.drafts.\(UUID().uuidString)"
    }

    override func tearDown() {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: cacheDirectory)
        UserDefaults(suiteName: childrenSuiteName)?.removePersistentDomain(forName: childrenSuiteName)
        UserDefaults(suiteName: draftSuiteName)?.removePersistentDomain(forName: draftSuiteName)
        super.tearDown()
    }

    private var expectedMediaURL: String {
        "\(serverOrigin)/media/\(documentID.uuidString.lowercased())/attachments/\(attachmentUUID).pdf"
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
            serverOrigin: serverOrigin, contentCache: contentCache, childrenCache: childrenCache,
            mediaCheckRetryInterval: .zero)
    }

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

    private func stubUploadPipeline(
        mediaCheckStatus: String = "ready", uploadStatus: Int = 201, content: String = "Body text.",
        log: RequestRecorder? = nil, uploadCapture: AttachmentUploadCapture? = nil
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
                    "{\"file\": \"/api/v1.0/documents/\(docID)/media-check/?key=\(docID)%2Fattachments%2F\(attachment).pdf\"}"
                return .init(statusCode: 201, headers: [:], body: Data(body.utf8), error: nil)
            }
            if url.contains("media-check") {
                let body =
                    mediaCheckStatus == "ready"
                    ? "{\"status\": \"ready\", \"file\": \"/media/\(docID)/attachments/\(attachment).pdf\"}"
                    : "{\"status\": \"processing\"}"
                return .init(statusCode: 200, headers: [:], body: Data(body.utf8), error: nil)
            }
            if url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: contentBody, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
    }

    private func attachments(in viewModel: EditorViewModel) -> [(name: String, url: String)] {
        viewModel.blocks.compactMap { block in
            if case .attachment(let name, let url) = block.kind { return (name, url) }
            return nil
        }
    }

    // MARK: - Happy path

    func testInsertAttachmentUploadsAndInsertsABlockWithTheAbsoluteMediaURL() async throws {
        stubUploadPipeline()
        let viewModel = await makeEditingViewModel()

        await viewModel.insertAttachment(loadingFile: { pickedPDF() })

        XCTAssertEqual(attachments(in: viewModel).count, 1)
        XCTAssertEqual(attachments(in: viewModel).first?.url, expectedMediaURL)
        XCTAssertEqual(attachments(in: viewModel).first?.name, "Q3 report.pdf")
        XCTAssertNil(viewModel.errorKey)
        XCTAssertFalse(viewModel.isUploadingAttachment)
    }

    func testTheUploadCarriesThePickedNameAndContentType() async throws {
        let capture = AttachmentUploadCapture()
        stubUploadPipeline(uploadCapture: capture)
        let viewModel = await makeEditingViewModel()

        await viewModel.insertAttachment(loadingFile: { pickedPDF(named: "Q3 report.pdf") })

        let request = try XCTUnwrap(capture.request)
        let body = String(decoding: try XCTUnwrap(bodyData(from: request)), as: UTF8.self)
        XCTAssertTrue(body.contains(#"name="file"; filename="Q3 report.pdf""#), body)
        XCTAssertTrue(body.contains("Content-Type: application/pdf"), body)
        XCTAssertTrue(body.contains("%PDF-1.4"), "the picked bytes must be uploaded verbatim")
    }

    func testTheInsertedBlockSurvivesSerializationAsAnAttachmentLine() async throws {
        stubUploadPipeline()
        let viewModel = await makeEditingViewModel()

        await viewModel.insertAttachment(loadingFile: { pickedPDF() })

        // What a save would actually send.
        XCTAssertTrue(viewModel.currentMarkdown().contains("[Q3 report.pdf](\(expectedMediaURL))"))
    }

    func testInsertingFlushesImmediatelyRatherThanWaitingForAutosave() async throws {
        stubUploadPipeline()
        let viewModel = await makeEditingViewModel()

        await viewModel.insertAttachment(loadingFile: { pickedPDF() })

        // The upload can outlive the screen, so the draft must be on disk now.
        // Probing the coordinator rather than `isDirty`: the insert ends in a
        // `defer`red flush, so `isDirty` is false either way and asserting on it
        // would pass with the flush deleted.
        let stored = viewModel.saveCoordinator.storedDraft(documentID: documentID)
        let pending = viewModel.saveCoordinator.pendingSave(documentID: documentID)
        XCTAssertTrue(
            stored != nil || pending != nil, "the insert must have reached the save pipeline synchronously")
    }

    func testInsertingReplacesTheFocusedEmptyParagraphAndLeavesATrailingOne() async throws {
        stubUploadPipeline(content: "")
        let viewModel = await makeEditingViewModel()
        viewModel.focusedBlockID = try XCTUnwrap(viewModel.blocks.first).id

        await viewModel.insertAttachment(loadingFile: { pickedPDF() })

        XCTAssertEqual(viewModel.blocks.count, 2)
        if case .attachment = viewModel.blocks[0].kind {} else { XCTFail("expected the attachment first") }
        XCTAssertEqual(viewModel.blocks[1].kind, .paragraph)
        XCTAssertEqual(viewModel.focusedBlockID, viewModel.blocks[1].id, "the caret lands after the attachment")
    }

    // MARK: - Reading mode (Done tapped while the upload was in flight)

    func testInsertingAfterLeavingEditModeAppendsToTheSourceAndPreservesBlockIdentities() async throws {
        stubUploadPipeline(content: "Alpha\\n\\nBeta")
        let viewModel = await makeEditingViewModel()
        let idsBefore = viewModel.blocks.map(\.id)
        viewModel.finishEditing()

        await viewModel.insertAttachment(loadingFile: { pickedPDF() })

        // Identities matter: a re-parse would mint new ones and make a live
        // forward diff the whole document as delete-all + reinsert.
        XCTAssertEqual(Array(viewModel.blocks.map(\.id).prefix(idsBefore.count)), idsBefore)
        XCTAssertEqual(attachments(in: viewModel).count, 1)
        XCTAssertTrue(viewModel.currentMarkdown().contains("[Q3 report.pdf](\(expectedMediaURL))"))
    }

    // MARK: - Refusals that must not corrupt the document

    /// A source whose tail is an unterminated fence swallows anything appended
    /// to it, so the attachment would render as literal code. Never rewrite the
    /// source to make room, and never claim success without producing a block.
    func testAnUnterminatedCodeFenceRefusesTheInsertRatherThanCorruptTheDocument() async throws {
        stubUploadPipeline(content: "Intro\\n\\n```swift\\nlet x = 1")
        let viewModel = await makeEditingViewModel()
        viewModel.finishEditing()
        // After finishEditing: reading mode reports `rawMarkdown`, which is the
        // representation the insert would be appending to.
        let markdownBefore = viewModel.currentMarkdown()

        await viewModel.insertAttachment(loadingFile: { pickedPDF() })

        XCTAssertTrue(attachments(in: viewModel).isEmpty)
        XCTAssertEqual(viewModel.errorKey, .editor_error_add_file)
        XCTAssertEqual(viewModel.currentMarkdown(), markdownBefore, "the source must be untouched")
    }

    func testAnOversizedFileReportsItsOwnCopyRatherThanTryAgain() async throws {
        stubUploadPipeline()
        let viewModel = await makeEditingViewModel()

        await viewModel.insertAttachment(loadingFile: { throw AttachmentImportError.tooLarge })

        XCTAssertEqual(viewModel.errorKey, .editor_error_file_too_large)
        XCTAssertTrue(attachments(in: viewModel).isEmpty)
    }

    func testAnUnreadableFileReportsTheGenericError() async throws {
        stubUploadPipeline()
        let viewModel = await makeEditingViewModel()

        await viewModel.insertAttachment(loadingFile: { throw AttachmentImportError.unreadable })

        XCTAssertEqual(viewModel.errorKey, .editor_error_add_file)
    }

    func testACancelledPickerInsertsNothingAndShowsNoError() async throws {
        stubUploadPipeline()
        let viewModel = await makeEditingViewModel()

        await viewModel.insertAttachment(loadingFile: { nil })

        XCTAssertTrue(attachments(in: viewModel).isEmpty)
        XCTAssertNil(viewModel.errorKey)
        XCTAssertFalse(viewModel.isUploadingAttachment)
    }

    func testARejectedUploadReportsTheError() async throws {
        stubUploadPipeline(uploadStatus: 400)
        let viewModel = await makeEditingViewModel()

        await viewModel.insertAttachment(loadingFile: { pickedPDF() })

        XCTAssertTrue(attachments(in: viewModel).isEmpty)
        XCTAssertEqual(viewModel.errorKey, .editor_error_add_file)
    }

    /// The upload already succeeded, so the URL must never be lost just because
    /// readiness could not be confirmed in the poll budget.
    func testAnUnreadyMediaCheckStillInsertsTheKeyDerivedURL() async throws {
        stubUploadPipeline(mediaCheckStatus: "processing")
        let viewModel = await makeEditingViewModel()

        await viewModel.insertAttachment(loadingFile: { pickedPDF() })

        XCTAssertEqual(attachments(in: viewModel).first?.url, expectedMediaURL)
        XCTAssertNil(viewModel.errorKey)
    }

    func testInsertingBeforeContentLoadsIsANoOp() async throws {
        stubUploadPipeline()
        let viewModel = makeViewModel()  // never loaded

        await viewModel.insertAttachment(loadingFile: { pickedPDF() })

        XCTAssertTrue(attachments(in: viewModel).isEmpty)
        XCTAssertNil(viewModel.errorKey)
    }

    /// Without an origin nothing classifies, so the insert's own verification
    /// counts zero attachments and refuses — the loud failure a missing origin
    /// should produce, rather than silently writing a paragraph where the web
    /// expects a file block.
    func testAViewModelWithNoServerOriginRefusesToInsert() async throws {
        stubUploadPipeline()
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: PendingDraftStore(userDefaults: UserDefaults(suiteName: draftSuiteName)!),
            contentCache: DocumentContentCacheStore(directory: cacheDirectory), backgroundTasks: .noop)
        let viewModel = EditorViewModel(
            client: client, documentID: documentID, title: "Doc", saveCoordinator: coordinator,
            contentCache: DocumentContentCacheStore(directory: cacheDirectory),
            childrenCache: DocumentChildrenCacheStore(userDefaults: UserDefaults(suiteName: childrenSuiteName)!),
            mediaCheckRetryInterval: .zero)
        await viewModel.load()
        viewModel.startEditing()

        await viewModel.insertAttachment(loadingFile: { pickedPDF() })

        XCTAssertTrue(attachments(in: viewModel).isEmpty)
        XCTAssertEqual(viewModel.errorKey, .editor_error_add_file)
    }

    // MARK: - One upload at a time

    func testAnAttachmentUploadInFlightWithholdsBothPickers() async throws {
        stubUploadPipeline()
        let viewModel = await makeEditingViewModel()
        viewModel.isUploadingAttachment = true

        XCTAssertFalse(viewModel.canInsertAttachment)
        XCTAssertFalse(viewModel.canInsertPhoto)

        viewModel.requestAttachmentInsertion()
        XCTAssertFalse(viewModel.isAttachmentImporterPresented, "the picker must not open")
    }

    func testAPhotoUploadInFlightWithholdsTheFilePicker() async throws {
        stubUploadPipeline()
        let viewModel = await makeEditingViewModel()
        viewModel.isUploadingPhoto = true

        XCTAssertFalse(viewModel.canInsertAttachment)
    }

    /// Bail out *before* consuming the typed "/file", or the selection silently
    /// eats what the user typed and does nothing.
    func testSelectingTheFileItemWhileUploadingLeavesTheTypedTextIntact() async throws {
        stubUploadPipeline(content: "")
        let viewModel = await makeEditingViewModel()
        let block = try XCTUnwrap(viewModel.blocks.first)
        viewModel.focusedBlockID = block.id
        viewModel.updateText(blockID: block.id, text: "/file")
        viewModel.isUploadingAttachment = true

        let item = try XCTUnwrap(allSlashMenuItems.first { $0.action == .insertAttachment })
        viewModel.applySlashSelection(item)

        XCTAssertEqual(viewModel.blocks.first?.text, "/file")
        XCTAssertFalse(viewModel.isAttachmentImporterPresented)
    }
}
