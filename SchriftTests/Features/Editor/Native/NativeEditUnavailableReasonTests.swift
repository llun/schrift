import XCTest

@testable import Schrift

/// Tests for `NativeEditUnavailableReason` copy, icon mapping, projection refusal diagnostics,
/// `NativeEditorOpen.resolveUnavailableReason`, and `NativeEditorOpen.editUnavailableReason`.
@MainActor
final class NativeEditUnavailableReasonTests: DocumentEngineTestCase {
    private let owner = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    // MARK: - Icons and Localized Notes

    func testAllReasonCasesExposeExpectedIconAndLocalizedNote() {
        let (loc, cleanup) = makeLocalizationStore()
        defer { cleanup() }

        let cases: [(reason: NativeEditUnavailableReason, icon: MaterialIcon, expectedNote: String)] = [
            (
                .unfamiliarContent(blockNode: "callout", reason: "nested blocks"),
                .info,
                "Read-only: this document has a block the native editor can't edit yet (Callout with nested blocks)"
            ),
            (
                .unfamiliarContent(blockNode: "", reason: "unsupported root"),
                .info,
                "Read-only: this document has a block the native editor can't edit yet (Unsupported document root)"
            ),
            (
                .unfamiliarContent(blockNode: "diagram", reason: "diagram: unsupported"),
                .info,
                "Read-only: this document has a block the native editor can't edit yet (Diagram: unsupported)"
            ),
            (
                .unfamiliarContent(blockNode: "exoticWidget", reason: "exoticWidget"),
                .info,
                "Read-only: this document has a block the native editor can't edit yet (exoticWidget)"
            ),
            (.noEditAccess, .lock, loc[.native_editor_read_only_no_access]),
            (.nativeSwitchOff, .lock, loc[.native_editor_owned_read_only_body]),
            (.pendingSync, .sync, loc[.native_editor_read_only_pending_sync]),
            (.pendingDelete, .delete, loc[.editor_pending_delete]),
            (.classicDraft, .sync, loc[.native_editor_read_only_classic_draft]),
            (.liveHeld, .sync, loc[.native_editor_read_only_live_held]),
            (.signedOut, .lock, loc[.native_editor_read_only_signed_out]),
            (.preservedUnavailable, .warning, loc[.native_editor_owned_unavailable_body]),
            (.offlineLimitedRead, .wifi_off, loc[.editor_offline_read_only_native]),
        ]

        for entry in cases {
            XCTAssertEqual(entry.reason.icon, entry.icon, "icon mismatch for \(entry.reason)")
            let note = entry.reason.localizedNote(using: loc)
            XCTAssertFalse(note.isEmpty, "empty note for \(entry.reason)")
            XCTAssertEqual(note, entry.expectedNote, "note mismatch for \(entry.reason)")
        }
    }

    // MARK: - Projection Refusal & No Text Leak

    func testCalloutWithNestedBlocksProducesUnfamiliarReasonWithoutLeakingText() async throws {
        let (loc, cleanup) = makeLocalizationStore()
        defer { cleanup() }

        let secretParent = "CONFIDENTIAL_CALLOUT_TEXT"
        let secretChild = "CONFIDENTIAL_CHILD_TEXT"
        let callout = BlockNoteBlock(
            node: "callout",
            props: [
                ("backgroundColor", .string("default")),
                ("emoji", .string("💡")),
                ("textAlignment", .string("left")),
            ],
            runs: [InlineRun(secretParent)],
            id: "callout-1",
            children: [
                BlockNoteBlock(
                    node: "paragraph", props: Self.paragraphProps, runs: [InlineRun(secretChild)], id: "child-1")
            ])
        let state = BlockNoteYjs.encode([callout], clientID: Self.seedClientID)
        let doc = YDoc(clientID: 1, gc: true)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(state), origin: .remote)

        let unsupported = NativeBlockProjection.firstUnsupportedReason(doc)
        XCTAssertEqual(unsupported, NativeUnfamiliarBlock(node: "callout", reason: "nested blocks"))

        let session = try await NativeEditorSession.inspect(state: state)
        defer { session.close() }
        XCTAssertFalse(session.canType)
        XCTAssertEqual(session.unfamiliarContent, NativeUnfamiliarBlock(node: "callout", reason: "nested blocks"))

        let reason = NativeEditUnavailableReason.unfamiliarContent(
            blockNode: session.unfamiliarContent?.node ?? "",
            reason: session.unfamiliarContent?.reason ?? "")
        let note = reason.localizedNote(using: loc)
        XCTAssertEqual(
            note,
            "Read-only: this document has a block the native editor can't edit yet (Callout with nested blocks)")
        XCTAssertFalse(note.contains(secretParent))
        XCTAssertFalse(note.contains(secretChild))
    }

    func testOpaqueBlockAndUnsupportedRootNeverLeakDocumentText() async throws {
        let (loc, cleanup) = makeLocalizationStore()
        defer { cleanup() }

        let secretOpaque = "SECRET_WIDGET_BODY"
        let exotic = BlockNoteBlock(
            node: "exoticWidget", props: [], runs: [InlineRun(secretOpaque)], id: "exotic-1")
        let exoticState = BlockNoteYjs.encode([exotic], clientID: Self.seedClientID)
        let exoticSession = try await NativeEditorSession.inspect(state: exoticState)
        defer { exoticSession.close() }
        XCTAssertFalse(exoticSession.canType)
        XCTAssertEqual(exoticSession.unfamiliarContent?.node, "exoticWidget")

        let exoticReason = try XCTUnwrap(
            NativeEditorOpen.resolveUnavailableReason(
                enabled: true, hasEditAccess: true, hasAccount: true, isPendingDelete: false,
                hasCheckpointedCreate: false, isLiveHeld: false, hasClassicDraft: false, session: exoticSession))
        let exoticNote = exoticReason.localizedNote(using: loc)
        XCTAssertFalse(exoticNote.contains(secretOpaque))

        let badRootDoc = YDoc(clientID: 2)
        defer { badRootDoc.destroy() }
        let root = badRootDoc.get(BlockNoteYjs.fragmentField)
        try badRootDoc.transact { tx in
            _ = try YWrite.insertAfter(
                tx, into: root, after: nil, [.type(YType(typeRef: .xmlElement(nodeName: "unknown")))])
        }
        let badRootState = try YStateEncoder.encodeStateAsUpdate(badRootDoc)
        let badRootSession = try await NativeEditorSession.inspect(state: badRootState)
        defer { badRootSession.close() }
        XCTAssertTrue(badRootSession.hasUnsupportedRoot)
        XCTAssertFalse(badRootSession.canType)

        let badRootReason = NativeEditorOpen.resolveUnavailableReason(
            enabled: true, hasEditAccess: true, hasAccount: true, isPendingDelete: false,
            hasCheckpointedCreate: false, isLiveHeld: false, hasClassicDraft: false, session: badRootSession)
        XCTAssertEqual(badRootReason, .unfamiliarContent(blockNode: "", reason: "unsupported root"))
    }

    // MARK: - Resolution Precedence

    func testResolveUnavailableReasonPrecedenceAcrossGates() async throws {
        let typeableState = BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID)
        let typeableSession = try await NativeEditorSession.inspect(state: typeableState)
        defer { typeableSession.close() }
        XCTAssertTrue(typeableSession.canType)

        XCTAssertNil(
            NativeEditorOpen.resolveUnavailableReason(
                enabled: true, hasEditAccess: true, hasAccount: true, isPendingDelete: false,
                hasCheckpointedCreate: false, isLiveHeld: false, hasClassicDraft: false, session: typeableSession))

        XCTAssertEqual(
            NativeEditorOpen.resolveUnavailableReason(
                enabled: false, hasEditAccess: false, hasAccount: false, isPendingDelete: true,
                hasCheckpointedCreate: true, isLiveHeld: true, hasClassicDraft: true, session: typeableSession),
            .noEditAccess)

        XCTAssertEqual(
            NativeEditorOpen.resolveUnavailableReason(
                enabled: false, hasEditAccess: true, hasAccount: false, isPendingDelete: true,
                hasCheckpointedCreate: true, isLiveHeld: true, hasClassicDraft: true, session: typeableSession),
            .nativeSwitchOff)

        XCTAssertEqual(
            NativeEditorOpen.resolveUnavailableReason(
                enabled: true, hasEditAccess: true, hasAccount: false, isPendingDelete: true,
                hasCheckpointedCreate: true, isLiveHeld: true, hasClassicDraft: true, session: typeableSession),
            .pendingDelete)

        XCTAssertEqual(
            NativeEditorOpen.resolveUnavailableReason(
                enabled: true, hasEditAccess: true, hasAccount: false, isPendingDelete: false,
                hasCheckpointedCreate: true, isLiveHeld: true, hasClassicDraft: true, session: typeableSession),
            .pendingSync)

        XCTAssertEqual(
            NativeEditorOpen.resolveUnavailableReason(
                enabled: true, hasEditAccess: true, hasAccount: false, isPendingDelete: false,
                hasCheckpointedCreate: false, isLiveHeld: true, hasClassicDraft: true, session: typeableSession),
            .liveHeld)

        XCTAssertEqual(
            NativeEditorOpen.resolveUnavailableReason(
                enabled: true, hasEditAccess: true, hasAccount: false, isPendingDelete: false,
                hasCheckpointedCreate: false, isLiveHeld: false, hasClassicDraft: true, session: typeableSession),
            .classicDraft)

        XCTAssertEqual(
            NativeEditorOpen.resolveUnavailableReason(
                enabled: true, hasEditAccess: true, hasAccount: false, isPendingDelete: false,
                hasCheckpointedCreate: false, isLiveHeld: false, hasClassicDraft: false, session: typeableSession),
            .signedOut)
    }

    // MARK: - Open Route Integration

    func testOpenPopulatesEditUnavailableReasonOnReadOnlyRoutesAndClearsOnWritableRoute() async throws {
        // 1. Reader (no edit access)
        do {
            let env = makeEnvironment()
            defer { env.clean() }
            stubServer(state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID), canUpdate: false)
            let open = NativeEditorOpen(preference: { true })
            defer { open.close() }
            await open.open(viewModel: env.model, isOffline: false, canUpdate: false)
            guard case .native(let session) = open.route else { return XCTFail("expected .native reader") }
            XCTAssertNil(session.input)
            XCTAssertEqual(open.editUnavailableReason, .noEditAccess)
        }

        // 2. Unfamiliar block (callout with nested block)
        do {
            let env = makeEnvironment()
            defer { env.clean() }
            let callout = BlockNoteBlock(
                node: "callout",
                props: [("backgroundColor", .string("default")), ("emoji", .string("💡"))],
                runs: [InlineRun("Body")],
                id: "c1",
                children: [
                    BlockNoteBlock(
                        node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("Child")], id: "p1")
                ])
            stubServer(state: BlockNoteYjs.encode([callout], clientID: Self.seedClientID), canUpdate: true)
            let open = NativeEditorOpen(preference: { true })
            defer { open.close() }
            await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
            guard case .native(let session) = open.route else { return XCTFail("expected .native reader") }
            XCTAssertNil(session.input)
            XCTAssertEqual(
                open.editUnavailableReason, .unfamiliarContent(blockNode: "callout", reason: "nested blocks"))
        }

        // 3. Owned replica with switch off -> .nativeSwitchOff
        do {
            let env = makeEnvironment()
            defer { env.clean() }
            try seedReplica(env)
            let open = NativeEditorOpen(preference: { false })
            defer { open.close() }
            await open.open(viewModel: env.model, isOffline: true, canUpdate: true)
            guard case .native(let session) = open.route else { return XCTFail("expected owned .native route") }
            XCTAssertNil(session.input)
            XCTAssertTrue(open.isPreservedReadOnly)
            XCTAssertEqual(open.editUnavailableReason, .nativeSwitchOff)
        }

        // 4. Owned replica held by live owner -> .liveHeld
        do {
            let env = makeEnvironment(isLiveHeld: { _ in true })
            defer { env.clean() }
            try seedReplica(env)
            let open = NativeEditorOpen(preference: { true })
            defer { open.close() }
            await open.open(viewModel: env.model, isOffline: true, canUpdate: true)
            guard case .native(let session) = open.route else { return XCTFail("expected owned .native route") }
            XCTAssertNil(session.input)
            XCTAssertEqual(open.editUnavailableReason, .liveHeld)
        }

        // 5. Ownership marker without readable replica (switch off) -> .preservedUnavailable
        do {
            let env = makeEnvironment()
            defer { env.clean() }
            let scope = ReplicaScope(
                serverOrigin: env.model.client.serverOrigin, ownerUserID: owner, org: "docs",
                documentID: env.documentID)
            try env.replicaStore.create(
                for: scope, checkpoint: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID))
            let manifestURL = env.directory
                .appendingPathComponent("ReplicaDrafts")
                .appendingPathComponent(try scope.directoryName())
                .appendingPathComponent("manifest.json")
            try FileManager.default.removeItem(at: manifestURL)
            let open = NativeEditorOpen(preference: { false })
            defer { open.close() }
            await open.open(viewModel: env.model, isOffline: true, canUpdate: true)
            guard case .preservedUnavailable = open.route else {
                return XCTFail("expected .preservedUnavailable route")
            }
            XCTAssertEqual(open.editUnavailableReason, .preservedUnavailable)
        }

        // 6. Typeable document clears editUnavailableReason
        do {
            let env = makeEnvironment()
            defer { env.clean() }
            stubServer(state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID), canUpdate: true)
            let open = NativeEditorOpen(preference: { true })
            defer { open.close() }
            await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
            guard case .native(let session) = open.route else { return XCTFail("expected .native editor") }
            XCTAssertNotNil(session.input)
            XCTAssertNil(open.editUnavailableReason)
        }
    }

    // MARK: - Helpers

    private func makeLocalizationStore() -> (LocalizationStore, () -> Void) {
        let suite = "NativeEditUnavailableReasonTests.Loc.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let store = LocalizationStore(userDefaults: defaults)
        store.language = .english
        return (store, { defaults.removePersistentDomain(forName: suite) })
    }

    private struct Environment {
        let model: EditorViewModel
        let defaults: UserDefaults
        let suite: String
        let directory: URL
        let replicaStore: ReplicaStore
        let documentID: UUID
        func clean() {
            MockURLProtocol.reset()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeEnvironment(isLiveHeld: @escaping @MainActor (UUID) -> Bool = { _ in false }) -> Environment {
        MockURLProtocol.reset()
        let suite = "NativeEditUnavailableReasonTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let documentID = UUID()
        SignedInUserStore(userDefaults: defaults).remember(owner)
        let client = DocsAPIClient(
            baseURL: URL(string: "https://docs.example.org/api/v1.0/")!, session: MockURLProtocol.makeSession(),
            cookieProvider: { [] })
        let content = DocumentContentCacheStore(directory: directory)
        let children = DocumentChildrenCacheStore(userDefaults: defaults)
        let replicaStore = ReplicaStore(
            directory: directory.appendingPathComponent("ReplicaDrafts"),
            ownershipStore: ReplicaOwnershipStore(userDefaults: defaults))
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: PendingDraftStore(userDefaults: defaults), replicaStore: replicaStore,
            contentCache: content, createStore: PendingDocumentCreateStore(userDefaults: defaults),
            deleteStore: PendingDocumentDeleteStore(userDefaults: defaults),
            attachmentStore: PendingAttachmentStore(
                userDefaults: defaults, directory: directory.appendingPathComponent("attachments")),
            listCache: DocumentCacheStore(userDefaults: defaults), childrenCache: children,
            backgroundTasks: .noop, isLiveReplicaHeld: isLiveHeld)
        let model = EditorViewModel(
            client: client, documentID: documentID, title: "Title", saveCoordinator: coordinator,
            signedInUser: SignedInUserStore(userDefaults: defaults), contentCache: content, childrenCache: children,
            listCache: DocumentCacheStore(userDefaults: defaults),
            availability: OnlineAvailability(userDefaults: defaults))
        return Environment(
            model: model, defaults: defaults, suite: suite, directory: directory,
            replicaStore: replicaStore, documentID: documentID)
    }

    private func seedReplica(_ env: Environment) throws {
        let scope = ReplicaScope(
            serverOrigin: env.model.client.serverOrigin, ownerUserID: owner, org: "docs",
            documentID: env.documentID)
        _ = try env.replicaStore.create(
            for: scope, checkpoint: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID))
    }

    private func stubServer(state: Data, canUpdate: Bool) {
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            let json = ["Content-Type": "application/json"]
            if url.hasSuffix("/config/") {
                return .init(
                    statusCode: 200, headers: json, body: Data(#"{"RELEASE_VERSION":"6.0.0"}"#.utf8), error: nil)
            }
            if url.contains("/collaboration/ydoc/") {
                let body = try! JSONSerialization.data(withJSONObject: ["doc": state.base64EncodedString()])
                return .init(statusCode: 200, headers: json, body: body, error: nil)
            }
            if url.contains("formatted-content") {
                let id = request.url!.path.split(separator: "/").first { UUID(uuidString: String($0)) != nil }!
                let object: [String: Any] = [
                    "id": String(id), "title": "Server title", "content": "Server body",
                    "created_at": "2026-11-07T10:00:00Z", "updated_at": "2026-11-07T10:00:00Z",
                ]
                return .init(
                    statusCode: 200, headers: json, body: try! JSONSerialization.data(withJSONObject: object),
                    error: nil)
            }
            if request.httpMethod == "GET", url.hasSuffix("/"),
                let id = url.split(separator: "/").last.flatMap({ UUID(uuidString: String($0)) })
            {
                let detail: [String: Any] = [
                    "id": id.uuidString.lowercased(), "title": "Server title", "excerpt": NSNull(),
                    "abilities": ["update": canUpdate], "computed_link_reach": "restricted",
                    "computed_link_role": NSNull(), "created_at": "2026-11-07T10:00:00Z", "creator": NSNull(),
                    "depth": 1, "link_role": "reader", "link_reach": "restricted", "numchild": 0, "path": "0001",
                    "updated_at": "2026-11-07T10:00:00Z", "user_role": "owner",
                ]
                return .init(
                    statusCode: 200, headers: json, body: try! JSONSerialization.data(withJSONObject: detail),
                    error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
    }
}
