import XCTest

@testable import Schrift

/// The drawer's loading rules. The ones that matter are the destructive ones:
/// the children cache it writes is shared with the editor's own Subpages list,
/// so a level this view model invents or truncates outlives the drawer.
@MainActor
final class PagesTreeViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let rootID = UUID(uuidString: "1A1A1A1A-1A1A-4A1A-8A1A-1A1A1A1A1A1A")!
    private let childID = UUID(uuidString: "2B2B2B2B-2B2B-4B2B-8B2B-2B2B2B2B2B2B")!
    private let createdID = UUID(uuidString: "4D4D4D4D-4D4D-4D4D-8D4D-4D4D4D4D4D4D")!

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var contentCacheDirectory: URL!

    override func setUp() {
        super.setUp()
        suiteName = "PagesTreeViewModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        contentCacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PagesTreeViewModelTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: contentCacheDirectory)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeViewModel() -> (PagesTreeViewModel, DocumentChildrenCacheStore) {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let cache = DocumentChildrenCacheStore(userDefaults: defaults)
        return (PagesTreeViewModel(rootID: rootID, client: client, cache: cache, userDefaults: defaults), cache)
    }

    /// A drawer rooted at a document created **on this device**, with the coordinator wired.
    ///
    /// Every store shares this test's isolated suite — the draft store and the create store
    /// especially. A coordinator whose `createStore` falls back to `UserDefaults.standard`
    /// writes real records into the shared domain, and a later pass then issues a genuine
    /// `/users/me/` that escapes `MockURLProtocol` and stalls the run for a minute.
    private func makeLocalRootViewModel(signedInUserID: UUID? = UUID()) -> (
        viewModel: PagesTreeViewModel, coordinator: DocumentSaveCoordinator, root: Document,
        cache: DocumentChildrenCacheStore
    ) {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let cache = DocumentChildrenCacheStore(userDefaults: defaults)
        // Every store on this test's own suite — including the two the coordinator would
        // otherwise default onto `UserDefaults.standard` — so nothing here writes app-wide
        // storage. `createStore` is the one that must not be missed (a leaked record makes a
        // later pass issue a real `/users/me/` that escapes MockURLProtocol and stalls the run),
        // but a test has no business leaving the others behind either.
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: PendingDraftStore(userDefaults: defaults),
            contentCache: DocumentContentCacheStore(directory: contentCacheDirectory),
            createStore: PendingDocumentCreateStore(userDefaults: defaults),
            deleteStore: PendingDocumentDeleteStore(userDefaults: defaults),
            listCache: DocumentCacheStore(userDefaults: defaults), childrenCache: cache,
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)
        let signedIn = SignedInUserStore(userDefaults: defaults)
        if let signedInUserID { signedIn.remember(signedInUserID) }
        let root = coordinator.createLocalDocument(
            title: "Root", parentID: nil, ownerUserID: signedInUserID ?? UUID())
        let viewModel = PagesTreeViewModel(
            rootID: root.id, client: client, cache: cache, userDefaults: defaults,
            saveCoordinator: coordinator, signedInUser: signedIn)
        return (viewModel, coordinator, root, cache)
    }

    private func document(_ id: UUID, title: String, numchild: Int = 0) -> Document {
        Document(
            id: id, title: title, excerpt: nil, abilities: DocumentAbilities(),
            linkReach: .restricted, linkRole: .reader, isFavorite: false,
            depth: 1, numchild: numchild, path: "0001",
            createdAt: Date(), updatedAt: Date(), userRole: nil, creator: nil)
    }

    nonisolated private static func documentFixture(id: UUID, title: String, numchild: Int = 0) -> String {
        """
        {
            "id": "\(id.uuidString.lowercased())",
            "title": "\(title)",
            "excerpt": null,
            "abilities": {},
            "computed_link_reach": "restricted",
            "computed_link_role": null,
            "created_at": "2026-01-15T10:30:00Z",
            "creator": null,
            "depth": 1,
            "link_role": "reader",
            "link_reach": "restricted",
            "numchild": \(numchild),
            "path": "0001",
            "updated_at": "2026-01-15T10:30:00Z",
            "user_role": "owner"
        }
        """
    }

    nonisolated private static func listFixture(_ documents: [(UUID, String)]) -> Data {
        let results = documents.map { documentFixture(id: $0.0, title: $0.1) }.joined(separator: ",")
        return Data(
            """
            {"count": \(documents.count), "next": null, "previous": null, "results": [\(results)]}
            """.utf8)
    }

    // MARK: - Offline

    /// "Work offline" means never touch the network, not "try anyway and fall
    /// back on the cache" — the same contract the document lists honour.
    func testWorkOfflineServesTheCacheAndIssuesNoRequest() async {
        defaults.set(true, forKey: "schrift.workOffline")
        let (viewModel, cache) = makeViewModel()
        cache.save([document(childID, title: "Cached page")], for: rootID)
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 200, headers: [:], body: Self.listFixture([]), error: nil)
        }

        await viewModel.loadRoot()

        XCTAssertEqual(viewModel.rows.map(\.document.id), [childID], "the cached level still renders")
        XCTAssertEqual(log.methods.count, 0, "no request may be issued while working offline")
    }

    func testAFailedFetchKeepsTheCachedLevelAndStaysSilent() async {
        let (viewModel, cache) = makeViewModel()
        cache.save([document(childID, title: "Cached page")], for: rootID)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.loadRoot()

        XCTAssertEqual(viewModel.rows.map(\.document.id), [childID])
        XCTAssertNil(viewModel.errorKey, "a cached level to fall back on is not an error the user must be shown")
    }

    // MARK: - Load failures

    /// Left expanded, a level that failed to load renders as a node with no
    /// children — indistinguishable from a leaf, and with no way to retry.
    func testAFailedFetchWithNoCacheCollapsesTheNodeAndReportsIt() async {
        let (viewModel, cache) = makeViewModel()
        let parent = document(childID, title: "Parent", numchild: 2)
        cache.save([parent], for: rootID)
        MockURLProtocol.stubHandler = { [childID] request in
            request.url?.path.contains(childID.uuidString.lowercased()) == true
                ? .init(statusCode: 500, headers: [:], body: Data(), error: nil)
                : .init(statusCode: 200, headers: [:], body: Self.listFixture([]), error: nil)
        }

        await viewModel.toggle(parent)

        XCTAssertFalse(viewModel.expanded.contains(childID), "it collapses, so its arrow — the retry — comes back")
        XCTAssertEqual(viewModel.errorKey, .pages_error_load)
    }

    /// One shared error flag would let a success anywhere in the tree wipe a
    /// message about a level the user is still looking at.
    func testASuccessElsewhereDoesNotClearAnotherLevelsError() async {
        let (viewModel, cache) = makeViewModel()
        let parent = document(childID, title: "Broken", numchild: 1)
        cache.save([parent], for: rootID)
        MockURLProtocol.stubHandler = { [childID] request in
            if request.url?.path.contains(childID.uuidString.lowercased()) == true {
                return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
            }
            return .init(
                statusCode: 200, headers: [:],
                body: Self.listFixture([(childID, "Broken")]), error: nil)
        }
        await viewModel.toggle(parent)
        XCTAssertEqual(viewModel.errorKey, .pages_error_load)

        // A different level now loads cleanly.
        await viewModel.loadRoot()

        XCTAssertEqual(viewModel.errorKey, .pages_error_load, "the broken level is still broken")
    }

    // MARK: - Creating a page

    /// The cache is shared with the editor's Subpages list, so persisting a
    /// one-item level for a parent whose real children were never fetched hides
    /// them — in both places — until something else refetches.
    func testCreatingAPageDoesNotFabricateALevelThatWasNeverLoaded() async {
        let (viewModel, cache) = makeViewModel()
        MockURLProtocol.stubHandler = { [createdID] request in
            request.httpMethod == "POST"
                ? .init(
                    statusCode: 201, headers: [:],
                    body: Data(Self.documentFixture(id: createdID, title: "Untitled subpage").utf8), error: nil)
                : .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }

        let result = await viewModel.addPage(under: rootID)

        XCTAssertEqual(result?.id, createdID, "the page is still created, and handed back to navigate to")
        XCTAssertTrue(viewModel.rows.isEmpty, "an unknown level stays unknown rather than showing one invented row")
        XCTAssertNil(cache.children(for: rootID), "and nothing is written to the shared cache")
    }

    func testCreatingAPageAppendsToALevelThatIsKnown() async {
        let (viewModel, cache) = makeViewModel()
        MockURLProtocol.stubHandler = { [childID, createdID] request in
            request.httpMethod == "POST"
                ? .init(
                    statusCode: 201, headers: [:],
                    body: Data(Self.documentFixture(id: createdID, title: "Untitled subpage").utf8), error: nil)
                : .init(
                    statusCode: 200, headers: [:],
                    body: Self.listFixture([(childID, "Existing")]), error: nil)
        }
        await viewModel.loadRoot()

        _ = await viewModel.addPage(under: rootID)

        XCTAssertEqual(viewModel.rows.map(\.document.id), [childID, createdID])
        XCTAssertEqual(cache.children(for: rootID)?.map(\.id), [childID, createdID])
    }

    /// A list fetch that started before the create carries a pre-create
    /// snapshot; letting it land would drop the page the user just made.
    func testAnInFlightFetchCannotDropAJustCreatedPage() async {
        let (viewModel, cache) = makeViewModel()
        cache.save([document(childID, title: "Existing")], for: rootID)
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { [childID, createdID] request in
            log.record(request)
            if request.httpMethod == "POST" {
                return .init(
                    statusCode: 201, headers: [:],
                    body: Data(Self.documentFixture(id: createdID, title: "Untitled subpage").utf8), error: nil)
            }
            // The pre-create snapshot, held open so the create resolves first.
            return .init(
                statusCode: 200, headers: [:], body: Self.listFixture([(childID, "Existing")]), error: nil,
                delay: 0.3)
        }

        async let slowLoad: Void = viewModel.loadRoot()
        await waitUntil { log.count(ofMethod: "GET") == 1 }
        _ = await viewModel.addPage(under: rootID)
        await slowLoad

        XCTAssertEqual(
            viewModel.rows.map(\.document.id), [childID, createdID],
            "the stale snapshot must not overwrite the level the create added to")
    }

    /// The mutation stamp defends an append we actually made. Bumping it on a
    /// create that *declined* to append (unknown level) would block the in-flight
    /// fetch too — and then neither writer fills the level, so a document that
    /// just got its first child reads as "No subpages yet".
    func testACreateIntoAnUnknownLevelStillLetsTheFetchLand() async {
        let (viewModel, cache) = makeViewModel()
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { [childID, createdID] request in
            log.record(request)
            if request.httpMethod == "POST" {
                return .init(
                    statusCode: 201, headers: [:],
                    body: Data(Self.documentFixture(id: createdID, title: "Untitled subpage").utf8), error: nil)
            }
            return .init(
                statusCode: 200, headers: [:], body: Self.listFixture([(childID, "From the server")]), error: nil,
                delay: 0.3)
        }

        // Nothing cached: this fetch is the only thing that can populate the level.
        async let coldLoad: Void = viewModel.loadRoot()
        await waitUntil { log.count(ofMethod: "GET") == 1 }
        _ = await viewModel.addPage(under: rootID)
        await coldLoad

        XCTAssertEqual(
            viewModel.rows.map(\.document.id), [childID],
            "the level is populated from the server rather than left unknown")
        XCTAssertNotNil(cache.children(for: rootID))
    }

    /// The view model outlives the drawer (it is `@State` on the editor), so a
    /// failed create must not keep reporting itself over later openings that
    /// never tried to create anything.
    func testReopeningTheDrawerClearsAStaleCreateError() async {
        let (viewModel, _) = makeViewModel()
        MockURLProtocol.stubHandler = { [childID] request in
            request.httpMethod == "POST"
                ? .init(statusCode: 500, headers: [:], body: Data(), error: nil)
                : .init(
                    statusCode: 200, headers: [:],
                    body: Self.listFixture([(childID, "Child")]), error: nil)
        }
        _ = await viewModel.addPage(under: rootID)
        XCTAssertEqual(viewModel.errorKey, .pages_error_create)

        // The drawer is opened again, which re-runs `loadRoot`.
        await viewModel.loadRoot()

        XCTAssertNil(viewModel.errorKey)
    }

    // MARK: - Duplicate work

    func testASecondExpandWhileOneIsInFlightDoesNotRefetch() async {
        let (viewModel, _) = makeViewModel()
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { [childID] request in
            log.record(request)
            return .init(
                statusCode: 200, headers: [:], body: Self.listFixture([(childID, "Child")]), error: nil,
                delay: 0.2)
        }

        async let first: Void = viewModel.loadRoot()
        await waitUntil { viewModel.loading.contains(self.rootID) }
        await viewModel.loadRoot()
        await first

        XCTAssertEqual(log.methods.count, 1, "the in-flight guard collapses the second call")
    }

    // MARK: - Pages under a document created on this device

    /// The drawer's root can be a document the server has never seen. Creating under it must
    /// issue nothing: the POST would address `documents/{local-uuid}/children/` and take a
    /// non-retryable 404, so the transport fallback could not catch it.
    func testAddingAPageUnderALocalRootMintsLocallyWithoutAnyRequest() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 404, headers: [:], body: Data(), error: nil)
        }
        let env = makeLocalRootViewModel()

        let created = await env.viewModel.addPage(under: env.root.id)

        XCTAssertNotNil(created)
        XCTAssertEqual(log.methods.count, 0)
        XCTAssertNil(env.viewModel.createErrorKey)
        XCTAssertEqual(
            env.coordinator.pendingCreateForTesting(localID: created!.id)?.parentID, env.root.id)
        XCTAssertEqual(env.viewModel.rows.map(\.document.id), [created!.id], "and it shows in the tree")
    }

    /// The gap this closes: the row is merged in at **read** time, so it survives the view
    /// model being rebuilt — which is what happens every time the editor screen is recreated.
    func testALocalPageSurvivesAViewModelRecreation() async {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 404, headers: [:], body: Data(), error: nil) }
        let env = makeLocalRootViewModel()
        let created = await env.viewModel.addPage(under: env.root.id)

        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let signedIn = SignedInUserStore(userDefaults: defaults)
        let rebuilt = PagesTreeViewModel(
            rootID: env.root.id, client: client, cache: env.cache, userDefaults: defaults,
            saveCoordinator: env.coordinator, signedInUser: signedIn)

        XCTAssertEqual(rebuilt.rows.map(\.document.id), [created!.id])
    }

    /// And a *successful* level fetch, which replaces the level wholesale with an answer that
    /// cannot mention a document the server has never seen.
    func testALocalPageSurvivesALevelRefetch() async {
        let env = makeLocalRootViewModel()
        // A page created under a **synced** parent, since a local root is never fetched at all.
        let syncedParent = UUID()
        let local = env.coordinator.createLocalDocument(
            title: "Local", parentID: syncedParent,
            ownerUserID: env.coordinator.pendingCreateForTesting(
                localID: env.root.id)!.ownerUserID!)
        MockURLProtocol.stubHandler = { [childID] _ in
            .init(statusCode: 200, headers: [:], body: Self.listFixture([(childID, "From the server")]), error: nil)
        }
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let signedIn = SignedInUserStore(userDefaults: defaults)
        let viewModel = PagesTreeViewModel(
            rootID: syncedParent, client: client, cache: env.cache, userDefaults: defaults,
            saveCoordinator: env.coordinator, signedInUser: signedIn)

        await viewModel.loadRoot()

        XCTAssertEqual(
            Set(viewModel.rows.map(\.document.id)), [childID, local.id],
            "the fetched level is the server's, and the local page is merged back on top")
        XCTAssertEqual(
            env.cache.children(for: syncedParent)?.map(\.id), [childID],
            "and the synthetic never reaches the shared cache")
    }

    /// The drawer's twin of the editor's stale-row bug. A page created offline under a
    /// **synced** parent — the transport-fallback shape — used to be appended into the loaded
    /// level, where nothing could take it back out: `mergedChildren` returns `children`
    /// untouched once the record dies, so deleting the page left its row in the tree pointing
    /// at an id no record names. It reaches the tree through the merge instead.
    func testDeletingAnOfflineFallbackPageRemovesItsDrawerRow() async {
        let env = makeLocalRootViewModel()
        let syncedParent = UUID()
        let ownerUserID = env.coordinator.pendingCreateForTesting(localID: env.root.id)!.ownerUserID!
        // A *known* level — the shape where the old code appended, and the only one where this
        // can fail. With an unknown level the append block declined anyway.
        MockURLProtocol.stubHandler = { [childID] _ in
            .init(statusCode: 200, headers: [:], body: Self.listFixture([(childID, "From the server")]), error: nil)
        }
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let signedIn = SignedInUserStore(userDefaults: defaults)
        signedIn.remember(ownerUserID)
        let viewModel = PagesTreeViewModel(
            rootID: syncedParent, client: client, cache: env.cache, userDefaults: defaults,
            saveCoordinator: env.coordinator, signedInUser: signedIn)
        await viewModel.loadRoot()

        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        let created = await viewModel.addPage(under: syncedParent)
        XCTAssertNotNil(created)
        XCTAssertNil(viewModel.createErrorKey, "kept on the device, not reported")
        XCTAssertEqual(
            Set(viewModel.rows.map(\.document.id)), [childID, created!.id],
            "precondition: the merge puts it in the tree")
        XCTAssertEqual(
            env.cache.children(for: syncedParent)?.map(\.id), [childID],
            "and the synthetic never reaches the shared cache")

        env.coordinator.discardPendingWork(documentID: created!.id)

        XCTAssertEqual(
            viewModel.rows.map(\.document.id), [childID], "the row goes with the record")
    }

    /// The drawer annotates too, so a page deleted from its own screen stops looking alive
    /// here — and taps into the undo instead of opening.
    func testAPageIsAnnotatedOnceItsDeletionIsQueued() async {
        let env = makeLocalRootViewModel()
        let owner = env.coordinator.pendingCreateForTesting(localID: env.root.id)!.ownerUserID!
        let page = document(UUID(), title: "Doomed")
        XCTAssertFalse(env.viewModel.isDeletePending(page))

        env.coordinator.recordPendingDelete(documentID: page.id, ownerUserID: owner)

        XCTAssertTrue(env.viewModel.isDeletePending(page))

        env.coordinator.cancelPendingDelete(documentID: page.id)
        XCTAssertFalse(env.viewModel.isDeletePending(page), "and the undo takes it off again")
    }

    /// The drawer is the fifth surface that strikes rows, so it owes the same drop when the
    /// deletion lands — and its hazard is the sharpest: this view model outlives the drawer,
    /// and a non-root level is refetched only when its node is toggled, so a reopened drawer
    /// would show the row again, **un-struck**, indefinitely.
    func testALandedDeletionTakesThePageOutOfTheTree() async {
        let env = makeLocalRootViewModel()
        let owner = env.coordinator.pendingCreateForTesting(localID: env.root.id)!.ownerUserID!
        let doomed = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
        MockURLProtocol.stubHandler = { [doomed] _ in
            .init(statusCode: 200, headers: [:], body: Self.listFixture([(doomed, "Doomed")]), error: nil)
        }
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let signedIn = SignedInUserStore(userDefaults: defaults)
        signedIn.remember(owner)
        let syncedParent = UUID()
        let viewModel = PagesTreeViewModel(
            rootID: syncedParent, client: client, cache: env.cache, userDefaults: defaults,
            saveCoordinator: env.coordinator, signedInUser: signedIn)
        await viewModel.loadRoot()
        env.coordinator.recordPendingDelete(documentID: doomed, ownerUserID: owner)
        XCTAssertTrue(viewModel.isDeletePending(viewModel.rows[0].document), "precondition: struck through")

        env.coordinator.announceDocumentDeletedForTesting(doomed)

        XCTAssertEqual(viewModel.rows.map(\.document.id), [], "the row leaves rather than un-striking")
    }

    /// Without a coordinator the predicate answers false rather than trapping.
    func testAPageIsNeverAnnotatedWithoutACoordinator() {
        let (viewModel, _) = makeViewModel()

        XCTAssertFalse(viewModel.isDeletePending(document(UUID(), title: "Doc")))
    }

    /// A synthetic carries `numchild: 0` — it has no server bookkeeping at all — so without
    /// the loaded-level half of the rule a local page with local pages inside it draws as a
    /// leaf, with no way to open it.
    func testALocalPageWithItsOwnPagesGetsADisclosureAndExpandsWithoutAFetch() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 404, headers: [:], body: Data(), error: nil)
        }
        let env = makeLocalRootViewModel()
        let page = await env.viewModel.addPage(under: env.root.id)
        let nested = await env.viewModel.addPage(under: page!.id)

        // Creating under a page expands it, so both are on screen already.
        XCTAssertEqual(env.viewModel.rows.map(\.document.id), [page!.id, nested!.id])
        XCTAssertEqual(env.viewModel.rows.map(\.depth), [0, 1])
        XCTAssertEqual(env.viewModel.rows.first?.hasChildren, true, "and it keeps its arrow when collapsed")

        await env.viewModel.toggle(page!)
        XCTAssertEqual(env.viewModel.rows.map(\.document.id), [page!.id], "collapsing hides what is inside it")

        await env.viewModel.toggle(page!)

        XCTAssertEqual(env.viewModel.rows.map(\.document.id), [page!.id, nested!.id], "and expanding brings it back")
        XCTAssertEqual(log.methods.count, 0, "no level under a client-minted id is ever fetched")
        XCTAssertTrue(env.viewModel.failedLoads.isEmpty)
    }

    /// A level whose only children are this device's own gets the same silence a cached level
    /// gets. Collapsing it would hide a page the user created here — while an error about a
    /// level that is showing its contents is simply wrong. Reachable the ordinary way a
    /// sub-page is created at all: offline, under a synced document.
    func testAFailedFetchKeepsALevelWhoseOnlyChildrenAreLocal() async {
        let env = makeLocalRootViewModel()
        let syncedParent = UUID()
        let owner = env.coordinator.pendingCreateForTesting(localID: env.root.id)!.ownerUserID!
        let local = env.coordinator.createLocalDocument(
            title: "Local", parentID: syncedParent, ownerUserID: owner)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let signedIn = SignedInUserStore(userDefaults: defaults)
        let viewModel = PagesTreeViewModel(
            rootID: syncedParent, client: client, cache: env.cache, userDefaults: defaults,
            saveCoordinator: env.coordinator, signedInUser: signedIn)

        await viewModel.loadRoot()

        XCTAssertEqual(viewModel.rows.map(\.document.id), [local.id], "the local page still renders")
        XCTAssertNil(viewModel.errorKey, "and a level that is showing its contents is not an error")
        XCTAssertTrue(viewModel.failedLoads.isEmpty)
    }

    /// Minting needs an account to attribute the record to; without one it would be listed by
    /// nothing and replayed by nothing.
    func testAddingAPageUnderALocalRootReportsWhenNoAccountIsKnown() async {
        let env = makeLocalRootViewModel(signedInUserID: nil)

        let created = await env.viewModel.addPage(under: env.root.id)

        XCTAssertNil(created)
        XCTAssertEqual(env.viewModel.createErrorKey, .pages_error_create)
    }
}
