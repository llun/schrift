import SwiftUI
import XCTest

@testable import Schrift

@MainActor
final class NewDocumentEntryTests: XCTestCase {
    private let documentID = UUID()
    private let ownerID = UUID()
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var directory: URL!
    private var client: DocsAPIClient!
    private var coordinator: DocumentSaveCoordinator!
    private var drafts: PendingDraftStore!
    private var cache: DocumentContentCacheStore!
    private var children: DocumentChildrenCacheStore!

    override func setUp() {
        super.setUp()
        suiteName = "NewDocumentEntryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        client = DocsAPIClient(
            baseURL: URL(string: "https://docs.example.org/api/v1.0/")!,
            session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        drafts = PendingDraftStore(userDefaults: defaults)
        cache = DocumentContentCacheStore(directory: directory)
        children = DocumentChildrenCacheStore(userDefaults: defaults)
        coordinator = DocumentSaveCoordinator(
            client: client, draftStore: drafts, contentCache: cache,
            createStore: PendingDocumentCreateStore(userDefaults: defaults),
            deleteStore: PendingDocumentDeleteStore(userDefaults: defaults),
            listCache: DocumentCacheStore(userDefaults: defaults), childrenCache: children,
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)
        SignedInUserStore(userDefaults: defaults).remember(ownerID)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        coordinator = nil
        client = nil
        super.tearDown()
    }

    private func editor(id: UUID? = nil, intent: NewDocumentEntryIntent? = nil) -> EditorViewModel {
        EditorViewModel(
            client: client, documentID: id ?? documentID, title: "Untitled document",
            saveCoordinator: coordinator, entryIntent: intent,
            signedInUser: SignedInUserStore(userDefaults: defaults), contentCache: cache,
            childrenCache: children, autosaveInterval: .seconds(60))
    }

    private func stubContent(
        title: String = "Untitled document", markdown: String = "", gate: MockURLProtocol.ResponseGate? = nil
    ) {
        let body = try! JSONSerialization.data(withJSONObject: [
            "id": documentID.uuidString, "title": title, "content": markdown,
            "created_at": "2026-10-04T10:00:00Z", "updated_at": "2026-10-04T10:00:00Z",
        ])
        MockURLProtocol.stubHandler = { request in
            if request.url!.path.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: body, error: nil, releasedBy: gate)
            }
            return .init(statusCode: 200, headers: [:], body: Data("{\"count\":0,\"results\":[]}".utf8), error: nil)
        }
    }

    private func textViews(in view: UIView) -> [UITextView] {
        (view as? UITextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
    }

    func testRenderedCreationHeaderFocusesAndSelectsTitleOnce() async throws {
        let vm = editor(intent: NewDocumentEntryIntent())
        stubContent()
        await vm.load()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(
            rootView: EditorDocumentHeader(
                title: vm.title, onEditTitle: vm.updateTitle, reach: .restricted, peers: [],
                onConsumeInitialTitleFocus: vm.consumeInitialTitleFocus
            ) { Text("Synced just now") }
            .padding(16)
            .environment(LocalizationStore(userDefaults: defaults)))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.endEditing(true)
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        await waitUntil { self.textViews(in: host.view).contains(where: \.isFirstResponder) }
        let titleView = try XCTUnwrap(textViews(in: host.view).first(where: \.isFirstResponder))
        XCTAssertEqual(titleView.selectedRange, NSRange(location: 0, length: (vm.title as NSString).length))
        XCTAssertFalse(vm.isDirty, "selection/focus alone must not enqueue a save")
        titleView.insertText("Replacement title")
        await waitUntil { vm.title == "Replacement title" }
        XCTAssertTrue(vm.isDirty)
        titleView.resignFirstResponder()
        host.rootView = EditorDocumentHeader(
            title: vm.title, onEditTitle: vm.updateTitle, reach: .restricted, peers: [],
            onConsumeInitialTitleFocus: vm.consumeInitialTitleFocus
        ) { Text("Saved on this device") }
        .padding(16)
        .environment(LocalizationStore(userDefaults: defaults))
        await waitAndConfirmNever { self.textViews(in: host.view).contains(where: \.isFirstResponder) }
        vm.finishEditing()
    }

    func testNewDocumentWaitsForContentThenEntersEditingWithoutDirtyingOrBodyFocus() async {
        let intent = NewDocumentEntryIntent()
        let vm = editor(intent: intent)
        let gate = MockURLProtocol.ResponseGate()
        stubContent(markdown: "Existing body", gate: gate)
        let load = Task { await vm.load() }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        XCTAssertFalse(vm.canStartEditing)
        XCTAssertFalse(vm.isEditing)
        XCTAssertFalse(vm.consumeInitialTitleFocus())
        vm.startEditing()
        vm.flushPendingChanges()
        XCTAssertFalse(vm.isEditing)
        XCTAssertNil(drafts.draft(for: documentID))
        gate.open()
        await load.value
        XCTAssertTrue(vm.isEditing)
        XCTAssertEqual(vm.currentMarkdown(), "Existing body\n")
        XCTAssertNil(vm.focusedBlockID)
        XCTAssertFalse(vm.isDirty)
        XCTAssertTrue(vm.consumeInitialTitleFocus())
        XCTAssertFalse(vm.consumeInitialTitleFocus())
        vm.finishEditing()
        XCTAssertNil(drafts.draft(for: documentID))
    }

    func testChildrenRevalidationCannotDelayInitializedCreationEntry() async {
        let gate = MockURLProtocol.ResponseGate()
        let body = try! JSONSerialization.data(withJSONObject: [
            "id": documentID.uuidString, "title": "Untitled document", "content": "",
            "created_at": "2026-10-04T10:00:00Z", "updated_at": "2026-10-04T10:00:00Z",
        ])
        MockURLProtocol.stubHandler = { request in
            if request.url!.path.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: body, error: nil)
            }
            return .init(
                statusCode: 200, headers: [:], body: Data("{\"count\":0,\"results\":[]}".utf8),
                error: nil, releasedBy: gate)
        }
        let vm = editor(intent: NewDocumentEntryIntent())
        let load = Task { await vm.load() }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        XCTAssertTrue(vm.hasLoadedContent)
        XCTAssertTrue(vm.isEditing)
        XCTAssertFalse(vm.isLoading, "the spinner must release the editing canvas before children finish")
        XCTAssertTrue(vm.consumeInitialTitleFocus())
        gate.open()
        await load.value
    }

    func testEmptyInitializedDocumentFocusesTitleInsteadOfSeedParagraph() async {
        let vm = editor(intent: NewDocumentEntryIntent())
        stubContent()
        await vm.load()
        XCTAssertTrue(vm.isEditing)
        XCTAssertEqual(vm.blocks.count, 1)
        XCTAssertNil(vm.focusedBlockID)
        XCTAssertNil(vm.cursorRequest)
        XCTAssertTrue(vm.consumeInitialTitleFocus())
        vm.finishEditing()
        XCTAssertNil(drafts.draft(for: documentID))
    }

    func testFailedLoadLeavesIntentPendingAndRetrySafelyEnters() async {
        let vm = editor(intent: NewDocumentEntryIntent())
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        await vm.load()
        XCTAssertEqual(vm.errorKey, .editor_error_load)
        XCTAssertFalse(vm.isEditing)
        XCTAssertFalse(vm.consumeInitialTitleFocus())
        vm.flushPendingChanges()
        XCTAssertNil(drafts.draft(for: documentID))
        stubContent(markdown: "Body recovered on retry")
        await vm.refresh()
        XCTAssertTrue(vm.isEditing)
        XCTAssertEqual(vm.currentMarkdown(), "Body recovered on retry\n")
        XCTAssertTrue(vm.consumeInitialTitleFocus())
    }

    func testForbiddenLoadCannotEnterOrSaveAndSuccessfulRetryCanEnter() async {
        let vm = editor(intent: NewDocumentEntryIntent())
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 403, headers: [:], body: Data(), error: nil) }
        await vm.load()
        XCTAssertTrue(vm.isUnavailable)
        XCTAssertFalse(vm.canStartEditing)
        XCTAssertFalse(vm.consumeInitialTitleFocus())
        vm.flushPendingChanges()
        XCTAssertNil(drafts.draft(for: documentID))
        stubContent(markdown: "Real body")
        await vm.refresh()
        XCTAssertTrue(vm.isEditing)
        XCTAssertEqual(vm.currentMarkdown(), "Real body\n")
    }

    func testRefreshReappearanceAndRecreatedScreenDoNotReenterOrRefocus() async {
        let intent = NewDocumentEntryIntent()
        let vm = editor(intent: intent)
        stubContent()
        await vm.load()
        XCTAssertTrue(vm.consumeInitialTitleFocus())
        vm.finishEditing()
        await vm.refresh()
        await vm.load()
        XCTAssertFalse(vm.isEditing)
        XCTAssertFalse(vm.consumeInitialTitleFocus())
        let restored = editor(intent: intent)
        await restored.load()
        XCTAssertFalse(restored.isEditing)
        XCTAssertFalse(restored.consumeInitialTitleFocus())
    }

    func testOrdinaryOpenOfEmptyDocumentRemainsReading() async {
        let vm = editor()
        stubContent()
        await vm.load()
        XCTAssertTrue(vm.canStartEditing)
        XCTAssertFalse(vm.isEditing)
        XCTAssertFalse(vm.consumeInitialTitleFocus())
        vm.startEditing()
        XCTAssertTrue(vm.isEditing)
        XCTAssertNotNil(vm.focusedBlockID, "manual Start writing retains paragraph focus")
    }

    func testLocalCreationRestoresSeedBeforeEntryWithoutNetworkAndReopensReading() async {
        let document = coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: ownerID)
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }
        let vm = editor(id: document.id, intent: NewDocumentEntryIntent())
        XCTAssertFalse(vm.canStartEditing)
        await vm.load()
        XCTAssertTrue(vm.isLocalDocument)
        XCTAssertTrue(vm.isEditing)
        XCTAssertEqual(vm.currentMarkdown(), "")
        XCTAssertTrue(vm.consumeInitialTitleFocus())
        XCTAssertNil(vm.focusedBlockID)
        vm.updateTitle("Offline title")
        vm.updateText(blockID: vm.blocks[0].id, text: "Offline body")
        vm.finishEditing()
        XCTAssertEqual(drafts.draft(for: document.id)?.title, "Offline title")
        XCTAssertEqual(drafts.draft(for: document.id)?.markdown, "Offline body\n")
        let reopened = editor(id: document.id)
        await reopened.load()
        XCTAssertEqual(reopened.title, "Offline title")
        XCTAssertEqual(reopened.currentMarkdown(), "Offline body\n")
        XCTAssertFalse(reopened.isEditing)
        XCTAssertFalse(reopened.consumeInitialTitleFocus())
        XCTAssertTrue(log.methods.isEmpty)
    }

    func testRestoredDraftEntersBeforeSlowRevalidationAndKeepsItsTitleAndBody() async {
        drafts.save(
            PendingDraft(
                documentID: documentID, title: "My draft title", markdown: "Draft body", updatedAt: Date()))
        let gate = MockURLProtocol.ResponseGate()
        stubContent(markdown: "", gate: gate)
        let vm = editor(intent: NewDocumentEntryIntent())
        let load = Task { await vm.load() }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        XCTAssertTrue(vm.isEditing)
        XCTAssertEqual(vm.title, "My draft title")
        XCTAssertEqual(vm.currentMarkdown(), "Draft body\n")
        XCTAssertTrue(vm.consumeInitialTitleFocus())
        gate.open()
        await load.value
        XCTAssertEqual(vm.currentMarkdown(), "Draft body\n")
        XCTAssertFalse(vm.consumeInitialTitleFocus())
    }

    func testTitleOnlyEditPersistsLoadedBodyAndOrdinaryReopenReadsSavedTitle() async {
        let vm = editor(intent: NewDocumentEntryIntent())
        stubContent(markdown: "Body that must survive the rename")
        await vm.load()
        XCTAssertTrue(vm.consumeInitialTitleFocus())
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        vm.updateTitle("My new title")
        vm.finishEditing()
        XCTAssertEqual(drafts.draft(for: documentID)?.title, "My new title")
        XCTAssertEqual(drafts.draft(for: documentID)?.markdown, "Body that must survive the rename\n")
        await waitUntil { vm.saveState == .pendingSync }
        let reopened = editor()
        await reopened.load()
        XCTAssertEqual(reopened.title, "My new title")
        XCTAssertEqual(reopened.currentMarkdown(), "Body that must survive the rename\n")
        XCTAssertFalse(reopened.isEditing)
    }

    private func documentBody(id: UUID, title: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "id": id.uuidString, "title": title, "abilities": [:], "link_reach": "restricted",
            "link_role": "reader", "is_favorite": false, "depth": 1, "numchild": 0, "path": "0001",
            "created_at": "2026-10-04T10:00:00Z", "updated_at": "2026-10-04T10:00:00Z",
        ])
    }

    func testHomeOnlineAndWorkOfflineCreationCarryIntentOnlyOnCreationRoute() async throws {
        let home = HomeViewModel(
            client: client, cache: DocumentCacheStore(userDefaults: defaults), saveCoordinator: coordinator,
            userDefaults: defaults, signedInUser: SignedInUserStore(userDefaults: defaults),
            cachedUser: CurrentUserCacheStore(userDefaults: defaults))
        let createdBody = documentBody(id: documentID, title: "Untitled document")
        MockURLProtocol.stubHandler = { request in
            if request.httpMethod == "POST" {
                return .init(statusCode: 201, headers: [:], body: createdBody, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: Data("{\"count\":0,\"results\":[]}".utf8), error: nil)
        }
        let onlineDocument = await home.createDocument()
        let online = try XCTUnwrap(onlineDocument)
        stubContent()
        let onlineRoute = DocumentEditorRoute(createdDocument: online)
        let onlineEditor = editor(id: online.id, intent: onlineRoute.entryIntent)
        await onlineEditor.load()
        XCTAssertTrue(onlineEditor.isEditing)
        XCTAssertTrue(onlineEditor.consumeInitialTitleFocus())
        XCTAssertNil(DocumentEditorRoute(document: online).entryIntent)

        defaults.set(true, forKey: "schrift.workOffline")
        let offlineDocument = await home.createDocument()
        let offline = try XCTUnwrap(offlineDocument)
        let offlineRoute = DocumentEditorRoute(createdDocument: offline)
        let offlineEditor = editor(id: offline.id, intent: offlineRoute.entryIntent)
        await offlineEditor.load()
        XCTAssertTrue(offlineEditor.isLocalDocument)
        XCTAssertTrue(offlineEditor.isEditing)
        XCTAssertTrue(offlineEditor.consumeInitialTitleFocus())
    }

    func testOnlineSubpagesFromBothCreationSurfacesReceiveNewDocumentEntry() async throws {
        let vm = editor()
        let childID = UUID()
        let body = documentBody(id: childID, title: "Untitled subpage")
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 201, headers: [:], body: body, error: nil) }
        let addedSubpage = await vm.addSubpage()
        let subpage = try XCTUnwrap(addedSubpage)
        let tree = PagesTreeViewModel(
            rootID: documentID, client: client, cache: children, userDefaults: defaults,
            saveCoordinator: coordinator, signedInUser: SignedInUserStore(userDefaults: defaults))
        let addedPage = await tree.addPage(under: documentID)
        let page = try XCTUnwrap(addedPage)
        stubContent(title: "Untitled subpage")
        for child in [subpage, page] {
            let route = DocumentEditorRoute(createdDocument: child)
            let created = editor(id: child.id, intent: route.entryIntent)
            await created.load()
            XCTAssertTrue(created.isEditing)
            XCTAssertTrue(created.consumeInitialTitleFocus())
        }
    }

    func testConsumedIntentCannotRearmUnderAnotherDocumentIdentity() async {
        let intent = NewDocumentEntryIntent()
        let local = coordinator.createLocalDocument(title: "Untitled document", parentID: nil, ownerUserID: ownerID)
        let localEditor = editor(id: local.id, intent: intent)
        await localEditor.load()
        XCTAssertTrue(localEditor.consumeInitialTitleFocus())
        localEditor.finishEditing()
        stubContent(title: "Persisted title")
        let serverEditor = editor(id: documentID, intent: intent)
        await serverEditor.load()
        XCTAssertFalse(serverEditor.isEditing)
        XCTAssertFalse(serverEditor.consumeInitialTitleFocus())
        XCTAssertEqual(serverEditor.title, "Persisted title")
    }

    func testFullEditorCreationFocusAtNormalAndAccessibilitySizes() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.endEditing(true)
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        let fixtures: [(String, DynamicTypeSize)] = [
            ("Untitled document", .large),
            ("A long document title that wraps across several lines and keeps its ending visible", .large),
            ("A long document title with larger accessible text", .accessibility3),
        ]
        for (index, fixture) in fixtures.enumerated() {
            let document = coordinator.createLocalDocument(
                title: fixture.0, parentID: nil, ownerUserID: ownerID,
                seedMarkdown: "First paragraph stays beneath the shared document header.")
            let vm = editor(id: document.id, intent: NewDocumentEntryIntent())
            let host = UIHostingController(
                rootView: NavigationStack {
                    EditorView(
                        viewModel: vm, reach: .restricted, serverHost: "docs.example.org",
                        serverOrigin: "https://docs.example.org", childrenCache: children, isOffline: true)
                }
                .environment(LocalizationStore(userDefaults: defaults))
                .environment(DocumentCollaborationManager.inert())
                .environment(AttachmentLoader.inert())
                .environment(\.dynamicTypeSize, fixture.1))
            window.rootViewController = host
            window.makeKeyAndVisible()
            await waitUntil { self.textViews(in: host.view).contains(where: \.isFirstResponder) }
            let field = try XCTUnwrap(textViews(in: host.view).first(where: \.isFirstResponder))
            XCTAssertEqual(field.text, fixture.0)
            XCTAssertEqual(field.selectedRange.length, (fixture.0 as NSString).length)
            XCTAssertNil(vm.focusedBlockID)
            XCTAssertFalse(vm.isDirty)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "New document canvas \(index)"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.endEditing(true)
            vm.finishEditing()
        }
    }

    func testNewLocalSubpagesFromBothCreationSurfacesEnterAndReopenReading() async throws {
        let parent = coordinator.createLocalDocument(title: "Parent", parentID: nil, ownerUserID: ownerID)
        let vm = editor(id: parent.id)
        let addedSubpage = await vm.addSubpage()
        let subpage = try XCTUnwrap(addedSubpage)
        let tree = PagesTreeViewModel(
            rootID: parent.id, client: client, cache: children, userDefaults: defaults,
            saveCoordinator: coordinator, signedInUser: SignedInUserStore(userDefaults: defaults))
        let addedPage = await tree.addPage(under: parent.id)
        let page = try XCTUnwrap(addedPage)
        for child in [subpage, page] {
            let route = DocumentEditorRoute(createdDocument: child)
            let created = editor(id: child.id, intent: route.entryIntent)
            await created.load()
            XCTAssertTrue(created.isEditing)
            XCTAssertEqual(created.title, "Untitled subpage")
            XCTAssertTrue(created.consumeInitialTitleFocus())
            let reopened = editor(id: child.id)
            await reopened.load()
            XCTAssertFalse(reopened.isEditing)
        }
    }
}
