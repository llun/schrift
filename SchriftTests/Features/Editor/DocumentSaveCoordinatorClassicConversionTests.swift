import XCTest

@testable import Schrift

/// Converting a page this device created but never POSTed from a classic Markdown draft to a
/// native replica, so it opens in the native editor instead of waiting for its classic draft to
/// sync. Every test pins the switch and the cached server config explicitly: both decide whether
/// anything runs at all.
@MainActor
final class DocumentSaveCoordinatorClassicConversionTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let origin = "https://docs.example.org"
    private let documentID = UUID(uuidString: "7A7A7A7A-7A7A-4A7A-8A7A-7A7A7A7A7A7A")!
    private let serverID = UUID(uuidString: "8B8B8B8B-8B8B-4B8B-8B8B-8B8B8B8B8B8B")!
    private let user = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let otherUser = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    /// The server's own storage shape: `media/<document>/attachments/<file>`, which is what the
    /// commit's `isDocumentMediaURL` gate accepts.
    private var mediaURL: String {
        let file = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.jpg"
        return "https://docs.example.org/media/\(serverID.uuidString.lowercased())/attachments/\(file)"
    }

    private var cacheDirectory: URL!
    private var attachmentDirectory: URL!
    private var replicaDirectory: URL!
    private var suiteNames: [String] = []

    override func setUp() {
        super.setUp()
        let unique = UUID().uuidString
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClassicConversion-\(unique)", isDirectory: true)
        attachmentDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClassicConversionBytes-\(unique)", isDirectory: true)
        replicaDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClassicConversionReplicas-\(unique)", isDirectory: true)
        suiteNames = []
    }

    override func tearDown() {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.removeItem(at: attachmentDirectory)
        try? FileManager.default.removeItem(at: replicaDirectory)
        for name in suiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        super.tearDown()
    }

    // MARK: - Fixture

    private struct Environment {
        let coordinator: DocumentSaveCoordinator
        let drafts: PendingDraftStore
        let attachments: PendingAttachmentStore
        let creates: PendingDocumentCreateStore
        let replicaStore: ReplicaStore
        let defaults: UserDefaults
    }

    private func makeDefaults() -> UserDefaults {
        let name = "ClassicConversion.\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    /// Seeds the record, draft and photos **before** the coordinator is built, so its init
    /// mirrors them. Routing through `createLocalDocument` would mint a replica instead of the
    /// classic draft this suite is about.
    private func seedClassicCreate(
        _ defaults: UserDefaults,
        markdown: String,
        ownerUserID: UUID? = nil,
        syncedServerID: UUID? = nil,
        pendingDelete: Bool = false
    ) {
        let creates = PendingDocumentCreateStore(userDefaults: defaults)
        creates.save(
            PendingDocumentCreate(
                localID: documentID, title: "Local", parentID: nil, createdAt: Date(),
                serverOrigin: origin, ownerUserID: ownerUserID ?? user, syncedServerID: syncedServerID))
        PendingDraftStore(userDefaults: defaults).save(
            PendingDraft(documentID: documentID, title: "Local", markdown: markdown, updatedAt: Date()))
        if pendingDelete {
            PendingDocumentDeleteStore(userDefaults: defaults).save(
                PendingDocumentDelete(
                    documentID: documentID, requestedAt: Date(), serverOrigin: origin, ownerUserID: user))
        }
    }

    /// A queued classic photo, with its bytes unless `bytes` is false.
    @discardableResult
    private func seedPhoto(
        _ defaults: UserDefaults,
        documentID: UUID? = nil,
        ownerUserID: UUID? = nil,
        serverOrigin: String? = nil,
        uploadedURLString: String? = nil,
        failedAt: Date? = nil,
        bytes: Bool = true
    ) -> (localID: UUID, placeholder: String) {
        let store = PendingAttachmentStore(userDefaults: defaults, directory: attachmentDirectory)
        let localID = UUID()
        if bytes { store.saveData(Data([0xFF, 0xD8, 0xFF]), for: localID) }
        store.save(
            PendingAttachment(
                localID: localID, documentID: documentID ?? self.documentID, createdAt: Date(),
                serverOrigin: serverOrigin ?? origin, ownerUserID: ownerUserID ?? user,
                uploadedURLString: uploadedURLString, failedAt: failedAt))
        return (localID, pendingAttachmentPlaceholderURL(for: localID))
    }

    private func cacheDocs6(_ defaults: UserDefaults) {
        ServerConfigStore(userDefaults: defaults).remember(
            ServerConfig(releaseVersion: "6.0.0"), forServerOrigin: origin)
    }

    private func makeEnvironment(
        sharing defaults: UserDefaults,
        interrupt: (@Sendable (ReplicaStore.Operation, ReplicaStore.Boundary) throws -> Void)? = nil
    ) -> Environment {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        SignedInUserStore(userDefaults: defaults).remember(user)
        let drafts = PendingDraftStore(userDefaults: defaults)
        let attachments = PendingAttachmentStore(userDefaults: defaults, directory: attachmentDirectory)
        let creates = PendingDocumentCreateStore(userDefaults: defaults)
        let replicaStore = ReplicaStore(
            directory: replicaDirectory, ownershipStore: ReplicaOwnershipStore(userDefaults: defaults),
            interrupt: interrupt)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: drafts, replicaStore: replicaStore,
            contentCache: DocumentContentCacheStore(directory: cacheDirectory), createStore: creates,
            deleteStore: PendingDocumentDeleteStore(userDefaults: defaults), attachmentStore: attachments,
            listCache: DocumentCacheStore(userDefaults: defaults),
            childrenCache: DocumentChildrenCacheStore(userDefaults: defaults), serverOrigin: origin,
            mediaCheckMaxAttempts: 1, mediaCheckRetryInterval: .milliseconds(1), backgroundTasks: .noop)
        coordinator.nativeEditorEnabled = { true }
        return Environment(
            coordinator: coordinator, drafts: drafts, attachments: attachments, creates: creates,
            replicaStore: replicaStore, defaults: defaults)
    }

    private var scope: ReplicaScope {
        ReplicaScope(serverOrigin: origin, ownerUserID: user, org: "docs", documentID: documentID)
    }

    private func projectedMarkdown(_ env: Environment, _ scope: ReplicaScope) throws -> String {
        try ReplicaSaveAdapter(store: env.replicaStore, scope: scope).prepare().markdown
    }

    private func imageBlockIDs(_ env: Environment, _ scope: ReplicaScope) throws -> [String] {
        let restored = try XCTUnwrap(try env.replicaStore.restore(for: scope))
        let doc = YDoc(clientID: 0)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(restored.checkpoint), origin: .remote)
        for update in restored.updates { try doc.applyUpdate(YUpdateDecoder.decode(update), origin: .remote) }
        return NativeBlockProjection.project(doc, nativeMarks: false, inlineObjects: true).blocks
            .filter { $0.block.node == "image" }.map(\.id)
    }

    /// The state a death after step 2 leaves: a manifest, and a draft and records still classic.
    @discardableResult
    private func seedReplica(
        _ env: Environment, markdown: String, pendingImages: [String: String]
    ) throws -> ReplicaScope {
        let checkpoint = MarkdownYjs.encode(
            markdown: markdown, serverOrigin: origin, pendingImages: pendingImages)
        _ = try env.replicaStore.create(for: scope, checkpoint: checkpoint)
        return scope
    }

    /// `keepsReplica` covers the resume path's refusal: a replica that cannot hold every photo
    /// block is left in place, so ownership stays `.owned` while the draft stays classic.
    private func assertStaysClassic(
        _ env: Environment, markdown: String, photoLocalID: UUID? = nil, keepsReplica: Bool = false
    ) {
        if !keepsReplica {
            XCTAssertEqual(env.coordinator.nativeOwnership(documentID: documentID), .none)
        }
        XCTAssertNil(env.drafts.draft(for: documentID)?.replica)
        XCTAssertEqual(env.drafts.draft(for: documentID)?.markdown, markdown)
        if let photoLocalID {
            XCTAssertNil(env.attachments.attachment(for: photoLocalID)?.native)
        }
    }

    // MARK: - Converts

    func testConvertsAClassicUnsentPageWithNoPhotos() throws {
        let defaults = makeDefaults()
        seedClassicCreate(defaults, markdown: "# Notes")
        cacheDocs6(defaults)
        let env = makeEnvironment(sharing: defaults)

        env.coordinator.convertUnsentClassicCreates()

        XCTAssertEqual(env.coordinator.nativeOwnership(documentID: documentID), .owned(scope))
        let draft = try XCTUnwrap(env.drafts.draft(for: documentID))
        let reference = try XCTUnwrap(draft.replica)
        XCTAssertEqual(reference.scope, scope)
        XCTAssertEqual(draft.markdown, try projectedMarkdown(env, scope))
        XCTAssertEqual(draft.title, "Local")
    }

    func testConvertsAClassicUnsentPageWithOneQueuedPhoto() throws {
        let defaults = makeDefaults()
        let photo = seedPhoto(defaults)
        seedClassicCreate(defaults, markdown: "![](\(photo.placeholder))")
        cacheDocs6(defaults)
        let env = makeEnvironment(sharing: defaults)

        env.coordinator.convertUnsentClassicCreates()

        XCTAssertEqual(env.coordinator.nativeOwnership(documentID: documentID), .owned(scope))
        let draft = try XCTUnwrap(env.drafts.draft(for: documentID))
        XCTAssertEqual(draft.markdown, try projectedMarkdown(env, scope))

        let blockID = photo.localID.uuidString.lowercased()
        XCTAssertEqual(try imageBlockIDs(env, scope), [blockID], "the block id derives from the localID")
        let record = try XCTUnwrap(env.attachments.attachment(for: photo.localID))
        XCTAssertEqual(
            record.native,
            NativeMediaTarget(
                org: "docs", blockID: blockID, slot: MediaBlock.Slot(node: "image", url: ""),
                fileName: "photo.jpg", contentType: "image/jpeg"))
        XCTAssertEqual(record.documentID, documentID, "the record keeps its document")
        XCTAssertEqual(env.attachments.data(for: photo.localID), Data([0xFF, 0xD8, 0xFF]), "bytes stay put")
    }

    // MARK: - Skips

    func testSkipsWhenTheSwitchIsOff() {
        let defaults = makeDefaults()
        seedClassicCreate(defaults, markdown: "# Notes")
        cacheDocs6(defaults)
        let env = makeEnvironment(sharing: defaults)
        env.coordinator.nativeEditorEnabled = { false }

        env.coordinator.convertUnsentClassicCreates()

        assertStaysClassic(env, markdown: "# Notes")
    }

    func testSkipsWithoutACachedDocs6Config() {
        let defaults = makeDefaults()
        seedClassicCreate(defaults, markdown: "# Notes")
        let env = makeEnvironment(sharing: defaults)

        env.coordinator.convertUnsentClassicCreates()

        assertStaysClassic(env, markdown: "# Notes")
    }

    func testSkipsACheckpointedRecord() {
        let defaults = makeDefaults()
        seedClassicCreate(defaults, markdown: "# Notes", syncedServerID: serverID)
        cacheDocs6(defaults)
        let env = makeEnvironment(sharing: defaults)

        env.coordinator.convertUnsentClassicCreates()

        assertStaysClassic(env, markdown: "# Notes")
    }

    func testSkipsAnotherOwnersRecord() {
        let defaults = makeDefaults()
        seedClassicCreate(defaults, markdown: "# Notes", ownerUserID: otherUser)
        cacheDocs6(defaults)
        let env = makeEnvironment(sharing: defaults)

        env.coordinator.convertUnsentClassicCreates()

        assertStaysClassic(env, markdown: "# Notes")
    }

    func testSkipsAPagePendingDelete() {
        let defaults = makeDefaults()
        seedClassicCreate(defaults, markdown: "# Notes", pendingDelete: true)
        cacheDocs6(defaults)
        let env = makeEnvironment(sharing: defaults)

        env.coordinator.convertUnsentClassicCreates()

        assertStaysClassic(env, markdown: "# Notes")
    }

    func testSkipsADuplicatePlaceholder() {
        let defaults = makeDefaults()
        let photo = seedPhoto(defaults)
        let markdown = "![](\(photo.placeholder))\n\n![](\(photo.placeholder))"
        seedClassicCreate(defaults, markdown: markdown)
        cacheDocs6(defaults)
        let env = makeEnvironment(sharing: defaults)

        env.coordinator.convertUnsentClassicCreates()

        assertStaysClassic(env, markdown: markdown, photoLocalID: photo.localID)
    }

    func testSkipsAPlaceholderOutsideAnImage() {
        let defaults = makeDefaults()
        let photo = seedPhoto(defaults)
        let markdown = "See \(photo.placeholder) here"
        seedClassicCreate(defaults, markdown: markdown)
        cacheDocs6(defaults)
        let env = makeEnvironment(sharing: defaults)

        env.coordinator.convertUnsentClassicCreates()

        assertStaysClassic(env, markdown: markdown, photoLocalID: photo.localID)
    }

    func testSkipsAPhotoWithNoBytes() {
        let defaults = makeDefaults()
        let photo = seedPhoto(defaults, bytes: false)
        let markdown = "![](\(photo.placeholder))"
        seedClassicCreate(defaults, markdown: markdown)
        cacheDocs6(defaults)
        let env = makeEnvironment(sharing: defaults)

        env.coordinator.convertUnsentClassicCreates()

        assertStaysClassic(env, markdown: markdown, photoLocalID: photo.localID)
    }

    func testSkipsAnUploadedPhoto() {
        let defaults = makeDefaults()
        let photo = seedPhoto(defaults, uploadedURLString: mediaURL)
        let markdown = "![](\(photo.placeholder))"
        seedClassicCreate(defaults, markdown: markdown)
        cacheDocs6(defaults)
        let env = makeEnvironment(sharing: defaults)

        env.coordinator.convertUnsentClassicCreates()

        assertStaysClassic(env, markdown: markdown, photoLocalID: photo.localID)
    }

    func testSkipsAFailedPhoto() {
        let defaults = makeDefaults()
        let photo = seedPhoto(defaults, failedAt: Date())
        let markdown = "![](\(photo.placeholder))"
        seedClassicCreate(defaults, markdown: markdown)
        cacheDocs6(defaults)
        let env = makeEnvironment(sharing: defaults)

        env.coordinator.convertUnsentClassicCreates()

        assertStaysClassic(env, markdown: markdown, photoLocalID: photo.localID)
    }

    func testSkipsAPhotoBelongingToAnotherDocument() {
        let defaults = makeDefaults()
        let photo = seedPhoto(defaults, documentID: UUID())
        let markdown = "![](\(photo.placeholder))"
        seedClassicCreate(defaults, markdown: markdown)
        cacheDocs6(defaults)
        let env = makeEnvironment(sharing: defaults)

        env.coordinator.convertUnsentClassicCreates()

        assertStaysClassic(env, markdown: markdown, photoLocalID: photo.localID)
    }

    func testSkipsAPhotoBelongingToAnotherOwner() {
        let defaults = makeDefaults()
        let photo = seedPhoto(defaults, ownerUserID: otherUser)
        let markdown = "![](\(photo.placeholder))"
        seedClassicCreate(defaults, markdown: markdown)
        cacheDocs6(defaults)
        let env = makeEnvironment(sharing: defaults)

        env.coordinator.convertUnsentClassicCreates()

        assertStaysClassic(env, markdown: markdown, photoLocalID: photo.localID)
    }

    func testSkipsAPhotoFromAnotherServer() {
        let defaults = makeDefaults()
        let photo = seedPhoto(defaults, serverOrigin: "https://other.example.org")
        let markdown = "![](\(photo.placeholder))"
        seedClassicCreate(defaults, markdown: markdown)
        cacheDocs6(defaults)
        let env = makeEnvironment(sharing: defaults)

        env.coordinator.convertUnsentClassicCreates()

        assertStaysClassic(env, markdown: markdown, photoLocalID: photo.localID)
    }

    /// `MarkdownYjs` spells an `.unknown` block as plain paragraphs, which loses its structure —
    /// a table would come back as prose. Such a page stays classic.
    func testSkipsAPageWithAnUnknownBlock() {
        let defaults = makeDefaults()
        let markdown = "| a | b |\n| - | - |"
        seedClassicCreate(defaults, markdown: markdown)
        cacheDocs6(defaults)
        let env = makeEnvironment(sharing: defaults)

        env.coordinator.convertUnsentClassicCreates()

        assertStaysClassic(env, markdown: markdown)
    }

    /// A classic editor on screen still holds the classic draft in memory, so converting under it
    /// would make its next flush a refused classic save.
    func testSkipsAPageWhoseEditorIsOpen() {
        let defaults = makeDefaults()
        seedClassicCreate(defaults, markdown: "# Notes")
        cacheDocs6(defaults)
        let env = makeEnvironment(sharing: defaults)
        env.coordinator.retainOpenEditor(documentID: documentID)
        XCTAssertTrue(env.coordinator.hasOpenEditorForTesting(documentID: documentID))

        env.coordinator.convertUnsentClassicCreates()

        assertStaysClassic(env, markdown: "# Notes")
    }

    /// The parser accepts either case for the placeholder scheme, so the occurrence count must
    /// too — a case-sensitive one would read this page as having no placeholder at all.
    func testAnUppercasePlaceholderConverts() throws {
        let defaults = makeDefaults()
        let photo = seedPhoto(defaults)
        let markdown = "![](SCHRIFT-ATTACHMENT://\(photo.localID.uuidString.lowercased()))"
        seedClassicCreate(defaults, markdown: markdown)
        cacheDocs6(defaults)
        let env = makeEnvironment(sharing: defaults)

        env.coordinator.convertUnsentClassicCreates()

        XCTAssertEqual(env.coordinator.nativeOwnership(documentID: documentID), .owned(scope))
        let blockID = photo.localID.uuidString.lowercased()
        XCTAssertEqual(try imageBlockIDs(env, scope), [blockID])
        XCTAssertEqual(env.attachments.attachment(for: photo.localID)?.native?.blockID, blockID)
    }

    // MARK: - Idempotence

    func testRunningTwiceChangesNothingTheSecondTime() throws {
        let defaults = makeDefaults()
        let photo = seedPhoto(defaults)
        seedClassicCreate(defaults, markdown: "![](\(photo.placeholder))")
        cacheDocs6(defaults)
        let env = makeEnvironment(sharing: defaults)

        env.coordinator.convertUnsentClassicCreates()
        let firstDraft = try XCTUnwrap(env.drafts.draft(for: documentID))
        let firstManifest = try XCTUnwrap(try env.replicaStore.manifest(for: scope))
        let firstRecord = try XCTUnwrap(env.attachments.attachment(for: photo.localID))

        env.coordinator.convertUnsentClassicCreates()

        XCTAssertEqual(env.drafts.draft(for: documentID), firstDraft)
        XCTAssertEqual(try env.replicaStore.manifest(for: scope), firstManifest)
        XCTAssertEqual(env.attachments.attachment(for: photo.localID), firstRecord)
    }

    // MARK: - Resume

    func testResumeAfterTheReplicaWasCreatedFinishesFromIt() throws {
        let defaults = makeDefaults()
        let photo = seedPhoto(defaults)
        let markdown = "![](\(photo.placeholder))"
        seedClassicCreate(defaults, markdown: markdown)
        cacheDocs6(defaults)
        let env = makeEnvironment(sharing: defaults)
        let blockID = photo.localID.uuidString.lowercased()
        try seedReplica(env, markdown: markdown, pendingImages: [photo.placeholder: blockID])
        let seeded = try XCTUnwrap(try env.replicaStore.manifest(for: scope))

        env.coordinator.convertUnsentClassicCreates()

        let draft = try XCTUnwrap(env.drafts.draft(for: documentID))
        XCTAssertEqual(draft.replica?.scope, scope, "the draft takes the replica reference")
        XCTAssertEqual(draft.markdown, try projectedMarkdown(env, scope))
        XCTAssertEqual(try env.replicaStore.manifest(for: scope), seeded, "the replica is never re-encoded")
        XCTAssertEqual(env.attachments.attachment(for: photo.localID)?.native?.blockID, blockID)
    }

    func testResumeAfterTheRecordsWereReKeyedFinishesFromTheReplica() throws {
        let defaults = makeDefaults()
        let photo = seedPhoto(defaults)
        let markdown = "![](\(photo.placeholder))"
        seedClassicCreate(defaults, markdown: markdown)
        cacheDocs6(defaults)
        let env = makeEnvironment(sharing: defaults)
        let blockID = photo.localID.uuidString.lowercased()
        try seedReplica(env, markdown: markdown, pendingImages: [photo.placeholder: blockID])
        // Step 3 already ran: the record is native, the draft is still classic.
        let store = PendingAttachmentStore(userDefaults: defaults, directory: attachmentDirectory)
        store.save(
            PendingAttachment(
                localID: photo.localID, documentID: documentID, createdAt: Date(), serverOrigin: origin,
                ownerUserID: user,
                native: NativeMediaTarget(
                    org: "docs", blockID: blockID, slot: MediaBlock.Slot(node: "image", url: ""),
                    fileName: "photo.jpg", contentType: "image/jpeg")))
        let relaunched = makeEnvironment(sharing: defaults)

        relaunched.coordinator.convertUnsentClassicCreates()

        let draft = try XCTUnwrap(relaunched.drafts.draft(for: documentID))
        XCTAssertEqual(draft.replica?.scope, scope, "the draft takes the replica reference")
        XCTAssertEqual(draft.markdown, try projectedMarkdown(relaunched, scope))
        XCTAssertEqual(relaunched.attachments.attachment(for: photo.localID)?.native?.blockID, blockID)
        XCTAssertEqual(relaunched.attachments.data(for: photo.localID), Data([0xFF, 0xD8, 0xFF]))
    }

    func testAReplicaMissingAnExpectedPhotoBlockLeavesEverythingAsItWas() throws {
        let defaults = makeDefaults()
        let photo = seedPhoto(defaults)
        let markdown = "![](\(photo.placeholder))"
        seedClassicCreate(defaults, markdown: markdown)
        cacheDocs6(defaults)
        let env = makeEnvironment(sharing: defaults)
        // A replica whose image block kept a fresh id: the resume cannot find the photo's block.
        try seedReplica(env, markdown: markdown, pendingImages: [:])
        let seeded = try XCTUnwrap(try env.replicaStore.manifest(for: scope))

        env.coordinator.convertUnsentClassicCreates()

        assertStaysClassic(env, markdown: markdown, photoLocalID: photo.localID, keepsReplica: true)
        XCTAssertEqual(try env.replicaStore.manifest(for: scope), seeded, "the replica is kept, not deleted")
        XCTAssertNotNil(try env.replicaStore.restore(for: scope))
    }

    // MARK: - Crash order

    /// A death between re-keying the records and creating the replica leaves native records on a
    /// classic page with no replica. If the next pass migrates it classically (here: the switch
    /// is off), the records must go back to classic so the photo uploads through the classic
    /// replay; left native, their commit finds no replica, answers `.gone` and deletes the bytes.
    func testANativeRecordOnAClassicallyMigratedPageUploadsAsClassic() async throws {
        let log = RequestRecorder()
        let defaults = makeDefaults()
        let photo = seedPhoto(defaults)
        let markdown = "![](\(photo.placeholder))"
        seedClassicCreate(defaults, markdown: markdown)
        cacheDocs6(defaults)
        let blockID = photo.localID.uuidString.lowercased()
        let store = PendingAttachmentStore(userDefaults: defaults, directory: attachmentDirectory)
        let classic = try XCTUnwrap(store.attachment(for: photo.localID))
        store.save(
            PendingAttachment(
                localID: classic.localID, documentID: classic.documentID, createdAt: classic.createdAt,
                serverOrigin: classic.serverOrigin, ownerUserID: classic.ownerUserID,
                native: NativeMediaTarget(
                    org: "docs", blockID: blockID, slot: MediaBlock.Slot(node: "image", url: ""),
                    fileName: "photo.jpg", contentType: "image/jpeg")))
        let env = makeEnvironment(sharing: defaults)
        env.coordinator.nativeEditorEnabled = { false }
        stubPipeline(log: log, bodies: BodyRecorder())

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(
            log.count(
                ofMethod: "POST", urlContaining: "/documents/\(serverID.uuidString.lowercased())/attachment-upload/"),
            1, "the photo uploads through the classic replay instead of being dropped")
        if let record = env.attachments.attachment(for: photo.localID) {
            XCTAssertNil(record.native, "a record left behind is classic")
            XCTAssertNotNil(env.attachments.data(for: photo.localID), "and keeps its bytes")
        }
    }

    /// A replica create that fails leaves the page classic, so its records go back to classic
    /// with their bytes, and a later pass converts the page from scratch.
    func testAFailedReplicaCreateLeavesThePageAndItsPhotosClassic() throws {
        let defaults = makeDefaults()
        let photo = seedPhoto(defaults)
        let markdown = "![](\(photo.placeholder))"
        seedClassicCreate(defaults, markdown: markdown)
        cacheDocs6(defaults)
        let blockID = photo.localID.uuidString.lowercased()
        let interrupted = makeEnvironment(sharing: defaults) { operation, boundary in
            if operation == .create, boundary == .payloadWritten { throw ReplicaStoreError.corrupt }
        }

        interrupted.coordinator.convertUnsentClassicCreates()

        XCTAssertNil(try interrupted.replicaStore.manifest(for: scope), "the create died before its manifest")
        XCTAssertNil(interrupted.attachments.attachment(for: photo.localID)?.native, "the record is classic again")
        XCTAssertNil(interrupted.drafts.draft(for: documentID)?.replica, "the draft is still classic")
        XCTAssertEqual(interrupted.attachments.data(for: photo.localID), Data([0xFF, 0xD8, 0xFF]))

        let relaunched = makeEnvironment(sharing: defaults)
        relaunched.coordinator.convertUnsentClassicCreates()

        XCTAssertEqual(relaunched.coordinator.nativeOwnership(documentID: documentID), .owned(scope))
        XCTAssertEqual(try imageBlockIDs(relaunched, scope), [blockID])
        XCTAssertEqual(relaunched.attachments.attachment(for: photo.localID)?.native?.blockID, blockID)
        XCTAssertEqual(relaunched.drafts.draft(for: documentID)?.replica?.scope, scope)
    }

    // MARK: - Server adoption

    /// A converted page whose only content is a queued photo projects to empty Markdown. A create
    /// resume that finds content on the server must not adopt it: that would discard the replica
    /// holding the photo block.
    func testAPhotoOnlyPageKeepsItsReplicaWhenTheServerHasContent() async throws {
        let log = RequestRecorder()
        let defaults = makeDefaults()
        let photo = seedPhoto(defaults)
        seedClassicCreate(defaults, markdown: "![](\(photo.placeholder))")
        cacheDocs6(defaults)
        let env = makeEnvironment(sharing: defaults)
        env.coordinator.convertUnsentClassicCreates()
        XCTAssertEqual(env.coordinator.nativeOwnership(documentID: documentID), .owned(scope))
        var record = try XCTUnwrap(env.creates.create(for: documentID))
        record.syncedServerID = serverID
        env.creates.save(record)
        let blockID = photo.localID.uuidString.lowercased()

        stubServerWithContent(log: log)
        let relaunched = makeEnvironment(sharing: defaults)
        await relaunched.coordinator.syncPendingDrafts()

        let serverScope = ReplicaScope(
            serverOrigin: origin, ownerUserID: user, org: "docs", documentID: serverID)
        XCTAssertEqual(
            try imageBlockIDs(relaunched, serverScope), [blockID],
            "the photo block survives under the server scope")
        XCTAssertEqual(relaunched.attachments.attachment(for: photo.localID)?.documentID, serverID)
        XCTAssertEqual(relaunched.attachments.data(for: photo.localID), Data([0xFF, 0xD8, 0xFF]))
    }

    // MARK: - Replay end to end

    /// A converted page POSTs, is re-keyed, uploads its photo under the server id and commits the
    /// URL into the block — and no save ever carries the placeholder.
    func testAConvertedPageWithAPhotoPostsReKeysAndCommitsTheURL() async throws {
        let log = RequestRecorder()
        let bodies = BodyRecorder()
        let defaults = makeDefaults()
        let photo = seedPhoto(defaults)
        seedClassicCreate(defaults, markdown: "![](\(photo.placeholder))")
        cacheDocs6(defaults)
        let env = makeEnvironment(sharing: defaults)
        let registry = NativeSessionRegistry()
        env.coordinator.nativeSessions = registry
        env.coordinator.nativeCommitAttempts = 5
        env.coordinator.nativeCommitInterval = .milliseconds(10)
        addTeardownBlock { await registry.closeAll().value }
        stubPipeline(log: log, bodies: bodies)

        await env.coordinator.syncPendingDrafts()

        let serverScope = ReplicaScope(
            serverOrigin: origin, ownerUserID: user, org: "docs", documentID: serverID)
        await waitUntil {
            env.creates.create(for: self.documentID) == nil
                && env.attachments.attachment(for: photo.localID) == nil
                && (try? self.committedURL(env, serverScope)) == self.mediaURL
                && bodies.joined.contains(self.mediaURL)
        }

        XCTAssertNil(env.creates.create(for: documentID), "the create record is re-keyed away")
        XCTAssertNil(env.attachments.attachment(for: photo.localID), "the record is collected after the commit")
        XCTAssertEqual(try committedURL(env, serverScope), mediaURL)
        XCTAssertEqual(
            log.count(
                ofMethod: "POST", urlContaining: "/documents/\(serverID.uuidString.lowercased())/attachment-upload/"),
            1, "the upload must address the server id")
        XCTAssertEqual(
            log.count(ofMethod: "POST", urlContaining: documentID.uuidString.lowercased()), 0,
            "the local id must never reach the server")
        XCTAssertGreaterThan(bodies.count, 0, "at least one save body must have been decoded")
        XCTAssertTrue(bodies.joined.contains(mediaURL), "the decoded save carries the committed URL")
        XCTAssertFalse(bodies.joined.contains("schrift-attachment"), "no save may carry the placeholder")
    }

    private func committedURL(_ env: Environment, _ scope: ReplicaScope) throws -> String? {
        let restored = try XCTUnwrap(try env.replicaStore.restore(for: scope))
        let doc = YDoc(clientID: 0)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(restored.checkpoint), origin: .remote)
        for update in restored.updates { try doc.applyUpdate(YUpdateDecoder.decode(update), origin: .remote) }
        let image = NativeBlockProjection.project(doc, nativeMarks: false, inlineObjects: true).blocks
            .first { $0.block.node == "image" }
        return image.map { MediaBlock.string("url", in: $0.block.props) }
    }

    /// A server that already holds content under the checkpointed id — what a co-author's write
    /// looks like to a create resume.
    private func stubServerWithContent(log: RequestRecorder) {
        let serverLower = serverID.uuidString.lowercased()
        let userLower = user.uuidString.lowercased()
        let body = Data(
            """
            {"id":"\(serverLower)","title":"Renamed on web","content":"# Written on the web",
             "abilities":{"update":true},"link_reach":"restricted","link_role":"reader","depth":1,
             "numchild":0,"path":"0001",
             "created_at":"2026-03-01T12:00:00Z","updated_at":"2026-03-02T12:00:00Z"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("users/me/") {
                return .init(
                    statusCode: 200, headers: [:], body: Data("{\"id\": \"\(userLower)\"}".utf8), error: nil)
            }
            if request.httpMethod == "PATCH" {
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: body, error: nil)
        }
    }

    private func stubPipeline(log: RequestRecorder, bodies: BodyRecorder) {
        let serverLower = serverID.uuidString.lowercased()
        let userLower = user.uuidString.lowercased()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            bodies.record(request)
            let url = request.url?.absoluteString ?? ""
            let method = request.httpMethod ?? "GET"
            if url.hasSuffix("users/me/") {
                return .init(
                    statusCode: 200, headers: [:], body: Data("{\"id\": \"\(userLower)\"}".utf8), error: nil)
            }
            if url.hasSuffix("/config/") {
                return .init(
                    statusCode: 200, headers: [:], body: Data(#"{"RELEASE_VERSION":"6.0.0"}"#.utf8), error: nil)
            }
            if method == "POST", url.hasSuffix("/documents/") {
                return .init(
                    statusCode: 201, headers: [:],
                    body: Data(
                        """
                        {"id":"\(serverLower)","title":"Local","abilities":{"update":true},
                         "link_reach":"restricted","link_role":"reader","depth":1,"numchild":0,"path":"0001",
                         "created_at":"2026-03-01T12:00:00Z","updated_at":"2026-03-01T12:00:00Z"}
                        """.utf8), error: nil)
            }
            if method == "POST", url.contains("/documents/\(serverLower)/attachment-upload/") {
                return .init(
                    statusCode: 201, headers: [:],
                    body: Data(#"{"file":"/api/v1.0/documents/x/media-check/?key=k.jpg"}"#.utf8), error: nil)
            }
            if method == "GET", url.contains("media-check") {
                let file = "/media/\(serverLower)/attachments/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.jpg"
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data("{\"status\":\"ready\",\"file\":\"\(file)\"}".utf8), error: nil)
            }
            if method == "PATCH", url.contains("/collaboration/ydoc/") {
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
            }
            if method == "GET", url.contains("formatted-content") {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data(
                        """
                        {"id":"\(serverLower)","title":"Local","content":"",
                         "created_at":"2026-03-01T12:00:00Z","updated_at":"2026-03-01T12:00:00Z"}
                        """.utf8), error: nil)
            }
            if method == "GET", url.contains("/documents/\(serverLower)/") {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data(
                        """
                        {"id":"\(serverLower)","title":"Local","abilities":{"update":true},
                         "link_reach":"restricted","link_role":"reader","depth":1,"numchild":0,"path":"0001",
                         "created_at":"2026-03-01T12:00:00Z","updated_at":"2026-03-01T12:00:00Z"}
                        """.utf8), error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: Data("{}".utf8), error: nil)
        }
    }
}

/// Every save body's Yjs bytes, decoded — a save carries them base64 in `update` (collaboration
/// route) or `content` (legacy), so a placeholder that reached one would appear here.
private final class BodyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var decoded: [String] = []

    func record(_ request: URLRequest) {
        guard let data = bodyData(from: request),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let encoded = (json["update"] ?? json["content"]) as? String,
            let bytes = Data(base64Encoded: encoded)
        else { return }
        lock.lock()
        defer { lock.unlock() }
        decoded.append(String(decoding: bytes, as: UTF8.self))
    }

    var joined: String {
        lock.lock()
        defer { lock.unlock() }
        return decoded.joined()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return decoded.count
    }
}
