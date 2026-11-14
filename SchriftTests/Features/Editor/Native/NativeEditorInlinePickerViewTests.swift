import SwiftUI
import UIKit
import XCTest

@testable import Schrift

/// Step 3 of native inline pickers (`PR13c2`): `NativeEditorOpen.canMention`,
/// `EditorViewModel.nativePageLinkCandidates()`, `NativeMentionPickerView`,
/// `NativeEditorView` / `EditorView` integration, title priming, and silent
/// failure isolation.
@MainActor
final class NativeEditorInlinePickerViewTests: NativeEditingTestCase {
    private let owner = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let otherOwner = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let origin = "https://docs.example.org"
    private var windows: [UIWindow] = []

    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }

    @discardableResult
    private func hostController(_ controller: UIViewController) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let previous = scene?.windows.first(where: \.isKeyWindow)
        let window =
            scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in
            window.endEditing(true)
            window.isHidden = true
            previous?.makeKey()
        }
        windows.append(window)
        return window
    }

    private struct Env {
        let model: EditorViewModel
        let coordinator: DocumentSaveCoordinator
        let defaults: UserDefaults
        let suite: String
        let directory: URL
        let ownership: ReplicaOwnershipStore
        let replicaStore: ReplicaStore
        let listCache: DocumentCacheStore
        let childrenCache: DocumentChildrenCacheStore
        let signedInUser: SignedInUserStore
        let client: DocsAPIClient

        func clean() {
            MockURLProtocol.reset()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeEnv(
        documentID: UUID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
        userID: UUID? = nil,
        isOffline: Bool = false,
        isLocalDocument: Bool = false
    ) -> Env {
        MockURLProtocol.reset()
        let suite = "NativeEditorInlinePickerViewTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        if isOffline {
            defaults.set(true, forKey: "schrift.workOffline")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let client = DocsAPIClient(
            baseURL: URL(string: "\(origin)/api/v1.0/")!, session: MockURLProtocol.makeSession(),
            cookieProvider: { [] })
        let content = DocumentContentCacheStore(directory: directory)
        let children = DocumentChildrenCacheStore(userDefaults: defaults)
        let listCache = DocumentCacheStore(userDefaults: defaults)
        let ownership = ReplicaOwnershipStore(userDefaults: defaults)
        let replicaStore = ReplicaStore(
            directory: directory.appendingPathComponent("ReplicaDrafts"), ownershipStore: ownership)
        let createStore = PendingDocumentCreateStore(userDefaults: defaults)
        let deleteStore = PendingDocumentDeleteStore(userDefaults: defaults)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: PendingDraftStore(userDefaults: defaults), replicaStore: replicaStore,
            contentCache: content,
            createStore: createStore,
            deleteStore: deleteStore,
            attachmentStore: PendingAttachmentStore(
                userDefaults: defaults, directory: directory.appendingPathComponent("attachments")),
            listCache: listCache, childrenCache: children, serverOrigin: origin, backgroundTasks: .noop)
        let signedIn = SignedInUserStore(userDefaults: defaults)
        if let userID { signedIn.remember(userID) }
        var effectiveDocumentID = documentID
        if isLocalDocument, let userID {
            effectiveDocumentID =
                coordinator.createLocalDocument(
                    title: "Local Draft", parentID: nil, ownerUserID: userID
                ).id
        }
        let availability = OnlineAvailability(userDefaults: defaults)
        let model = EditorViewModel(
            client: client, documentID: effectiveDocumentID, title: "Current Doc", saveCoordinator: coordinator,
            serverOrigin: origin, signedInUser: signedIn, contentCache: content, childrenCache: children,
            listCache: listCache, availability: availability)
        return Env(
            model: model, coordinator: coordinator, defaults: defaults, suite: suite, directory: directory,
            ownership: ownership, replicaStore: replicaStore, listCache: listCache, childrenCache: children,
            signedInUser: signedIn, client: client)
    }

    private func makeDocument(
        id: UUID, title: String?, updatedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> Schrift.Document {
        Schrift.Document(
            id: id, title: title, excerpt: nil, abilities: DocumentAbilities(),
            linkReach: .restricted, linkRole: .reader, isFavorite: false,
            depth: 1, numchild: 0, path: "0001",
            createdAt: updatedAt, updatedAt: updatedAt, userRole: nil, creator: nil)
    }

    private func seedState() -> Data {
        BlockNoteYjs.encode([paragraph("p1", "Hello")], clientID: 1)
    }

    private func stubEditorOpen(
        state: Data,
        canUpdate: Bool = true,
        canMention: Bool = true,
        detailStatus: Int = 200,
        accessesStatus: Int = 200,
        accessesJSON: String = "[]",
        recorder: RequestRecorder? = nil
    ) {
        MockURLProtocol.stubHandler = { request in
            recorder?.record(request)
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
                    "id": String(id), "title": "Current Doc", "content": "Hello",
                    "created_at": "2026-11-07T10:00:00Z", "updated_at": "2026-11-07T10:00:00Z",
                ]
                return .init(
                    statusCode: 200, headers: json, body: try! JSONSerialization.data(withJSONObject: object),
                    error: nil)
            }
            if url.contains("/children/") {
                return .init(
                    statusCode: 200, headers: json, body: Data(#"{"count":0,"results":[]}"#.utf8), error: nil)
            }
            if url.contains("/accesses/") {
                return .init(
                    statusCode: accessesStatus, headers: json,
                    body: Data(accessesJSON.utf8), error: nil)
            }
            if request.httpMethod == "GET", url.hasSuffix("/"),
                let id = url.split(separator: "/").last.flatMap({ UUID(uuidString: String($0)) })
            {
                if detailStatus != 200 {
                    return .init(statusCode: detailStatus, headers: [:], body: Data(), error: nil)
                }
                let detail: [String: Any] = [
                    "id": id.uuidString.lowercased(), "title": "Current Doc", "excerpt": NSNull(),
                    "abilities": ["update": canUpdate, "mention": canMention],
                    "computed_link_reach": "restricted", "computed_link_role": NSNull(),
                    "created_at": "2026-11-07T10:00:00Z", "creator": NSNull(),
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

    // MARK: - NativeEditorOpen.canMention

    func testNativeEditorOpenReadsServerAbilityFallsBackOn5xxAndForcesFalseForReaders() async {
        let env = makeEnv(userID: owner)
        defer { env.clean() }
        let state = seedState()

        // 1. Server answers abilities.mention = true (overrides false pinRow).
        stubEditorOpen(state: state, canUpdate: true, canMention: true)
        let open = NativeEditorOpen(preference: { true })
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true, canMention: false)
        XCTAssertTrue(open.canMention)
        open.close()
        XCTAssertFalse(open.canMention, "close() resets canMention")

        // 2. Server answers abilities.mention = false (overrides true pinRow).
        let env2 = makeEnv(userID: owner)
        defer { env2.clean() }
        stubEditorOpen(state: state, canUpdate: true, canMention: false)
        let open2 = NativeEditorOpen(preference: { true })
        await open2.open(viewModel: env2.model, isOffline: false, canUpdate: true, canMention: true)
        XCTAssertFalse(open2.canMention)
        open2.close()

        // 3. Server detail fails with 503 (unanswered): falls back to pinRow.abilities.mention == true.
        let env3 = makeEnv(userID: owner)
        defer { env3.clean() }
        stubEditorOpen(state: state, detailStatus: 503)
        let open3 = NativeEditorOpen(preference: { true })
        await open3.open(viewModel: env3.model, isOffline: false, canUpdate: true, canMention: true)
        XCTAssertTrue(open3.canMention)
        open3.close()

        // 4. Server detail answers 403 (reader): forces canMention = false even with pinRow true.
        let env4 = makeEnv(userID: owner)
        defer { env4.clean() }
        stubEditorOpen(state: state, detailStatus: 403)
        let open4 = NativeEditorOpen(preference: { true })
        await open4.open(viewModel: env4.model, isOffline: false, canUpdate: true, canMention: true)
        XCTAssertFalse(open4.canMention)
        open4.close()
    }

    func testOwnedReplicaUpdatesCanMentionFromServerIntegration() async throws {
        let env = makeEnv(userID: owner)
        defer { env.clean() }
        let scope = ReplicaScope(
            serverOrigin: env.model.client.serverOrigin, ownerUserID: owner, org: "docs",
            documentID: env.model.documentID)
        _ = try env.replicaStore.create(for: scope, checkpoint: seedState())

        stubEditorOpen(state: seedState(), canUpdate: true, canMention: false)
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true, canMention: true)
        XCTAssertFalse(open.canMention, "server abilities.mention = false overrides stale pinRow")
    }

    // MARK: - EditorViewModel.nativePageLinkCandidates

    func testNativePageLinkCandidatesAreAccountScopedAndWorkOfflineAndOnLocalDocuments() {
        let env = makeEnv(userID: owner, isOffline: true, isLocalDocument: true)
        defer { env.clean() }
        let docID = env.model.documentID

        let subpageID = UUID(uuidString: "aaaa0001-0000-4000-8000-000000000001")!
        let homeID = UUID(uuidString: "aaaa0002-0000-4000-8000-000000000002")!
        let childID = UUID(uuidString: "aaaa0003-0000-4000-8000-000000000003")!
        let pendingDeleteID = UUID(uuidString: "aaaa0005-0000-4000-8000-000000000005")!
        let otherAccountID = UUID(uuidString: "bbbb0001-0000-4000-8000-000000000001")!

        let localChild = env.coordinator.createLocalDocument(
            title: "Local Only", parentID: nil, ownerUserID: owner)
        env.coordinator.recordPendingDelete(documentID: pendingDeleteID, ownerUserID: owner)

        env.model.subpages = [
            makeDocument(id: subpageID, title: "Subpage Alpha"),
            localChild,
        ]
        env.listCache.saveRecentDocuments(
            [
                makeDocument(id: docID, title: "Self Doc"),
                makeDocument(id: homeID, title: "Home Beta"),
                makeDocument(id: pendingDeleteID, title: "Deleting"),
            ],
            fetchedFor: owner)
        env.listCache.savePinnedDocuments(
            [makeDocument(id: otherAccountID, title: "Other User Secret")], fetchedFor: otherOwner)
        env.childrenCache.save([makeDocument(id: childID, title: "Child Gamma")], for: homeID)

        let candidateIDs = Set(env.model.nativePageLinkCandidates().map(\.id))
        XCTAssertEqual(candidateIDs, [subpageID, homeID, childID])
    }

    // MARK: - NativeMentionPickerView hosting

    func testNativeMentionPickerViewRendersLoadingEmptyAndCandidateStatesWithoutClipping() {
        let loc = LocalizationStore()
        let ada = MentionCandidate(
            userID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            fullName: "Ada Lovelace", shortName: "Ada", email: "ada@example.org")
        let grace = MentionCandidate(
            userID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            fullName: "grace@example.org", shortName: nil, email: "grace@example.org")

        for state in [
            NativeMentionPickerState(query: "", isLoading: true, matches: [], highlightedIndex: 0),
            NativeMentionPickerState(query: "zzz", isLoading: false, matches: [], highlightedIndex: 0),
            NativeMentionPickerState(query: "ada", isLoading: false, matches: [ada, grace], highlightedIndex: 0),
        ] {
            let host = UIHostingController(
                rootView: NativeMentionPickerView(picker: state, onSelect: { _ in })
                    .environment(loc)
                    .environment(\.dynamicTypeSize, .accessibility3))
            let size = host.sizeThatFits(in: CGSize(width: 360, height: 1_000))
            XCTAssertGreaterThan(size.height, 44)
            XCTAssertLessThan(size.height, 600)
        }
    }

    func testPickerViewsAndRecordedTitlesScrubBidiOverridesAndBoundLength() async throws {
        let env = makeEnv(userID: owner)
        defer { env.clean() }
        let targetID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let oversizedBidi = String(repeating: "A", count: 500) + "\u{202E}\u{FFFC}\nTail"

        env.model.recordNativeDocumentTitle(oversizedBidi, for: targetID)
        let recorded = try XCTUnwrap(env.model.cachedDocumentTitle(for: targetID))
        XCTAssertLessThanOrEqual(recorded.unicodeScalars.count, NativeInlineObject.defaultDisplayLimit + 1)
        XCTAssertFalse(recorded.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0xFFFC })

        let surface = NativeTextSurface(blocks: [], storage: NativeTextView().textStorage)
        surface.recordDocumentTitle("Spec\u{202E}\nNotes\u{FFFC}", for: targetID)
        XCTAssertEqual(surface.attachmentGeometry.documentTitles[targetID], "Spec Notes")

        let dirtyCandidate = MentionCandidate(
            userID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            fullName: "Ada\u{202E}Lovelace\n" + String(repeating: "x", count: 400),
            shortName: nil,
            email: "ada\u{202E}@example.org")
        let label = NativeMentionPickerView.rowAccessibilityLabel(for: dirtyCandidate)
        XCTAssertFalse(label.unicodeScalars.contains { $0.value == 0x202E })
        XCTAssertFalse(label.contains("\n"))
        XCTAssertLessThanOrEqual(label.unicodeScalars.count, (NativeInlineObject.defaultDisplayLimit + 1) * 2 + 2)
    }

    // MARK: - NativeEditorView & EditorView integration

    func testNativeEditorViewPickPageLinkPrimesTitleAndSlashMenuOffersLinkPage() async throws {
        let env = makeEnv(userID: owner)
        defer { env.clean() }
        let targetID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let targetDoc = makeDocument(id: targetID, title: "Product Roadmap")
        env.listCache.saveRecentDocuments([targetDoc], fetchedFor: owner)

        let session = try await NativeEditorSession.seed(
            state: BlockNoteYjs.encode([paragraph("p1", "")], clientID: 1),
            interlinkingOrigin: origin)
        addTeardownBlock { await session.close().value }
        session.enableTyping(persist: { _, _ in })
        let loader = NativeMentionAccessLoader(
            client: env.client,
            scope: .init(
                serverOrigin: origin, ownerUserID: owner, documentID: env.model.documentID, signInGeneration: 0),
            canMention: true, isLocalDocument: false, isOffline: false)
        let source = NativeInlinePickerSource(
            canInsertPageLink: { !documentLinkHost(forOrigin: self.origin).isEmpty },
            pageLinkCandidates: { [model = env.model] in model.nativePageLinkCandidates() },
            excludedDocumentID: env.model.documentID,
            onRecordDocumentTitle: { [model = env.model] id, title in
                model.recordNativeDocumentTitle(title, for: id)
            },
            canMention: { true },
            mentionState: { loader.state },
            requestMentions: { loader.requestMentions(for: $0) },
            clearMentionFailure: { loader.clearFailure() })

        let hosting = UIHostingController(
            rootView: NativeEditorView(
                session: session,
                title: "Doc",
                serverOrigin: origin,
                documentID: env.model.documentID,
                documentTitle: { [model = env.model] id in model.cachedDocumentTitle(for: id) },
                inlinePickerSource: source
            ).environment(LocalizationStore()))
        _ = hostController(hosting)

        let input = try XCTUnwrap(session.input)
        await waitUntil { input.inlinePickerSource != nil }

        // Slash items offer "Link a page" when serverOrigin is valid.
        XCTAssertTrue(input.slashItems.contains { $0.action == .linkPage })

        // Type `[[Road` and pick the candidate.
        XCTAssertTrue(input.replace(range: NSRange(location: 0, length: 0), with: "[[Road"))
        await session.settle()
        guard case .pageLink(let picker)? = input.inlinePicker else {
            return XCTFail("expected page link picker")
        }
        XCTAssertEqual(picker.matches.map(\.id), [targetID])

        let committed = await session.run { input.commitHighlightedInlinePicker() }
        XCTAssertTrue(committed)

        // Remove from listCache after pick to prove title priming itself resolves the chip.
        env.listCache.saveRecentDocuments([], fetchedFor: owner)
        XCTAssertEqual(env.model.cachedDocumentTitle(for: targetID), "Product Roadmap")
        XCTAssertEqual(session.surface.attachmentGeometry.documentTitles[targetID], "Product Roadmap")
    }

    func testEditorViewMentionPickerFetchesSilentlyHandles403AndResetsOnSignInGenerationBump() async throws {
        let docID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let env = makeEnv(documentID: docID, userID: owner)
        defer { env.clean() }
        let adaID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let recorder = RequestRecorder()

        let accessesJSON = """
            [
              {
                "id": "99999999-0000-4000-8000-000000000001",
                "user": {
                  "id": "\(adaID.uuidString.lowercased())",
                  "email": "ada@example.org",
                  "full_name": "Ada Lovelace",
                  "short_name": "Ada"
                },
                "team": null,
                "role": "editor",
                "abilities": {}
              }
            ]
            """

        // 403 on listAccesses silently hides picker without setting errorKey.
        stubEditorOpen(
            state: seedState(), canUpdate: true, canMention: true,
            accessesStatus: 403, accessesJSON: "{}", recorder: recorder)

        let defaults = env.defaults
        defaults.set(true, forKey: NativeEditorPreference.key)

        let open = NativeEditorOpen(preference: { NativeEditorPreference.isEnabled(defaults) })
        addTeardownBlock { open.close() }
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true, canMention: true)
        guard case .native(let session) = open.route else { return XCTFail("expected native session") }
        XCTAssertTrue(open.canMention)

        let loader = NativeMentionAccessLoader(
            client: env.client,
            scope: .init(serverOrigin: origin, ownerUserID: owner, documentID: docID, signInGeneration: 0),
            canMention: open.canMention, isLocalDocument: env.model.isLocalDocument, isOffline: false)
        let source = NativeInlinePickerSource(
            canInsertPageLink: { true },
            pageLinkCandidates: { env.model.nativePageLinkCandidates() },
            excludedDocumentID: docID,
            onRecordDocumentTitle: { id, title in env.model.recordNativeDocumentTitle(title, for: id) },
            canMention: { open.canMention },
            mentionState: { loader.state },
            requestMentions: { loader.requestMentions(for: $0) },
            clearMentionFailure: { loader.clearFailure() })

        let hosting = UIHostingController(
            rootView: NativeEditorView(
                session: session, title: "Doc", serverOrigin: origin,
                documentID: docID,
                documentTitle: { env.model.cachedDocumentTitle(for: $0) },
                inlinePickerSource: source
            ).environment(LocalizationStore()))
        _ = hostController(hosting)

        let input = try XCTUnwrap(session.input)
        await waitUntil { input.inlinePickerSource != nil }

        // Move caret to end of "Hello" and type " @ada".
        session.textView.selectedRange = NSRange(location: 5, length: 0)
        XCTAssertTrue(input.replace(range: NSRange(location: 5, length: 0), with: " @ada"))
        await session.settle()
        await waitUntil {
            if case .failed = loader.state { return true }
            return false
        }
        XCTAssertNil(input.inlinePicker, "403 silently suppresses picker")
        XCTAssertNil(env.model.errorKey, "403 on listAccesses must never set errorKey")

        // Now stub 200 and bump signInGeneration: loader resets and new account can mention.
        stubEditorOpen(
            state: seedState(), canUpdate: true, canMention: true,
            accessesStatus: 200, accessesJSON: accessesJSON, recorder: recorder)
        loader.update(
            scope: .init(serverOrigin: origin, ownerUserID: otherOwner, documentID: docID, signInGeneration: 1),
            canMention: true, isLocalDocument: false, isOffline: false)
        XCTAssertEqual(loader.state, .idle)

        input.refreshInlinePicker()
        await waitUntil {
            if case .mention(let state)? = input.inlinePicker { return !state.isLoading && state.matches.count == 1 }
            return false
        }
        let committed = await session.run { input.commitHighlightedInlinePicker() }
        XCTAssertTrue(committed)
        let block = try XCTUnwrap(session.surface.blocks.first)
        XCTAssertTrue(
            block.runs.contains {
                $0.inlineObject == .mention(userID: adaID.uuidString.lowercased(), fullName: "Ada Lovelace")
            })
    }

    func testEditorViewWiresInlinePickerSourceAndResetsOnSignInGenerationChange() async throws {
        let docID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let env = makeEnv(documentID: docID, userID: owner)
        defer { env.clean() }
        let adaID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let graceID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
        let recorder = RequestRecorder()

        let previousNativePref = UserDefaults.standard.object(forKey: NativeEditorPreference.key)
        UserDefaults.standard.set(true, forKey: NativeEditorPreference.key)
        addTeardownBlock {
            if let previousNativePref {
                UserDefaults.standard.set(previousNativePref, forKey: NativeEditorPreference.key)
            } else {
                UserDefaults.standard.removeObject(forKey: NativeEditorPreference.key)
            }
        }

        let adaJSON = """
            [{"id":"99999999-0000-4000-8000-000000000001","user":{"id":"\(adaID.uuidString.lowercased())","email":"ada@example.org","full_name":"Ada Lovelace","short_name":"Ada"},"team":null,"role":"editor","abilities":{}}]
            """
        let graceJSON = """
            [{"id":"99999999-0000-4000-8000-000000000002","user":{"id":"\(graceID.uuidString.lowercased())","email":"grace@example.org","full_name":"Grace Hopper","short_name":"Grace"},"team":null,"role":"editor","abilities":{}}]
            """

        let useGrace = Locked(false)
        MockURLProtocol.stubHandler = { request in
            recorder.record(request)
            let url = request.url?.absoluteString ?? ""
            let json = ["Content-Type": "application/json"]
            if url.hasSuffix("/config/") {
                return .init(
                    statusCode: 200, headers: json, body: Data(#"{"RELEASE_VERSION":"6.0.0"}"#.utf8), error: nil)
            }
            if url.contains("/collaboration/ydoc/") {
                let state = BlockNoteYjs.encode(
                    [BlockNoteBlock(node: "paragraph", props: [], runs: [InlineRun("Hello")], id: "p1")], clientID: 1)
                let body = try! JSONSerialization.data(withJSONObject: ["doc": state.base64EncodedString()])
                return .init(statusCode: 200, headers: json, body: body, error: nil)
            }
            if url.contains("formatted-content") {
                let id = request.url!.path.split(separator: "/").first { UUID(uuidString: String($0)) != nil }!
                let object: [String: Any] = [
                    "id": String(id), "title": "Current Doc", "content": "Hello",
                    "created_at": "2026-11-07T10:00:00Z", "updated_at": "2026-11-07T10:00:00Z",
                ]
                return .init(
                    statusCode: 200, headers: json, body: try! JSONSerialization.data(withJSONObject: object),
                    error: nil)
            }
            if url.contains("/children/") {
                return .init(
                    statusCode: 200, headers: json, body: Data(#"{"count":0,"results":[]}"#.utf8), error: nil)
            }
            if url.contains("/accesses/") {
                let payload = useGrace.value ? graceJSON : adaJSON
                return .init(statusCode: 200, headers: json, body: Data(payload.utf8), error: nil)
            }
            if request.httpMethod == "GET", url.hasSuffix("/"),
                let id = url.split(separator: "/").last.flatMap({ UUID(uuidString: String($0)) })
            {
                let detail: [String: Any] = [
                    "id": id.uuidString.lowercased(), "title": "Current Doc", "excerpt": NSNull(),
                    "abilities": ["update": true, "mention": true],
                    "computed_link_reach": "restricted", "computed_link_role": NSNull(),
                    "created_at": "2026-11-07T10:00:00Z", "creator": NSNull(),
                    "depth": 1, "link_role": "reader", "link_reach": "restricted", "numchild": 0, "path": "0001",
                    "updated_at": "2026-11-07T10:00:00Z", "user_role": "owner",
                ]
                return .init(
                    statusCode: 200, headers: json, body: try! JSONSerialization.data(withJSONObject: detail),
                    error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }

        let genBox = InlinePickerGenerationBox()
        let registry = NativeSessionRegistry()
        let loc = LocalizationStore()

        let hosting = UIHostingController(
            rootView: InlinePickerEditorHost(
                viewModel: env.model,
                childrenCache: env.childrenCache,
                genBox: genBox,
                registry: registry,
                loc: loc))
        _ = hostController(hosting)

        let scopeA = ReplicaScope(
            serverOrigin: origin, ownerUserID: owner, org: "docs", documentID: docID)
        await waitUntil { registry.surfaces(of: scopeA).first?.input?.inlinePickerSource != nil }

        let sessionA = try XCTUnwrap(registry.surfaces(of: scopeA).first)
        let inputA = try XCTUnwrap(sessionA.input)
        XCTAssertTrue(inputA.inlinePickerSource?.canMention() == true)
        sessionA.textView.onRequestEdit?()
        await waitUntil { sessionA.textView.isEditable }
        sessionA.textView.selectedRange = NSRange(location: 5, length: 0)
        XCTAssertTrue(inputA.replace(range: NSRange(location: 5, length: 0), with: " @"))
        await sessionA.settle()

        await waitUntil {
            if case .mention(let state)? = inputA.inlinePicker {
                return !state.isLoading && state.matches.map(\.fullName) == ["Ada Lovelace"]
            }
            return false
        }

        // Bump signInGeneration: EditorView resets mentionLoader and reopens cleanly.
        useGrace.value = true
        genBox.generation = 1

        await waitUntil {
            registry.surfaces(of: scopeA).contains {
                $0 !== sessionA && !$0.isClosed && $0.input?.inlinePickerSource != nil
            }
        }

        let sessionB = try XCTUnwrap(
            registry.surfaces(of: scopeA).first { $0 !== sessionA && !$0.isClosed })
        let inputB = try XCTUnwrap(sessionB.input)
        sessionB.textView.onRequestEdit?()
        await waitUntil { sessionB.textView.isEditable }
        sessionB.textView.selectedRange = NSRange(location: 5, length: 0)
        XCTAssertTrue(inputB.replace(range: NSRange(location: 5, length: 0), with: " @"))
        await sessionB.settle()

        await waitUntil {
            if case .mention(let state)? = inputB.inlinePicker {
                return !state.isLoading && state.matches.map(\.fullName) == ["Grace Hopper"]
            }
            return false
        }
        XCTAssertEqual(recorder.count(ofMethod: "GET", urlContaining: "/accesses/"), 2)
        await sessionA.close().value
        await sessionB.close().value
        await registry.drainAll()
    }
}

@MainActor @Observable
private final class InlinePickerGenerationBox {
    var generation = 0
}

private struct InlinePickerEditorHost: View {
    let viewModel: EditorViewModel
    let childrenCache: DocumentChildrenCacheStore
    let genBox: InlinePickerGenerationBox
    let registry: NativeSessionRegistry
    let loc: LocalizationStore

    var body: some View {
        EditorView(
            viewModel: viewModel,
            reach: .restricted,
            serverHost: "docs.example.org",
            serverOrigin: "https://docs.example.org",
            childrenCache: childrenCache,
            pinRow: Document(
                id: viewModel.documentID, title: "Current Doc", excerpt: nil,
                abilities: {
                    var a = DocumentAbilities()
                    a.update = true
                    a.mention = true
                    return a
                }(),
                linkReach: .restricted, linkRole: .reader, isFavorite: false,
                depth: 1, numchild: 0, path: "0001",
                createdAt: Date(), updatedAt: Date(), userRole: .owner, creator: nil),
            signInGeneration: genBox.generation
        )
        .environment(registry)
        .environment(loc)
    }
}
