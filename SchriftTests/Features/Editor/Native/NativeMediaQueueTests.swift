import ImageIO
import UIKit
import XCTest

@testable import Schrift

/// PR13b: the native media queue end to end on real stores. A coordinator over
/// `MockURLProtocol` (nothing reaches a network), a real registry and
/// `ReplicaStore`, records and bytes in `PendingAttachmentStore`: every upload
/// is queued first, uploaded, checkpointed and committed through a headless
/// lease of the document's replica, open editor or not.
@MainActor
final class NativeMediaQueueTests: NativeEditingTestCase {
    private nonisolated static let origin = "https://docs.example"
    /// The web capture's document, so a commit can equal its `updateBlock` XML.
    private nonisolated static let documentID = UUID(uuidString: "0b5d1c0e-7e4b-4c3b-9a35-5b8f3c9b8e11")!
    private nonisolated static let owner = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    private nonisolated static let mediaPath =
        "/media/0b5d1c0e-7e4b-4c3b-9a35-5b8f3c9b8e11/attachments/5f0f6a54-0b1d-4a8e-9f8c-3d2e1f0a9b8c.png"
    private nonisolated static var mediaURL: String { origin + mediaPath }
    private let slot = MediaBlock.Slot(node: "image", url: "")

    /// One device's stores: a second `Device` over the same one is a relaunch.
    private struct Device {
        let directory: URL
        let defaults: UserDefaults
        let scope: ReplicaScope
        var store: ReplicaStore { ReplicaStore(directory: directory.appendingPathComponent("replicas")) }
        var attachments: PendingAttachmentStore {
            PendingAttachmentStore(userDefaults: defaults, directory: directory.appendingPathComponent("bytes"))
        }
    }

    @MainActor
    private struct App {
        let coordinator: DocumentSaveCoordinator
        let registry: NativeSessionRegistry
        let device: Device
        var store: ReplicaStore { coordinator.replicaStore }
    }

    /// What the fake server answers: an upload's status, and the media path its check reports.
    private final class Server: Sendable {
        let log = RequestRecorder()
        let uploadStatus = Locked(201)
        let mediaPath = Locked(NativeMediaQueueTests.mediaPath)
        let offline = Locked(false)
        let gate = Locked<MockURLProtocol.ResponseGate?>(nil)
        /// `documents/{id}/`'s `abilities.update`; nil fails as a transport error (the gate falls
        /// back to the Home lists). `documentStatus` other than 200 answers that status instead;
        /// `answeredID` is the id the answer names; `documentGate` holds it.
        let canUpdate = Locked<Bool?>(nil)
        let documentStatus = Locked(200)
        let answeredID = Locked(NativeMediaQueueTests.documentID)
        let documentGate = Locked<MockURLProtocol.ResponseGate?>(nil)
        /// A failure that is not the server's answer about the document (review R1).
        enum DocumentFailure: String {
            /// An HTML 404: no view for the route (a proxy during a rollout).
            case routeNotFound
            /// A 200 whose body does not decode.
            case decoding
            /// A transport timeout.
            case timeout
        }
        let documentFailure = Locked<DocumentFailure?>(nil)
        var uploads: Int { log.count(ofMethod: "POST", urlContaining: "attachment-upload") }
    }

    /// A capture's seed, or (`applied`) the document after its web edit.
    private func state(_ name: String, applied: Bool) throws -> Data {
        let capture = try XCTUnwrap(BlockNoteMediaCaptures.edits.first { $0.name == name })
        let seed = try XCTUnwrap(Data(base64Encoded: capture.seed))
        guard applied else { return seed }
        let doc = YDoc(clientID: 98)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(seed), origin: .remote)
        try doc.applyUpdate(YUpdateDecoder.decode(try XCTUnwrap(Data(base64Encoded: capture.update))), origin: .remote)
        return try YStateEncoder.encodeStateAsUpdate(doc)
    }

    private func makeDevice(seed: String = "imageCommit", applied: Bool = false, state: Data? = nil) throws -> Device {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativeMediaQueue-\(UUID())")
        let suite = "NativeMediaQueue.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        SignedInUserStore(userDefaults: defaults).remember(Self.owner)
        let scope = ReplicaScope(
            serverOrigin: Self.origin, ownerUserID: Self.owner, org: "docs", documentID: Self.documentID)
        let device = Device(directory: directory, defaults: defaults, scope: scope)
        _ = try device.store.create(for: scope, checkpoint: try state ?? self.state(seed, applied: applied))
        addTeardownBlock {
            MockURLProtocol.reset()
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return device
    }

    /// The app on `device`: a fresh coordinator and registry over its stores (a launch).
    private func launch(_ device: Device, server: Server, leases: Bool = true, writable: Bool = true) -> App {
        let client = DocsAPIClient(
            baseURL: URL(string: Self.origin + "/api/v1.0/")!, session: MockURLProtocol.makeSession(),
            cookieProvider: { [] })
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: PendingDraftStore(userDefaults: device.defaults), replicaStore: device.store,
            contentCache: DocumentContentCacheStore(directory: device.directory.appendingPathComponent("cache")),
            createStore: PendingDocumentCreateStore(userDefaults: device.defaults),
            attachmentStore: device.attachments, listCache: DocumentCacheStore(userDefaults: device.defaults),
            childrenCache: DocumentChildrenCacheStore(userDefaults: device.defaults), serverOrigin: Self.origin,
            mediaCheckMaxAttempts: 1, mediaCheckRetryInterval: .milliseconds(1), backgroundTasks: .noop)
        let registry = NativeSessionRegistry()
        if leases { coordinator.nativeSessions = registry }
        // The headless typing gate (review X2): the switch on, and the account may update the document.
        coordinator.nativeEditorEnabled = { true }
        if writable { allowUpdates(device) }
        coordinator.nativeCommitAttempts = 5
        coordinator.nativeCommitInterval = .milliseconds(10)
        addTeardownBlock { await registry.closeAll().value }
        stub(server)
        return App(coordinator: coordinator, registry: registry, device: device)
    }

    /// The account's cached Home list says it may update the document.
    private func allowUpdates(_ device: Device, _ update: Bool = true) {
        var abilities = DocumentAbilities()
        abilities.update = update
        let document = Document(
            id: Self.documentID, title: "Doc", excerpt: nil, abilities: abilities, linkReach: .restricted,
            linkRole: .reader, isFavorite: false, depth: 1, numchild: 0, path: "0001", createdAt: Date(),
            updatedAt: Date(), userRole: nil, creator: nil)
        DocumentCacheStore(userDefaults: device.defaults).saveRecentDocuments([document], fetchedFor: Self.owner)
    }

    private func stub(_ server: Server) {
        MockURLProtocol.stubHandler = { request in
            server.log.record(request)
            let url = request.url?.absoluteString ?? ""
            if server.offline.value {
                return .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
            }
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
                    statusCode: server.uploadStatus.value, headers: [:],
                    body: Data(#"{"file": "/api/v1.0/documents/x/media-check/?key=k.png"}"#.utf8), error: nil,
                    releasedBy: server.gate.value)
            case "GET" where url.hasSuffix("documents/\(Self.documentID.uuidString.lowercased())/"):
                if server.documentStatus.value != 200 {
                    return .init(statusCode: server.documentStatus.value, headers: [:], body: Data(), error: nil)
                }
                switch server.documentFailure.value {
                case .routeNotFound:
                    return .init(
                        statusCode: 404, headers: ["Content-Type": "text/html"],
                        body: Data("<html><body>Not Found</body></html>".utf8), error: nil)
                case .decoding:
                    return .init(
                        statusCode: 200, headers: [:], body: Data(#"{"id": "not-a-uuid"}"#.utf8), error: nil)
                case .timeout:
                    return .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.timedOut))
                case nil:
                    break
                }
                guard let update = server.canUpdate.value else {
                    return .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
                }
                return .init(
                    statusCode: 200, headers: [:], body: Self.documentJSON(update: update, id: server.answeredID.value),
                    error: nil, releasedBy: server.documentGate.value)
            case "GET" where url.contains("media-check"):
                let body = #"{"status":"ready","file":"\#(server.mediaPath.value)"}"#
                return .init(statusCode: 200, headers: [:], body: Data(body.utf8), error: nil)
            default:
                return .init(statusCode: 404, headers: [:], body: Data(), error: nil)
            }
        }
    }

    private nonisolated static func documentJSON(update: Bool, id: UUID) -> Data {
        Data(
            """
            {"id": "\(id.uuidString.lowercased())", "title": "Doc", "excerpt": null,
             "abilities": {"update": \(update)}, "computed_link_reach": "restricted", "computed_link_role": null,
             "created_at": "2026-01-15T10:30:00Z", "creator": null, "depth": 1, "link_role": "reader",
             "link_reach": "restricted", "numchild": 0, "path": "0001", "updated_at": "2026-01-15T10:30:00Z",
             "user_role": "owner", "is_favorite": false}
            """.utf8)
    }

    /// An editor on the scope, typing through the scope's journal as `installTyping` does.
    private func openEditor(_ app: App) async throws -> NativeEditorSession {
        let session = try await unwrapped(app.registry.open(store: app.store, scope: app.device.scope))
        app.registry.installJournal(
            ReplicaSaveAdapter(store: app.store, scope: app.device.scope), for: app.device.scope)
        session.enableTyping(persist: nil)
        return session
    }

    /// The replica as the journal replays it (what a relaunch restores).
    private func storedXML(_ device: Device) throws -> String {
        let restored = try XCTUnwrap(device.store.restore(for: device.scope))
        let replica = YDoc(clientID: 99)
        defer { replica.destroy() }
        try replica.applyUpdate(YUpdateDecoder.decode(restored.checkpoint), origin: .remote)
        for update in restored.updates { try replica.applyUpdate(YUpdateDecoder.decode(update), origin: .remote) }
        return YXMLString.fragment(replica)
    }

    private func localCommits(_ device: Device) throws -> Int {
        try XCTUnwrap(device.store.restore(for: device.scope)).manifest.journal.filter { $0.origin == .local }.count
    }

    private func target(_ blockID: String = "mx", name: String = "up.bin", slotURL: String = "") -> NativeMediaTarget {
        NativeMediaTarget(
            org: "docs", blockID: blockID, slot: MediaBlock.Slot(node: "image", url: slotURL), fileName: name,
            contentType: "application/octet-stream")
    }

    /// A record left on disk by an earlier process (queued, maybe checkpointed).
    private func leftBehind(
        _ device: Device, blockID: String = "mx", checkpoint: String? = nil, owner: UUID = owner,
        bytes: Data = Data("bytes".utf8), slotURL: String = ""
    ) -> UUID {
        let localID = UUID()
        device.attachments.saveData(bytes, for: localID)
        device.attachments.save(
            PendingAttachment(
                localID: localID, documentID: Self.documentID, createdAt: Date(), serverOrigin: Self.origin,
                ownerUserID: owner, uploadedURLString: checkpoint, native: target(blockID, slotURL: slotURL)))
        return localID
    }

    private nonisolated static let file = PreparedAttachmentFile(
        fileName: "harbour.png", contentType: "image/png", data: testJPEGDataWithGPSMetadata(width: 8, height: 8))

    // MARK: - The queue and the headless commit

    /// The fixture gate: a queued upload with no editor open commits exactly
    /// the web's `updateBlock` XML (name and url set, `previewWidth="undefined"`
    /// removed), once, through a headless lease, and the record goes.
    func testAQueuedUploadCommitsTheWebsUpdateBlockWithNoEditorOpen() async throws {
        let server = Server()
        let app = launch(try makeDevice(), server: server)
        let capture = try XCTUnwrap(BlockNoteMediaCaptures.edits.first { $0.name == "imageCommit" })
        XCTAssertNotNil(app.coordinator.queueNativeAttachment(scope: app.device.scope, target: target(), data: Data()))
        await waitUntil { app.coordinator.nativeAttachments(scope: app.device.scope).isEmpty }
        await waitUntil { app.registry.openScopes.isEmpty }
        XCTAssertEqual(try storedXML(app.device), capture.xml)
        XCTAssertEqual(try localCommits(app.device), 1)
        XCTAssertEqual(server.uploads, 1)
        XCTAssertNotNil(
            server.log.indexOfFirstRequest(
                method: "POST", urlContaining: "documents/\(Self.documentID.uuidString.lowercased())/attachment-upload/"
            ))
    }

    /// Picked in an open editor: the bytes are prepared and queued, the card
    /// says uploading, and the commit reaches the editor by fan-out.
    func testAnUploadFromTheInspectorReachesTheOpenEditor() async throws {
        let server = Server()
        server.gate.value = MockURLProtocol.ResponseGate()
        let app = launch(try makeDevice(), server: server)
        let editor = try await openEditor(app)
        let uploads = NativeMediaUploads(scope: app.device.scope, queue: app.coordinator)
        await uploads.start(.file { Self.file }, into: "mx", slot: slot, in: editor)?.value
        XCTAssertEqual(uploads.uploadingBlocks, ["mx"])
        XCTAssertFalse(uploads.canUpload("mx"), "one upload per block")
        XCTAssertEqual(uploads.record("mx")?.native?.fileName, "harbour.jpg", "an image block's file goes as a JPEG")
        await waitUntil { server.uploads == 1 }
        server.gate.value?.open()
        await waitUntil { uploads.record("mx") == nil }
        await editor.settle()
        let block = try XCTUnwrap(editor.surface.blocks.first { $0.id == "mx" })
        XCTAssertEqual(MediaBlock.string("url", in: block.props), Self.mediaURL)
        XCTAssertEqual(MediaBlock.string("name", in: block.props), "harbour.jpg")
        XCTAssertTrue(uploads.uploadingBlocks.isEmpty)
        XCTAssertEqual(try localCommits(app.device), 1)
        await editor.close().value
    }

    /// PR13a dropped an upload that finished after its editor closed; now the
    /// headless lease commits it into the closed document.
    func testAnUploadFinishingAfterTheEditorClosedStillCommits() async throws {
        let server = Server()
        server.gate.value = MockURLProtocol.ResponseGate()
        let app = launch(try makeDevice(), server: server)
        let editor = try await openEditor(app)
        let uploads = NativeMediaUploads(scope: app.device.scope, queue: app.coordinator)
        await uploads.start(.file { Self.file }, into: "mx", slot: slot, in: editor)?.value
        await waitUntil { server.uploads == 1 }
        await editor.close().value
        server.gate.value?.open()
        await waitUntil { app.coordinator.nativeAttachments(scope: app.device.scope).isEmpty }
        await waitUntil { app.registry.openScopes.isEmpty }
        XCTAssertTrue(try storedXML(app.device).contains(Self.mediaPath))
        XCTAssertEqual(try localCommits(app.device), 1)
    }

    /// Offline the upload is queued, not refused; the reconnect's pass commits it.
    func testOfflineQueuesAndTheNextPassCommits() async throws {
        let server = Server()
        server.offline.value = true
        let app = launch(try makeDevice(), server: server)
        let editor = try await openEditor(app)
        let uploads = NativeMediaUploads(scope: app.device.scope, queue: app.coordinator)
        await uploads.start(.file { Self.file }, into: "mx", slot: slot, in: editor)?.value
        XCTAssertNil(uploads.failure)
        await waitUntil { server.uploads == 1 }
        await waitUntil { app.registry.surfaces(of: app.device.scope).count == 1 }
        let waiting = try XCTUnwrap(uploads.record("mx"))
        XCTAssertNil(waiting.failedAt, "offline is transient")
        XCTAssertNil(waiting.uploadedURLString)
        XCTAssertNotNil(app.device.attachments.data(for: waiting.localID), "the bytes wait on the device")
        server.offline.value = false
        await app.coordinator.syncPendingDrafts()
        await waitUntil { uploads.record("mx") == nil }
        await editor.settle()
        XCTAssertEqual(
            editor.surface.blocks.first { $0.id == "mx" }.map { MediaBlock.string("url", in: $0.props) },
            Self.mediaURL)
        XCTAssertNil(app.device.attachments.data(for: waiting.localID), "the bytes go with the record")
        await editor.close().value
    }

    /// Kill and relaunch: a record killed mid-upload uploads once on the next
    /// launch; one killed after its checkpoint commits without uploading; one
    /// killed after its commit (record not yet removed) is refused by its own
    /// slot and dropped. One block, one URL, never a second photo.
    func testKillAndRelaunchNeverDuplicatesOrLosesAPhoto() async throws {
        let device = try makeDevice()
        let server = Server()
        // Killed mid-upload: no checkpoint.
        let killed = leftBehind(device)
        let first = launch(device, server: server)
        await first.coordinator.syncPendingDrafts()
        await waitUntil { first.coordinator.nativeAttachments(scope: device.scope).isEmpty }
        await waitUntil { first.registry.openScopes.isEmpty }
        XCTAssertEqual(server.uploads, 1)
        XCTAssertEqual(try localCommits(device), 1)
        XCTAssertNil(device.attachments.attachment(for: killed))
        let committed = try storedXML(device)
        XCTAssertTrue(committed.contains(Self.mediaPath))

        // Killed after the commit, before the record went: the slot (url "") no longer holds.
        let again = leftBehind(device, checkpoint: Self.mediaURL)
        let second = launch(device, server: server)
        await second.coordinator.syncPendingDrafts()
        await waitUntil { second.coordinator.nativeAttachments(scope: device.scope).isEmpty }
        await waitUntil { second.registry.openScopes.isEmpty }
        XCTAssertEqual(server.uploads, 1, "a checkpointed record never uploads again")
        XCTAssertEqual(try localCommits(device), 1, "no second commit")
        XCTAssertEqual(try storedXML(device), committed)
        XCTAssertNil(device.attachments.data(for: again))
    }

    /// Killed after the checkpoint, before the commit: the relaunch commits
    /// the checkpointed URL and sends nothing.
    func testACheckpointedRecordCommitsWithoutUploadingAgain() async throws {
        let device = try makeDevice()
        let server = Server()
        _ = leftBehind(device, checkpoint: Self.mediaURL)
        let app = launch(device, server: server)
        await app.coordinator.syncPendingDrafts()
        await waitUntil { app.coordinator.nativeAttachments(scope: app.device.scope).isEmpty }
        await waitUntil { app.registry.openScopes.isEmpty }
        XCTAssertEqual(server.uploads, 0)
        XCTAssertTrue(try storedXML(device).contains(Self.mediaPath))
        XCTAssertEqual(try localCommits(device), 1)
    }

    /// A media block inside a column (the web's slash insertion there) commits
    /// like a root one: the engine resolves the id document-wide.
    func testAColumnsMediaBlockCommitsHeadlessly() async throws {
        let device = try makeDevice(seed: "imageSlashInColumn", applied: true)
        let server = Server()
        // No column recorded: the lease finds the block in its (closed) group (review X6).
        _ = leftBehind(device, blockID: "q")
        let app = launch(device, server: server)
        await app.coordinator.syncPendingDrafts()
        await waitUntil { app.coordinator.nativeAttachments(scope: app.device.scope).isEmpty }
        await waitUntil { app.registry.openScopes.isEmpty }
        let xml = try storedXML(device)
        XCTAssertTrue(xml.contains(#"<column id="c1" width="1"><blockcontainer id="a">"#), xml)
        XCTAssertTrue(
            xml.contains(#"name="up.bin" showPreview="true" textAlignment="left" url="\#(Self.mediaURL)""#), xml)
        XCTAssertEqual(try localCommits(device), 1)
    }

    /// The commit cannot land (an open editor that does not write): the
    /// checkpointed URL stays on the record, and the next pass commits it
    /// without uploading again.
    func testACommitThatCannotLandKeepsItsCheckpoint() async throws {
        let server = Server()
        let app = launch(try makeDevice(), server: server)
        let reader = try await unwrapped(app.registry.open(store: app.store, scope: app.device.scope))
        let localID = try XCTUnwrap(
            app.coordinator.queueNativeAttachment(scope: app.device.scope, target: target(), data: Data()))
        await waitUntil { app.coordinator.pendingAttachment(localID: localID)?.uploadedURLString == Self.mediaURL }
        await waitUntil { app.registry.surfaces(of: app.device.scope).count == 1 }
        XCTAssertEqual(try localCommits(app.device), 0)
        await reader.close().value
        await app.coordinator.syncPendingDrafts()
        await waitUntil { app.coordinator.pendingAttachment(localID: localID) == nil }
        await waitUntil { app.registry.openScopes.isEmpty }
        XCTAssertEqual(server.uploads, 1, "the checkpoint is what keeps a second copy off the server")
        XCTAssertEqual(try localCommits(app.device), 1)
    }

    /// Review X6: a block moved into a column (or another group) after it was
    /// picked is found there and gets its upload; only a block absent from the
    /// whole document is gone.
    func testABlockMovedIntoAColumnStillGetsItsUpload() async throws {
        // The record was made for a root block; the block now sits in column c1 of group cl.
        let device = try makeDevice(seed: "imageSlashInColumn", applied: true)
        let server = Server()
        let localID = leftBehind(device, blockID: "q")
        let app = launch(device, server: server)
        await app.coordinator.syncPendingDrafts()
        await waitUntil { app.coordinator.pendingAttachment(localID: localID) == nil }
        await waitUntil { app.registry.openScopes.isEmpty }
        XCTAssertEqual(server.uploads, 1)
        XCTAssertTrue(try storedXML(device).contains(Self.mediaPath))
    }

    /// Review X2: with nothing open, the headless journal needs the editor
    /// open's typing gate. A reader, an unknown ability or the switch off keep
    /// the record (checkpointed) and write nothing.
    func testTheHeadlessJournalNeedsTheTypingGate() async throws {
        for gate in ["reader", "unknown", "switchOff"] {
            let device = try makeDevice()
            let server = Server()
            let localID = leftBehind(device, checkpoint: Self.mediaURL)
            let app = launch(device, server: server, writable: false)
            if gate == "reader" { allowUpdates(device, false) }
            if gate == "switchOff" {
                allowUpdates(device)
                app.coordinator.nativeEditorEnabled = { false }
            }
            await app.coordinator.syncPendingDrafts()
            await waitUntil { app.registry.openScopes.isEmpty }
            XCTAssertNotNil(app.coordinator.pendingAttachment(localID: localID), gate)
            XCTAssertEqual(try localCommits(device), 0, gate)
        }
    }

    /// Review Y1: the server's reader answer wins over a cached `update: true`
    /// and is remembered, so an offline pass (or a relaunch) never trusts the
    /// stale cache; an editor's reader answer (`noteNativeReader`) counts too.
    func testAReaderAnswerWinsOverTheCacheAndIsRemembered() async throws {
        let device = try makeDevice()
        let server = Server()
        server.canUpdate.value = false
        let localID = leftBehind(device, checkpoint: Self.mediaURL)
        let app = launch(device, server: server)
        await app.coordinator.syncPendingDrafts()
        await waitUntil { app.registry.openScopes.isEmpty }
        XCTAssertNotNil(app.coordinator.pendingAttachment(localID: localID))
        XCTAssertEqual(try localCommits(device), 0)
        // Offline after a relaunch: the cache still says update, the remembered answer does not.
        server.canUpdate.value = nil
        let relaunched = launch(device, server: server)
        await relaunched.coordinator.syncPendingDrafts()
        await waitUntil { relaunched.registry.openScopes.isEmpty }
        XCTAssertEqual(try localCommits(device), 0)
        // The server saying it may again lifts it.
        server.canUpdate.value = true
        await relaunched.coordinator.syncPendingDrafts()
        await waitUntil { relaunched.coordinator.pendingAttachment(localID: localID) == nil }
        XCTAssertEqual(try localCommits(device), 1)
    }

    /// Review Z1: a 403 or 404 about the document is a denial, remembered like
    /// a reader answer (an offline pass afterwards still trusts no cache).
    func testAForbiddenOrMissingAnswerIsADenial() async throws {
        for status in [403, 404] {
            let device = try makeDevice()
            let server = Server()
            server.documentStatus.value = status
            let localID = leftBehind(device, checkpoint: Self.mediaURL)
            let app = launch(device, server: server)
            await app.coordinator.syncPendingDrafts()
            await waitUntil { app.registry.openScopes.isEmpty }
            server.documentStatus.value = 200
            await app.coordinator.syncPendingDrafts()
            await waitUntil { app.registry.openScopes.isEmpty }
            XCTAssertNotNil(app.coordinator.pendingAttachment(localID: localID), "\(status)")
            XCTAssertEqual(try localCommits(device), 0, "\(status)")
        }
    }

    /// Review R1: a missing route (an HTML 404 from a proxy during a rollout), an unreadable
    /// body and a timeout are not the server's answer about the document. No denial is
    /// remembered, and the account's own Home list still allows the commit.
    func testAMissingRouteOrUnreadableAnswerIsNotADenial() async throws {
        for failure in [Server.DocumentFailure.routeNotFound, .decoding, .timeout] {
            let device = try makeDevice()
            let server = Server()
            server.documentFailure.value = failure
            let localID = leftBehind(device, checkpoint: Self.mediaURL)
            let app = launch(device, server: server)
            await app.coordinator.syncPendingDrafts()
            await waitUntil { app.coordinator.pendingAttachment(localID: localID) == nil }
            XCTAssertFalse(app.coordinator.isNativeReader(device.scope), "\(failure)")
            XCTAssertEqual(try localCommits(device), 1, "\(failure)")
        }
    }

    /// Review Z1: offline, only the account's own Home lists may allow a
    /// headless commit: a subpage cache row (any account's) never does.
    func testTheSubpageCacheNeverAllowsAHeadlessCommit() async throws {
        let device = try makeDevice()
        let localID = leftBehind(device, checkpoint: Self.mediaURL)
        var abilities = DocumentAbilities()
        abilities.update = true
        let row = Document(
            id: Self.documentID, title: "Doc", excerpt: nil, abilities: abilities, linkReach: .restricted,
            linkRole: .reader, isFavorite: false, depth: 2, numchild: 0, path: "00010001", createdAt: Date(),
            updatedAt: Date(), userRole: nil, creator: nil)
        DocumentChildrenCacheStore(userDefaults: device.defaults).save([row], for: UUID())
        let app = launch(device, server: Server(), writable: false)
        await app.coordinator.syncPendingDrafts()
        await waitUntil { app.registry.openScopes.isEmpty }
        XCTAssertNotNil(app.coordinator.pendingAttachment(localID: localID))
        XCTAssertEqual(try localCommits(device), 0)
    }

    /// Review Z3: an answer naming another document is no answer for this one.
    func testAnAnswerForAnotherDocumentIsNotTrusted() async throws {
        let device = try makeDevice()
        let server = Server()
        server.canUpdate.value = true
        server.answeredID.value = UUID()
        let localID = leftBehind(device, checkpoint: Self.mediaURL)
        let app = launch(device, server: server, writable: false)
        await app.coordinator.syncPendingDrafts()
        await waitUntil { app.registry.openScopes.isEmpty }
        XCTAssertNotNil(app.coordinator.pendingAttachment(localID: localID))
        XCTAssertEqual(try localCommits(device), 0)
    }

    /// Review Z2: a reader answer never commits, even when an editor made the
    /// scope writable while the question was out (it may be on a stale row).
    func testAReaderAnswerNeverCommitsThroughAnEditorThatOpenedMeanwhile() async throws {
        let device = try makeDevice()
        let server = Server()
        server.canUpdate.value = false
        let gate = MockURLProtocol.ResponseGate()
        server.documentGate.value = gate
        let localID = leftBehind(device, checkpoint: Self.mediaURL)
        let app = launch(device, server: server)
        let pass = Task { await app.coordinator.syncPendingDrafts() }
        await waitUntil {
            server.log.count(ofMethod: "GET", urlContaining: "documents/\(Self.documentID.uuidString.lowercased())/")
                == 1
        }
        let editor = try await openEditor(app)
        gate.open()
        await pass.value
        await waitUntil { app.registry.surfaces(of: device.scope).count == 1 }
        XCTAssertNotNil(app.coordinator.pendingAttachment(localID: localID))
        XCTAssertEqual(try localCommits(device), 0)
        // The denial ends the editor's writability too (review Z2b)…
        await editor.settle()
        XCTAssertFalse(editor.state.writable, "the open editor became a reader")
        // …and a second replay while it is still open commits nothing either.
        server.canUpdate.value = nil
        await app.coordinator.syncPendingDrafts()
        await waitUntil { app.registry.surfaces(of: device.scope).count == 1 }
        XCTAssertNotNil(app.coordinator.pendingAttachment(localID: localID))
        XCTAssertEqual(try localCommits(device), 0)
        await editor.close().value
    }

    /// Review Z2b: a remembered denial stops a commit through an editor that is
    /// writable on its own row (opened before the pass, the server unreachable).
    func testARememberedDenialStopsACommitThroughAWritableEditor() async throws {
        let device = try makeDevice()
        let localID = leftBehind(device, checkpoint: Self.mediaURL)
        let app = launch(device, server: Server())
        app.coordinator.noteNativeReader(device.scope)
        let editor = try await openEditor(app)
        await app.coordinator.syncPendingDrafts()
        await waitUntil { app.registry.surfaces(of: device.scope).count == 1 }
        XCTAssertNotNil(app.coordinator.pendingAttachment(localID: localID))
        XCTAssertEqual(try localCommits(device), 0)
        await editor.close().value
    }

    /// Review F1: a web-authored media block nested under a column's paragraph
    /// (in a group that is not open) is found and gets its upload, never
    /// declared gone.
    func testANestedMediaBlockInAClosedColumnGetsItsUpload() async throws {
        let device = try makeDevice(state: try Self.nestedImageInColumn())
        let localID = leftBehind(device, blockID: "n", checkpoint: Self.mediaURL, slotURL: Self.oldImageURL)
        let app = launch(device, server: Server())
        await app.coordinator.syncPendingDrafts()
        await waitUntil { app.registry.openScopes.isEmpty }
        let xml = try storedXML(device)
        XCTAssertTrue(xml.contains(Self.mediaPath), xml)
        XCTAssertNil(app.coordinator.pendingAttachment(localID: localID))
    }

    nonisolated static let oldImageURL =
        "https://docs.example/media/0b5d1c0e-7e4b-4c3b-9a35-5b8f3c9b8e11/attachments/1f0f6a54-0b1d-4a8e-9f8c-3d2e1f0a9b8c.png"

    /// Lead, then a group `cl` whose column `c1` holds paragraph `a` with a
    /// plain image `n` (the web's nested shape) under it, then column `c2`, then tail.
    nonisolated static func nestedImageInColumn() throws -> Data {
        let doc = YDoc(clientID: 1, gc: true)
        defer { doc.destroy() }
        let root = doc.get(BlockNoteYjs.fragmentField)
        try doc.transact { tx in
            func element(_ name: String, into parent: YType, after: YItem?, id: String? = nil) throws -> (YItem?, YType)
            {
                let type = YType(typeRef: .xmlElement(nodeName: name))
                let item = try YWrite.insertAfter(tx, into: parent, after: after, [.type(type)])
                if let id { try YWrite.mapSet(tx, on: type, key: "id", .any([.string(id)])) }
                return (item, type)
            }
            func paragraph(_ id: String, _ text: String, into parent: YType, after: YItem?) throws
                -> (item: YItem?, container: YType, paragraph: YItem?)
            {
                let (item, container) = try element("blockContainer", into: parent, after: after, id: id)
                let (paragraphItem, paragraph) = try element("paragraph", into: container, after: nil)
                for (key, value) in [
                    ("backgroundColor", "default"), ("textColor", "default"), ("textAlignment", "left"),
                ] {
                    try YWrite.mapSet(tx, on: paragraph, key: key, .any([.string(value)]))
                }
                let xmlText = YType(typeRef: .xmlText)
                try YWrite.insertAfter(tx, into: paragraph, after: nil, [.type(xmlText)])
                try xmlText.insert(0, text, YTextAttributes())
                return (item, container, paragraphItem)
            }
            let (_, group) = try element("blockGroup", into: root, after: nil)
            let lead = try paragraph("lead", "Before", into: group, after: nil).item
            let (listItem, list) = try element("columnList", into: group, after: lead, id: "cl")
            let (c1Item, c1) = try element("column", into: list, after: nil, id: "c1")
            try YWrite.mapSet(tx, on: c1, key: "width", .any([.int(1)]))
            let a = try paragraph("a", "Left", into: c1, after: nil)
            let (_, nested) = try element("blockGroup", into: a.container, after: a.paragraph)
            let (_, container) = try element("blockContainer", into: nested, after: nil, id: "n")
            let (_, image) = try element("image", into: container, after: nil)
            for (key, value): (String, YAnyValue) in [
                ("textAlignment", .string("left")), ("backgroundColor", .string("default")),
                ("name", .string("old.png")),
                ("url", .string(oldImageURL)), ("caption", .string("")), ("showPreview", .bool(true)),
                ("previewWidth", .undefined),
            ] {
                try YWrite.mapSet(tx, on: image, key: key, .any([value]))
            }
            let (_, c2) = try element("column", into: list, after: c1Item, id: "c2")
            try YWrite.mapSet(tx, on: c2, key: "width", .any([.int(1)]))
            _ = try paragraph("c", "Right", into: c2, after: nil)
            _ = try paragraph("tail", "After", into: group, after: listItem)
        }
        return try YStateEncoder.encodeStateAsUpdate(doc)
    }

    /// Review Y1: an editor's reader answer is remembered for the scope.
    func testAnEditorsReaderAnswerBlocksAHeadlessCommit() async throws {
        let device = try makeDevice()
        let localID = leftBehind(device, checkpoint: Self.mediaURL)
        let app = launch(device, server: Server())
        app.coordinator.noteNativeReader(device.scope)
        await app.coordinator.syncPendingDrafts()
        await waitUntil { app.registry.openScopes.isEmpty }
        XCTAssertNotNil(app.coordinator.pendingAttachment(localID: localID))
        XCTAssertEqual(try localCommits(device), 0)
    }

    /// Review Y3: a document outside the Home lists (a folder, a deep link)
    /// commits headlessly once the server says it may be updated; while
    /// nothing may write it, its card says it waits, not that it uploads.
    func testADocumentOutsideTheCachesAsksTheServer() async throws {
        let device = try makeDevice()
        let server = Server()
        let localID = leftBehind(device, checkpoint: Self.mediaURL)
        let app = launch(device, server: server, writable: false)
        let uploads = NativeMediaUploads(scope: device.scope, queue: app.coordinator)
        await app.coordinator.syncPendingDrafts()
        await waitUntil { app.registry.openScopes.isEmpty }
        XCTAssertEqual(uploads.waitingBlocks, ["mx"], "unknown ability: it waits")
        XCTAssertTrue(uploads.uploadingBlocks.isEmpty, "never claims to upload")
        server.canUpdate.value = true
        await app.coordinator.syncPendingDrafts()
        await waitUntil { app.coordinator.pendingAttachment(localID: localID) == nil }
        XCTAssertEqual(try localCommits(device), 1)
    }

    /// Review Y2: deleting the document drops only this account's records:
    /// another account's queued photo of the same document keeps its bytes.
    func testDeletingTheDocumentKeepsAnotherAccountsRecords() async throws {
        let device = try makeDevice()
        let mine = leftBehind(device)
        let theirs = leftBehind(device, owner: UUID())
        let app = launch(device, server: Server(), leases: false)
        app.coordinator.discardPendingWork(documentID: Self.documentID)
        XCTAssertNil(device.attachments.attachment(for: mine))
        XCTAssertNotNil(device.attachments.attachment(for: theirs))
        XCTAssertNotNil(device.attachments.data(for: theirs))
    }

    /// Review X3: a checkpoint restored from disk is checked like a fresh
    /// answer before it is committed: another document's URL fails the record.
    func testARestoredCheckpointIsCheckedBeforeTheCommit() async throws {
        let device = try makeDevice()
        let other =
            "\(Self.origin)/media/\(UUID().uuidString.lowercased())/attachments/5f0f6a54-0b1d-4a8e-9f8c-3d2e1f0a9b8c.png"
        let localID = leftBehind(device, checkpoint: other)
        let app = launch(device, server: Server())
        await app.coordinator.syncPendingDrafts()
        await waitUntil { app.coordinator.pendingAttachment(localID: localID)?.failedAt != nil }
        XCTAssertEqual(try localCommits(device), 0)
    }

    /// Review X4: bytes on disk over the picker's limit are never read or sent.
    func testReplayedBytesOverTheLimitFailUnsent() async throws {
        let device = try makeDevice()
        let server = Server()
        let localID = leftBehind(device, bytes: Data(count: 64))
        let app = launch(device, server: server)
        app.coordinator.nativeAttachmentByteLimit = 32
        await app.coordinator.syncPendingDrafts()
        await waitUntil { app.coordinator.pendingAttachment(localID: localID)?.failedAt != nil }
        XCTAssertEqual(server.uploads, 0)
    }

    /// Review X7: a headless commit made while a surface holds the replica
    /// never leaves its own scheduler as the scope's: the editor that asks for
    /// the scope's scheduler next gets its own, with the editor's save rules.
    func testTheHeadlessSchedulerNeverBecomesTheEditors() async throws {
        let device = try makeDevice()
        _ = leftBehind(device, checkpoint: Self.mediaURL)
        let app = launch(device, server: Server())
        let editor = try await openEditor(app)
        await app.coordinator.syncPendingDrafts()
        await waitUntil { app.coordinator.nativeAttachments(scope: device.scope).isEmpty }
        await waitUntil { app.registry.surfaces(of: device.scope).count == 1 }
        XCTAssertEqual(try localCommits(device), 1)
        let mine = NativeReplicaSaveScheduler(enqueue: { true }, onFailure: { _ in })
        XCTAssertTrue(app.registry.scheduler(for: device.scope) { mine } === mine)
        await editor.close().value
    }

    /// Review X8: a headless surface whose epoch moved (a resync after its
    /// delivery bound) still commits: it posts with its current epoch.
    func testAHeadlessCommandPostsWithTheSurfacesEpoch() async throws {
        let app = launch(try makeDevice(), server: Server())
        let surface = try await unwrapped(app.registry.open(store: app.store, scope: app.device.scope))
        app.registry.installJournal(
            ReplicaSaveAdapter(store: app.store, scope: app.device.scope), for: app.device.scope)
        let replica = try XCTUnwrap(surface.replica)
        // More deliveries than the bound while the main actor is busy: a resync moves the epoch.
        for _ in 0..<(DocumentReplicaSession.deliveryBound * 2) {
            replica.mailbox.post(.drain(surfaceID: surface.surfaceID, token: UUID()))
        }
        // As the lease does: settle, post, and go again on `.stale` (a resync may still be on its way).
        var result: ReplicaResult?
        for _ in 0..<5 {
            await surface.settle()
            result = await surface.post(
                .mediaProps([ProjectedProp(key: "url", value: .string(Self.mediaURL))], expecting: slot), blockID: "mx")
            if case .stale? = result { continue }
            break
        }
        guard case .applied? = result else { return XCTFail("\(String(describing: result))") }
        await surface.close().value
    }

    /// A block deleted while its photo waited: the record and bytes go before
    /// anything is uploaded.
    func testADeletedBlockDropsTheRecordBeforeAnyUpload() async throws {
        let device = try makeDevice()
        let server = Server()
        let localID = leftBehind(device, blockID: "gone")
        let app = launch(device, server: server)
        await app.coordinator.syncPendingDrafts()
        await waitUntil { app.coordinator.nativeAttachments(scope: app.device.scope).isEmpty }
        XCTAssertEqual(server.uploads, 0)
        XCTAssertNil(device.attachments.data(for: localID))
        XCTAssertEqual(try localCommits(device), 0)
    }

    /// The block is filled (a link, a peer) while its upload runs: the commit's
    /// slot no longer holds, nothing is written over it and the record goes.
    func testABlockFilledDuringTheUploadRefusesTheCommit() async throws {
        let server = Server()
        server.gate.value = MockURLProtocol.ResponseGate()
        let app = launch(try makeDevice(), server: server)
        let editor = try await openEditor(app)
        let uploads = NativeMediaUploads(scope: app.device.scope, queue: app.coordinator)
        await uploads.start(.file { Self.file }, into: "mx", slot: slot, in: editor)?.value
        await waitUntil { server.uploads == 1 }
        let other = "https://other.example/picture.png"
        _ = await editor.run { editor.input!.setMediaProps("mx", [ProjectedProp(key: "url", value: .string(other))]) }
        server.gate.value?.open()
        await waitUntil { uploads.record("mx") == nil }
        await editor.settle()
        XCTAssertEqual(
            editor.surface.blocks.first { $0.id == "mx" }.map { MediaBlock.string("url", in: $0.props) }, other)
        XCTAssertFalse(try storedXML(app.device).contains(Self.mediaPath))
        XCTAssertEqual(try localCommits(app.device), 1, "only the link")
        await editor.close().value
    }

    /// A rejection on the merits fails the record (bytes kept, the card says
    /// so); Retry uploads again and commits; Discard drops the bytes.
    func testARejectedUploadFailsThenRetryCommitsOrDiscardDrops() async throws {
        let server = Server()
        server.uploadStatus.value = 400
        let app = launch(try makeDevice(), server: server)
        let editor = try await openEditor(app)
        let uploads = NativeMediaUploads(scope: app.device.scope, queue: app.coordinator)
        await uploads.start(.file { Self.file }, into: "mx", slot: slot, in: editor)?.value
        await waitUntil { uploads.failedBlocks == ["mx"] }
        XCTAssertTrue(uploads.uploadingBlocks.isEmpty)
        let failed = try XCTUnwrap(uploads.record("mx"))
        XCTAssertNotNil(app.device.attachments.data(for: failed.localID))
        server.uploadStatus.value = 201
        uploads.retry("mx")
        await waitUntil { uploads.record("mx") == nil }
        await editor.settle()
        XCTAssertEqual(
            editor.surface.blocks.first { $0.id == "mx" }.map { MediaBlock.string("url", in: $0.props) },
            Self.mediaURL)

        // Discard: the next failed upload's bytes go, the block stays as it is.
        server.uploadStatus.value = 400
        _ = await editor.run {
            editor.input!.setMediaProps("mx", [ProjectedProp(key: "url", value: .string(""))])
        }
        await uploads.start(.file { Self.file }, into: "mx", slot: slot, in: editor)?.value
        await waitUntil { uploads.failedBlocks == ["mx"] }
        let second = try XCTUnwrap(uploads.record("mx"))
        uploads.discard("mx")
        XCTAssertNil(uploads.record("mx"))
        XCTAssertNil(app.device.attachments.data(for: second.localID))
        await editor.close().value
    }

    /// An answered URL that is not this server's attachment for this document
    /// is never written; the record fails for the user to answer.
    func testOnlyThisDocumentsMediaURLIsWritten() async throws {
        let server = Server()
        server.mediaPath.value =
            "/media/\(UUID().uuidString.lowercased())/attachments/5f0f6a54-0b1d-4a8e-9f8c-3d2e1f0a9b8c.png"
        let app = launch(try makeDevice(), server: server)
        app.coordinator.queueNativeAttachment(scope: app.device.scope, target: target(), data: Data())
        await waitUntil { app.coordinator.nativeAttachments(scope: app.device.scope).first?.failedAt != nil }
        XCTAssertEqual(try localCommits(app.device), 0)
    }

    /// Another account's record on this device is never sent nor collected,
    /// and nothing is queued for a scope that is not the signed-in account's.
    func testAnotherAccountsRecordIsNeverSentNorCollected() async throws {
        let device = try makeDevice()
        let server = Server()
        let other = UUID()
        let localID = leftBehind(device, owner: other)
        let app = launch(device, server: server)
        await app.coordinator.syncPendingDrafts()
        await waitAndConfirmNever { server.uploads > 0 }
        XCTAssertNotNil(device.attachments.attachment(for: localID))
        XCTAssertNotNil(device.attachments.data(for: localID))
        let foreign = ReplicaScope(
            serverOrigin: Self.origin, ownerUserID: other, org: "docs", documentID: Self.documentID)
        XCTAssertNil(app.coordinator.queueNativeAttachment(scope: foreign, target: target(), data: Data()))
        // This account's card and inspector never show, retry or discard it (review X5).
        let uploads = NativeMediaUploads(scope: device.scope, queue: app.coordinator)
        XCTAssertNil(uploads.record("mx"))
        XCTAssertTrue(uploads.uploadingBlocks.isEmpty)
        uploads.discard("mx")
        XCTAssertNotNil(device.attachments.data(for: localID))
    }

    /// A sign-in switch (cookies about to change) before the request is built:
    /// nothing is sent and the record waits, untouched.
    func testASignInSwitchSendsNothing() async throws {
        let server = Server()
        let app = launch(try makeDevice(), server: server)
        let clock = SignInGenerationClock()
        app.coordinator.signInIsCurrent = { clock.isCurrent() }
        let localID = try XCTUnwrap(
            app.coordinator.queueNativeAttachment(scope: app.device.scope, target: target(), data: Data()))
        clock.beginSwitch()
        await waitAndConfirmNever { server.uploads > 0 }
        XCTAssertNotNil(app.device.attachments.attachment(for: localID))
        XCTAssertNil(app.device.attachments.attachment(for: localID)?.failedAt)
    }

    /// The classic pass collects a record no Markdown names; a native record
    /// names none and must survive it until its own run decides.
    func testTheClassicPassNeverCollectsANativeRecord() async throws {
        let device = try makeDevice()
        let server = Server()
        let localID = leftBehind(device)
        let app = launch(device, server: server, leases: false)
        await app.coordinator.syncPendingDrafts()
        XCTAssertNotNil(device.attachments.attachment(for: localID))
        XCTAssertNotNil(device.attachments.data(for: localID))
    }

    /// Deleting the document drops its native records and their bytes.
    func testDeletingTheDocumentDropsItsRecords() async throws {
        let device = try makeDevice()
        let localID = leftBehind(device)
        let app = launch(device, server: Server(), leases: false)
        app.coordinator.discardPendingWork(documentID: Self.documentID)
        XCTAssertNil(device.attachments.attachment(for: localID))
        XCTAssertNil(device.attachments.data(for: localID))
    }

    // MARK: - Preparation (PR13a, now feeding the queue)

    /// A photo is re-encoded as a JPEG before it is queued (metadata stripped),
    /// and an image block's picked file too (review A2): no GPS leaves.
    func testPhotosAndImageFilesAreQueuedAsJPEGsWithoutMetadata() async throws {
        let app = launch(try makeDevice(), server: Server(), leases: false)
        let editor = try await openEditor(app)
        let uploads = NativeMediaUploads(scope: app.device.scope, queue: app.coordinator)
        let original = testJPEGDataWithGPSMetadata(width: 60, height: 40)
        XCTAssertNotNil(testImageProperties(of: original)?[kCGImagePropertyGPSDictionary], "the fixture carries GPS")
        await uploads.start(.photo { original }, into: "mx", slot: slot, in: editor)?.value
        let photo = try XCTUnwrap(uploads.record("mx"))
        XCTAssertEqual(photo.native?.fileName, "photo.jpg")
        XCTAssertEqual(photo.native?.contentType, "image/jpeg")
        let bytes = try XCTUnwrap(app.device.attachments.data(for: photo.localID))
        XCTAssertNil(testImageProperties(of: bytes)?[kCGImagePropertyGPSDictionary], "no GPS queued")
        uploads.discard("mx")
        let picked = PreparedAttachmentFile(fileName: "harbour.JPG", contentType: "image/jpeg", data: original)
        await uploads.start(.file { picked }, into: "mx", slot: slot, in: editor)?.value
        let file = try XCTUnwrap(uploads.record("mx"))
        XCTAssertEqual(file.native?.fileName, "harbour.jpg")
        let fileBytes = try XCTUnwrap(app.device.attachments.data(for: file.localID))
        XCTAssertNil(testImageProperties(of: fileBytes)?[kCGImagePropertyGPSDictionary])
        await editor.close().value
    }

    /// The editor closes (another account's reopen, a sign-out) while a photo
    /// is prepared: nothing is queued (review A3); a too-large file fails with
    /// its own notice; a local document cannot upload.
    func testClosedDuringPreparationTooLargeAndLocalAreRefused() async throws {
        let app = launch(try makeDevice(), server: Server(), leases: false)
        let editor = try await openEditor(app)
        let uploads = NativeMediaUploads(scope: app.device.scope, queue: app.coordinator)
        await uploads.start(.file { throw AttachmentImportError.tooLarge }, into: "mx", slot: slot, in: editor)?.value
        XCTAssertEqual(uploads.failure?.key, .editor_error_file_too_large)
        let local = NativeMediaUploads(scope: nil, queue: app.coordinator)
        XCTAssertNil(local.start(.file { Self.file }, into: "mx", slot: slot, in: editor))
        XCTAssertEqual(local.failure?.key, .native_editor_media_upload_offline)
        let gate = Latch()
        let task = try XCTUnwrap(
            uploads.start(
                .file {
                    await gate.passing()
                    return Self.file
                }, into: "mx", slot: slot, in: editor))
        await editor.close().value
        gate.open()
        await task.value
        XCTAssertEqual(uploads.failure?.key, .native_editor_media_upload_dropped)
        XCTAssertTrue(app.coordinator.nativeAttachments(scope: app.device.scope).isEmpty)
    }

    /// Concurrent `uploads.start(...)` calls for multiple blocks mark all
    /// targets as preparing/uploading immediately, serialize off-main byte
    /// preparation so only one buffer is decoded at a time, and queue every
    /// item through `queueNativeAttachment` with GPS metadata stripped.
    func testMultiItemUploadsPrepareSeriallyAndQueueEveryBlock() async throws {
        let server = Server()
        server.canUpdate.value = true
        let app = launch(try makeDevice(), server: server)
        let editor = try await openEditor(app)
        let uploads = NativeMediaUploads(scope: app.device.scope, queue: app.coordinator)
        XCTAssertTrue(uploads.canStartAnyUpload)

        // Seed 3 real empty media blocks via `.insertMediaBatch` so the upload commits end-to-end.
        var batchIDs: [String] = []
        _ = await editor.run {
            editor.input?.insertMediaBatch(nodes: ["image", "image", "pdf"], at: "mx", placement: .after) {
                batchIDs = $0
            } ?? false
        }
        await editor.settle()
        XCTAssertEqual(batchIDs.count, 3)
        let (m1, m2, m3) = (batchIDs[0], batchIDs[1], batchIDs[2])

        final class Tracker: @unchecked Sendable {
            private let lock = NSLock()
            var active = 0
            var maxActive = 0
            var order: [String] = []
            func enter(_ id: String) {
                lock.lock()
                defer { lock.unlock() }
                active += 1
                maxActive = max(maxActive, active)
                order.append(id)
            }
            func leave() {
                lock.lock()
                defer { lock.unlock() }
                active -= 1
            }
        }
        let tracker = Tracker()
        let firstEntered = Latch()
        let releaseFirst = Latch()
        let gpsImage = testJPEGDataWithGPSMetadata(width: 60, height: 40)
        XCTAssertNotNil(testImageProperties(of: gpsImage)?[kCGImagePropertyGPSDictionary])

        server.gate.value = MockURLProtocol.ResponseGate()

        let t1 = uploads.start(
            .photo {
                tracker.enter("m1")
                firstEntered.open()
                await releaseFirst.passing()
                defer { tracker.leave() }
                return gpsImage
            }, into: m1, slot: slot, in: editor)
        let t2 = uploads.start(
            .file {
                tracker.enter("m2")
                defer { tracker.leave() }
                return PreparedAttachmentFile(fileName: "two.JPG", contentType: "image/jpeg", data: gpsImage)
            }, into: m2, slot: slot, in: editor)
        let t3 = uploads.start(
            .file {
                tracker.enter("m3")
                defer { tracker.leave() }
                return PreparedAttachmentFile(
                    fileName: "notes.pdf", contentType: "application/pdf", data: Data("%PDF-1.4\n".utf8))
            }, into: m3, slot: MediaBlock.Slot(node: "pdf", url: ""), in: editor)

        XCTAssertEqual(uploads.uploadingBlocks, Set([m1, m2, m3]))
        XCTAssertTrue(uploads.isPreparing(m1))
        XCTAssertTrue(uploads.isPreparing(m2))
        XCTAssertTrue(uploads.isPreparing(m3))
        XCTAssertFalse(uploads.canUpload(m1))
        XCTAssertTrue(uploads.canUpload("m4"))

        await firstEntered.passing()
        // Wait briefly to confirm m2 and m3 stay blocked behind m1's preparation.
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(tracker.maxActive, 1)
        XCTAssertEqual(tracker.order, ["m1"])

        releaseFirst.open()
        await t1?.value
        await t2?.value
        await t3?.value

        XCTAssertNil(uploads.failure)
        XCTAssertEqual(tracker.maxActive, 1)
        XCTAssertEqual(tracker.order, ["m1", "m2", "m3"])
        XCTAssertTrue(uploads.preparing.isEmpty)

        let m1Record = try XCTUnwrap(uploads.record(m1))
        let m2Record = try XCTUnwrap(uploads.record(m2))
        let m3Record = try XCTUnwrap(uploads.record(m3))
        XCTAssertEqual(m1Record.native?.fileName, "photo.jpg")
        XCTAssertEqual(m2Record.native?.fileName, "two.jpg")
        XCTAssertEqual(m3Record.native?.fileName, "notes.pdf")
        XCTAssertNil(
            testImageProperties(of: try XCTUnwrap(app.device.attachments.data(for: m1Record.localID)))?[
                kCGImagePropertyGPSDictionary])
        XCTAssertNil(
            testImageProperties(of: try XCTUnwrap(app.device.attachments.data(for: m2Record.localID)))?[
                kCGImagePropertyGPSDictionary])

        server.gate.value?.open()
        await waitUntil { app.coordinator.nativeAttachments(scope: app.device.scope).isEmpty }
        await editor.settle()
        for id in [m1, m2, m3] {
            let block = try XCTUnwrap(editor.surface.blocks.first { $0.id == id })
            XCTAssertEqual(MediaBlock.string("url", in: block.props), Self.mediaURL)
        }
        await editor.close().value
    }
}
