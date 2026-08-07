import XCTest

@testable import Schrift

/// The attachment replay: upload a photo queued on this device, checkpoint the resolved URL,
/// rewrite the placeholder, and let the ordinary save machinery push the now-clean body.
@MainActor
final class DocumentSaveCoordinatorAttachmentReplayTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let origin = "https://docs.example.org"
    private let documentID = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!
    private let owner = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    private let otherUser = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!

    private var cacheDirectory: URL!
    private var attachmentDirectory: URL!
    private var suiteNames: [String] = []

    private static let mediaURL = "https://docs.example.org/media/key.jpg"

    override func setUp() {
        super.setUp()
        let unique = UUID().uuidString
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachReplay-\(unique)", isDirectory: true)
        attachmentDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachBytes-\(unique)", isDirectory: true)
        suiteNames = []
    }

    override func tearDown() {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.removeItem(at: attachmentDirectory)
        for name in suiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        super.tearDown()
    }

    private struct Environment {
        let coordinator: DocumentSaveCoordinator
        let drafts: PendingDraftStore
        let attachments: PendingAttachmentStore
        let creates: PendingDocumentCreateStore
        let defaults: UserDefaults
    }

    private func makeEnvironment(sharing defaults: UserDefaults? = nil) -> Environment {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let defaults =
            defaults
            ?? {
                let name = "AttachReplay.\(UUID().uuidString)"
                suiteNames.append(name)
                return UserDefaults(suiteName: name)!
            }()
        let drafts = PendingDraftStore(userDefaults: defaults)
        let attachments = PendingAttachmentStore(userDefaults: defaults, directory: attachmentDirectory)
        let creates = PendingDocumentCreateStore(userDefaults: defaults)
        return Environment(
            coordinator: DocumentSaveCoordinator(
                client: client, draftStore: drafts,
                contentCache: DocumentContentCacheStore(directory: cacheDirectory),
                createStore: creates, attachmentStore: attachments,
                listCache: DocumentCacheStore(userDefaults: defaults),
                childrenCache: DocumentChildrenCacheStore(userDefaults: defaults),
                serverOrigin: origin, mediaCheckMaxAttempts: 2,
                mediaCheckRetryInterval: .milliseconds(1), backgroundTasks: .noop),
            drafts: drafts, attachments: attachments, creates: creates, defaults: defaults)
    }

    /// `/users/me/`, the attachment upload, the media-check poll, `formatted-content` for the
    /// draft replay, and the two save PATCHes.
    private func stubPipeline(
        log: RequestRecorder,
        uploadStatus: Int = 201,
        mediaReady: Bool = true
    ) {
        let origin = origin
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            switch request.httpMethod {
            case "GET" where url.contains("/users/me/"):
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data(
                        """
                        {"id": "55555555-5555-4555-8555-555555555555", "email": "a@b.c", \
                        "full_name": "Ana", "short_name": "Ana", "language": "en"}
                        """.utf8), error: nil)
            case "POST" where url.contains("attachment-upload"):
                return .init(
                    statusCode: uploadStatus, headers: [:],
                    body: Data(#"{"file": "/api/v1.0/documents/x/media-check/?key=key.jpg"}"#.utf8),
                    error: nil)
            case "GET" where url.contains("media-check"):
                let body = mediaReady ? #"{"status":"ready","file":"/media/key.jpg"}"# : #"{"status":"processing"}"#
                return .init(statusCode: 200, headers: [:], body: Data(body.utf8), error: nil)
            case "GET" where url.contains("formatted-content"):
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data(
                        """
                        {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", \
                        "content": "Server", "created_at": "2026-01-15T10:30:00Z", \
                        "updated_at": "2026-01-15T10:30:00Z"}
                        """.utf8), error: nil)
            default:
                _ = origin
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
            }
        }
    }

    private func makeDefaults() -> UserDefaults {
        let name = "AttachReplay.\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    /// Seeds a queued photo **before** the coordinator is built, so its init mirrors the record.
    ///
    /// Deliberately not routed through `queuePendingAttachment`: that kicks the sync funnel, which
    /// would race every arrangement here — the pass could collect or upload the record before the
    /// test had written the draft that references it. `testQueueingAPhotoKicksTheFunnel` covers
    /// that API and its kick on its own.
    private func seedPhoto(
        _ defaults: UserDefaults,
        documentID: UUID? = nil,
        ownerUserID: UUID? = nil,
        uploadedURLString: String? = nil
    ) -> String {
        let store = PendingAttachmentStore(userDefaults: defaults, directory: attachmentDirectory)
        let localID = UUID()
        store.saveData(Data([0xFF, 0xD8, 0xFF]), for: localID)
        store.save(
            PendingAttachment(
                localID: localID, documentID: documentID ?? self.documentID, createdAt: Date(),
                serverOrigin: origin, ownerUserID: ownerUserID ?? owner,
                uploadedURLString: uploadedURLString))
        return pendingAttachmentPlaceholderURL(for: localID)
    }

    private func contentPatches(_ log: RequestRecorder) -> Int {
        log.count(ofMethod: "PATCH", urlContaining: "/content/")
    }

    private func uploads(_ log: RequestRecorder) -> Int {
        log.count(ofMethod: "POST", urlContaining: "attachment-upload")
    }

    // MARK: - The happy path

    func testTheReplayUploadsRewritesTheDraftAndPushesTheCleanBody() async {
        let log = RequestRecorder()
        stubPipeline(log: log)
        let defaults = makeDefaults()
        let placeholder = seedPhoto(defaults)
        let env = makeEnvironment(sharing: defaults)
        env.coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Notes\n\n![](\(placeholder))")

        await env.coordinator.syncPendingDrafts()
        await waitUntil { self.contentPatches(log) == 1 }

        XCTAssertEqual(uploads(log), 1)
        // The record and its bytes are collected once nothing references them.
        XCTAssertNil(env.attachments.attachment(for: pendingAttachmentID(fromPlaceholderURL: placeholder)!))
        XCTAssertNil(env.attachments.data(for: pendingAttachmentID(fromPlaceholderURL: placeholder)!))
    }

    func testThePushedBodyCarriesTheMediaURLAndNeverThePlaceholder() async {
        let log = RequestRecorder()
        let bodies = ContentBodyRecorder()
        stubPipeline(log: log)
        let outer = MockURLProtocol.stubHandler
        MockURLProtocol.stubHandler = { request in
            bodies.record(request)
            return outer!(request)
        }
        let defaults = makeDefaults()
        let placeholder = seedPhoto(defaults)
        let env = makeEnvironment(sharing: defaults)
        env.coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "![](\(placeholder))")

        await env.coordinator.syncPendingDrafts()
        await waitUntil { self.contentPatches(log) == 1 }

        // The whole point: what reaches the server resolves for every collaborator.
        XCTAssertFalse(bodies.joined.contains("schrift-attachment"))
        XCTAssertTrue(bodies.sawContentPatch)
    }

    func testACheckpointedRecordIsNotUploadedTwice() async {
        let log = RequestRecorder()
        stubPipeline(log: log)
        let defaults = makeDefaults()
        // The state a kill between the upload landing and the rewrite leaves behind.
        let placeholder = seedPhoto(defaults, uploadedURLString: Self.mediaURL)
        let env = makeEnvironment(sharing: defaults)
        env.coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "![](\(placeholder))")

        await env.coordinator.syncPendingDrafts()
        await waitUntil { self.contentPatches(log) == 1 }

        XCTAssertEqual(uploads(log), 0, "the checkpoint must skip straight to the rewrite")
    }

    // MARK: - Failure routing

    func testATransientUploadFailureKeepsTheRecordAndTheHold() async {
        let log = RequestRecorder()
        stubPipeline(log: log, uploadStatus: 500)
        let defaults = makeDefaults()
        let placeholder = seedPhoto(defaults)
        let env = makeEnvironment(sharing: defaults)
        let localID = pendingAttachmentID(fromPlaceholderURL: placeholder)!
        env.coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "![](\(placeholder))")

        await env.coordinator.syncPendingDrafts()

        await waitAndConfirmNever { self.contentPatches(log) > 0 }
        XCTAssertNotNil(env.attachments.attachment(for: localID))
        XCTAssertNil(env.attachments.attachment(for: localID)?.failedAt, "5xx is retryable, not terminal")
        XCTAssertNotNil(env.attachments.data(for: localID), "the photo must survive for the retry")
    }

    func testATerminalRejectionIsRecordedAndStillHoldsTheSave() async {
        let log = RequestRecorder()
        stubPipeline(log: log, uploadStatus: 400)
        let defaults = makeDefaults()
        let placeholder = seedPhoto(defaults)
        let env = makeEnvironment(sharing: defaults)
        let localID = pendingAttachmentID(fromPlaceholderURL: placeholder)!
        env.coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "![](\(placeholder))")

        await env.coordinator.syncPendingDrafts()

        await waitAndConfirmNever { self.contentPatches(log) > 0 }
        XCTAssertNotNil(env.attachments.attachment(for: localID)?.failedAt)
        XCTAssertNotNil(env.attachments.data(for: localID), "Retry/Remove need the photo to still exist")
    }

    func testAFailedRecordIsNotRetriedUntilTheUserAsks() async {
        let log = RequestRecorder()
        stubPipeline(log: log, uploadStatus: 400)
        let defaults = makeDefaults()
        let placeholder = seedPhoto(defaults)
        let env = makeEnvironment(sharing: defaults)
        let localID = pendingAttachmentID(fromPlaceholderURL: placeholder)!
        env.coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "![](\(placeholder))")
        await env.coordinator.syncPendingDrafts()
        await waitUntil { env.attachments.attachment(for: localID)?.failedAt != nil }

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(uploads(log), 1, "a terminal failure must not re-POST every pass")
    }

    func testRetryClearsTheFailureSoTheNextPassUploadsAgain() async {
        let log = RequestRecorder()
        stubPipeline(log: log, uploadStatus: 400)
        let defaults = makeDefaults()
        let placeholder = seedPhoto(defaults)
        let env = makeEnvironment(sharing: defaults)
        let localID = pendingAttachmentID(fromPlaceholderURL: placeholder)!
        env.coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "![](\(placeholder))")
        await env.coordinator.syncPendingDrafts()
        await waitUntil { env.attachments.attachment(for: localID)?.failedAt != nil }

        stubPipeline(log: log)
        env.coordinator.retryPendingAttachment(localID: localID)
        await env.coordinator.syncPendingDrafts()

        await waitUntil { self.contentPatches(log) == 1 }
    }

    // MARK: - Scoping and gating

    func testAnotherAccountsQueuedPhotoIsNeitherUploadedNorCollected() async {
        let log = RequestRecorder()
        stubPipeline(log: log)
        let defaults = makeDefaults()
        let placeholder = seedPhoto(defaults, ownerUserID: otherUser)
        let env = makeEnvironment(sharing: defaults)
        let localID = pendingAttachmentID(fromPlaceholderURL: placeholder)!
        // Nothing references it, so an unscoped collection would delete it — and it is the only
        // copy of somebody else's photo. Dormant means no requests *and* no deletion.
        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(uploads(log), 0)
        XCTAssertNotNil(env.attachments.attachment(for: localID))
        XCTAssertNotNil(env.attachments.data(for: localID))
    }

    func testAPhotoInALocallyCreatedDocumentWaitsForItsCreate() async {
        let log = RequestRecorder()
        stubPipeline(log: log)
        let env = makeEnvironment()
        let localDoc = env.coordinator.createLocalDocument(
            title: "Local", parentID: nil, ownerUserID: owner
        ).id
        let placeholder = env.coordinator.queuePendingAttachment(
            documentID: localDoc, ownerUserID: owner, jpegData: Data([0xFF, 0xD8, 0xFF]))!
        env.coordinator.enqueue(documentID: localDoc, title: "Local", markdown: "![](\(placeholder))")

        await env.coordinator.syncPendingDrafts()

        // Uploading here would POST `documents/<local-uuid>/attachment-upload/` and 404. The
        // create replay sends the document first; this photo waits for the pass after it.
        XCTAssertEqual(uploads(log), 0)
        XCTAssertNotNil(env.attachments.attachment(for: pendingAttachmentID(fromPlaceholderURL: placeholder)!))
    }

    func testQueueingAPhotoWritesBytesBeforeTheRecordAndKicksTheFunnel() async {
        let log = RequestRecorder()
        stubPipeline(log: log)
        let env = makeEnvironment()
        // A draft first, so the kicked pass finds the photo referenced and uploads it rather
        // than collecting it — this is the online transient-failure shape.
        let placeholder = env.coordinator.queuePendingAttachment(
            documentID: documentID, ownerUserID: owner, jpegData: Data([0xFF, 0xD8, 0xFF]))!
        env.coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "![](\(placeholder))")

        // No reconnect edge is coming for a photo queued while the network is up, so the queue
        // itself has to start the pass.
        await waitUntil(timeout: 5) { self.contentPatches(log) == 1 }
        XCTAssertEqual(uploads(log), 1)
    }

    // MARK: - Collection

    func testAnUnreferencedRecordIsCollectedWithItsBytes() async {
        let log = RequestRecorder()
        stubPipeline(log: log)
        let defaults = makeDefaults()
        let placeholder = seedPhoto(defaults)
        let env = makeEnvironment(sharing: defaults)
        let localID = pendingAttachmentID(fromPlaceholderURL: placeholder)!
        // No draft ever named it — the user removed the image, or the insert failed.

        await env.coordinator.syncPendingDrafts()

        XCTAssertNil(env.attachments.attachment(for: localID))
        XCTAssertNil(env.attachments.data(for: localID))
        XCTAssertEqual(uploads(log), 0, "an unreferenced photo must not be uploaded first")
    }

    func testCollectionIsDeferredWhileAnEditorIsOpen() async {
        let log = RequestRecorder()
        stubPipeline(log: log)
        let defaults = makeDefaults()
        let placeholder = seedPhoto(defaults)
        let env = makeEnvironment(sharing: defaults)
        let localID = pendingAttachmentID(fromPlaceholderURL: placeholder)!
        env.coordinator.retainOpenEditor(documentID: documentID)

        await env.coordinator.syncPendingDrafts()

        // That screen may be about to flush a body that still names the photo.
        XCTAssertNotNil(env.attachments.attachment(for: localID))
    }

    func testDeletingADocumentDropsItsQueuedPhotos() async {
        let defaults = makeDefaults()
        let placeholder = seedPhoto(defaults)
        let env = makeEnvironment(sharing: defaults)
        let localID = pendingAttachmentID(fromPlaceholderURL: placeholder)!

        env.coordinator.discardPendingWork(documentID: documentID)

        XCTAssertNil(env.attachments.attachment(for: localID))
        XCTAssertNil(env.attachments.data(for: localID))
    }

    func testKeepingTheServerVersionDropsQueuedPhotos() async {
        let defaults = makeDefaults()
        let placeholder = seedPhoto(defaults)
        let env = makeEnvironment(sharing: defaults)
        let localID = pendingAttachmentID(fromPlaceholderURL: placeholder)!
        env.coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "![](\(placeholder))")
        env.coordinator.recordConflict(documentID: documentID, serverUpdatedAt: Date())

        env.coordinator.resolveConflictKeepingServer(documentID: documentID)

        XCTAssertNil(env.attachments.attachment(for: localID))
        XCTAssertNil(env.attachments.data(for: localID))
    }

    // MARK: - Interaction with the conflict hold

    func testTheReplayDoesNotPushOverAnUnansweredConflict() async {
        let log = RequestRecorder()
        stubPipeline(log: log)
        let defaults = makeDefaults()
        let placeholder = seedPhoto(defaults)
        let env = makeEnvironment(sharing: defaults)
        env.coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "![](\(placeholder))")
        // The server moved while the photo sat queued offline.
        env.coordinator.recordConflict(documentID: documentID, serverUpdatedAt: Date())

        await env.coordinator.syncPendingDrafts()

        // The upload may land — the photo is ours either way — but the body must not be pushed
        // over a divergence the user has not answered.
        await waitAndConfirmNever { self.contentPatches(log) > 0 }
        XCTAssertNotNil(env.coordinator.conflict(for: documentID))
    }

    func testAnsweringTheConflictThenPushesTheRewrittenBody() async {
        let log = RequestRecorder()
        stubPipeline(log: log)
        let defaults = makeDefaults()
        let placeholder = seedPhoto(defaults)
        let env = makeEnvironment(sharing: defaults)
        env.coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "![](\(placeholder))")
        env.coordinator.recordConflict(documentID: documentID, serverUpdatedAt: Date())
        await env.coordinator.syncPendingDrafts()
        await waitAndConfirmNever { self.contentPatches(log) > 0 }

        env.coordinator.resolveConflictKeepingLocal(documentID: documentID)

        await waitUntil { self.contentPatches(log) == 1 }
    }

    // MARK: - Two photos

    func testADocumentWithTwoQueuedPhotosPushesOnlyOnceBothLand() async {
        let log = RequestRecorder()
        stubPipeline(log: log)
        let defaults = makeDefaults()
        let first = seedPhoto(defaults)
        let second = seedPhoto(defaults)
        let env = makeEnvironment(sharing: defaults)
        env.coordinator.enqueue(
            documentID: documentID, title: "Doc", markdown: "![](\(first))\n\n![](\(second))")

        await env.coordinator.syncPendingDrafts()

        await waitUntil { self.contentPatches(log) == 1 }
        XCTAssertEqual(uploads(log), 2)
        XCTAssertNil(env.attachments.attachment(for: pendingAttachmentID(fromPlaceholderURL: first)!))
        XCTAssertNil(env.attachments.attachment(for: pendingAttachmentID(fromPlaceholderURL: second)!))
    }

    // MARK: - The open editor's in-memory copy

    func testTheOpenEditorsCopyIsRewrittenInTheSameTurnAsTheDraft() async {
        let log = RequestRecorder()
        stubPipeline(log: log)
        let defaults = makeDefaults()
        let placeholder = seedPhoto(defaults)
        let env = makeEnvironment(sharing: defaults)
        env.coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "![](\(placeholder))")
        var observed: [(String, String)] = []
        env.coordinator.setPendingAttachmentRewriteObserver(
            { placeholder, resolved in observed.append((placeholder, resolved)) }, for: documentID)

        await env.coordinator.syncPendingDrafts()
        await waitUntil { self.contentPatches(log) == 1 }

        // Without this the editor's blocks still name the placeholder, and its next flush would
        // re-enqueue it with no record left to resolve it — a permanent hold.
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed.first?.0, placeholder)
        XCTAssertEqual(observed.first?.1, Self.mediaURL)
    }
}

/// Captures every `PATCH …/content/` body so a test can prove the placeholder never went out.
private final class ContentBodyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String] = []

    func record(_ request: URLRequest) {
        guard request.httpMethod == "PATCH",
            request.url?.absoluteString.hasSuffix("/content/") == true,
            let data = bodyData(from: request)
        else { return }
        lock.lock()
        defer { lock.unlock() }
        bodies.append(String(decoding: data, as: UTF8.self))
    }

    var joined: String {
        lock.lock()
        defer { lock.unlock() }
        return bodies.joined()
    }

    var sawContentPatch: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !bodies.isEmpty
    }
}
