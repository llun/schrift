import XCTest

@testable import Schrift

@MainActor
final class EditorViewModelChildrenTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!

    private var cacheDirectory: URL!
    private var childrenCache: DocumentChildrenCacheStore!
    private var childrenSuiteName: String!
    /// The per-view-model suites, cleaned up so each test leaves no plist behind.
    private var suiteNames: [String] = []

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorViewModelChildrenTests.\(UUID().uuidString)", isDirectory: true)
        childrenSuiteName = "EditorViewModelChildrenTests.children.\(UUID().uuidString)"
        childrenCache = DocumentChildrenCacheStore(userDefaults: UserDefaults(suiteName: childrenSuiteName)!)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: cacheDirectory)
        UserDefaults(suiteName: childrenSuiteName)?.removePersistentDomain(forName: childrenSuiteName)
        for name in suiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    private func makeViewModel(title: String = "Untitled document") -> EditorViewModel {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let suiteName = "EditorViewModelChildrenTests.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        let draftStore = PendingDraftStore(userDefaults: defaults)
        let contentCache = DocumentContentCacheStore(directory: cacheDirectory)
        // **Every** store on this test's own suite, not just the draft store. A coordinator
        // whose createStore/deleteStore/listCache fall back to `UserDefaults.standard` writes
        // app-wide storage — and since this PR a sub-page delete routes through
        // `completeImmediateDelete` → `purgeLocalTraces`, which *writes* the list and children
        // caches and reads the create store, so the half-isolated form now genuinely leaks.
        // See `PagesTreeViewModelTests.makeLocalRootViewModel` for the same reasoning.
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: draftStore, contentCache: contentCache,
            createStore: PendingDocumentCreateStore(userDefaults: defaults),
            deleteStore: PendingDocumentDeleteStore(userDefaults: defaults),
            listCache: DocumentCacheStore(userDefaults: defaults),
            childrenCache: childrenCache, backgroundTasks: .noop)
        return EditorViewModel(
            client: client, documentID: documentID, title: title, saveCoordinator: coordinator,
            signedInUser: SignedInUserStore(userDefaults: defaults),
            contentCache: contentCache, childrenCache: childrenCache)
    }

    private static func childrenFixture(id: String, title: String) -> Data {
        """
        {
            "count": 1,
            "next": null,
            "previous": null,
            "results": [
                {
                    "id": "\(id)",
                    "title": "\(title)",
                    "excerpt": null,
                    "abilities": {},
                    "computed_link_reach": "restricted",
                    "computed_link_role": null,
                    "created_at": "2026-01-15T10:30:00Z",
                    "creator": null,
                    "depth": 2,
                    "link_role": "reader",
                    "link_reach": "restricted",
                    "numchild": 0,
                    "path": "00010001",
                    "updated_at": "2026-01-15T10:30:00Z",
                    "user_role": "owner",
                    "is_favorite": false
                }
            ]
        }
        """.data(using: .utf8)!
    }

    func testLoadChildrenPopulatesSubpages() async {
        let viewModel = makeViewModel()
        let body = Self.childrenFixture(id: "11111111-1111-4111-8111-111111111111", title: "Meeting notes")
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }

        await viewModel.loadChildren()

        XCTAssertEqual(viewModel.subpages?.map(\.title), ["Meeting notes"])
    }

    func testLoadChildrenFailureLeavesSubpagesNil() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.loadChildren()

        XCTAssertNil(viewModel.subpages, "failed fetch: not fetched, not 'none'")
    }

    func testLoadPopulatesSubpages() async {
        let viewModel = makeViewModel()
        let contentBody = """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "Body", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
            """.data(using: .utf8)!
        let childrenBody = Self.childrenFixture(id: "22222222-2222-4222-8222-222222222222", title: "Child page")
        MockURLProtocol.stubHandler = { request in
            let path = request.url?.path ?? ""
            if path.contains("children") {
                return .init(statusCode: 200, headers: [:], body: childrenBody, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: contentBody, error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.subpages?.map(\.title), ["Child page"])
        // Content actually landed on screen (install sets lastSyncedAt from the fetch).
        XCTAssertNotNil(viewModel.lastSyncedAt)
    }

    private func decodeChild(id: String, title: String) -> Document {
        try! JSONDecoder.docsAPI
            .decode(PaginatedResponse<Document>.self, from: Self.childrenFixture(id: id, title: title))
            .results[0]
    }

    func testLoadSeedsSubpagesFromChildrenCacheWhenOffline() async {
        let cached = decodeChild(id: "33333333-3333-4333-8333-333333333333", title: "Cached child")
        childrenCache.save([cached], for: documentID)
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.load()

        XCTAssertEqual(viewModel.subpages?.map(\.title), ["Cached child"])
    }

    func testLoadChildrenWritesThroughToCache() async {
        let viewModel = makeViewModel()
        let body = Self.childrenFixture(id: "44444444-4444-4444-8444-444444444444", title: "Fetched child")
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }

        await viewModel.loadChildren()

        XCTAssertEqual(childrenCache.children(for: documentID)?.map(\.title), ["Fetched child"])
    }

    func testAddSubpageAppendsAndPersists() async {
        let existing = decodeChild(id: "55555555-5555-4555-8555-555555555555", title: "Existing child")
        childrenCache.save([existing], for: documentID)
        let viewModel = makeViewModel()
        await viewModel.load()  // seeds subpages from the cache (stub not set: request fails)
        let createdBody = """
            {
                "id": "66666666-6666-4666-8666-666666666666",
                "title": "Untitled subpage",
                "excerpt": null,
                "abilities": {},
                "computed_link_reach": "restricted",
                "computed_link_role": null,
                "created_at": "2026-01-15T10:30:00Z",
                "creator": null,
                "depth": 2,
                "link_role": "reader",
                "link_reach": "restricted",
                "numchild": 0,
                "path": "00010002",
                "updated_at": "2026-01-15T10:30:00Z",
                "user_role": "owner",
                "is_favorite": false
            }
            """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 201, headers: [:], body: createdBody, error: nil) }

        let child = await viewModel.addSubpage()

        XCTAssertEqual(child?.title, "Untitled subpage")
        XCTAssertEqual(viewModel.subpages?.map(\.title), ["Existing child", "Untitled subpage"])
        XCTAssertEqual(childrenCache.children(for: documentID)?.map(\.title), ["Existing child", "Untitled subpage"])
    }

    func testAddSubpageWithUnknownChildrenDoesNotFabricateCacheEntry() async {
        // subpages == nil (never fetched, never cached): persisting
        // [newChild] would durably hide the document's real children.
        let viewModel = makeViewModel()
        let createdBody = """
            {
                "id": "99999999-9999-4999-8999-999999999999",
                "title": "Untitled subpage",
                "excerpt": null,
                "abilities": {},
                "computed_link_reach": "restricted",
                "computed_link_role": null,
                "created_at": "2026-01-15T10:30:00Z",
                "creator": null,
                "depth": 2,
                "link_role": "reader",
                "link_reach": "restricted",
                "numchild": 0,
                "path": "00010003",
                "updated_at": "2026-01-15T10:30:00Z",
                "user_role": "owner",
                "is_favorite": false
            }
            """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 201, headers: [:], body: createdBody, error: nil) }

        let child = await viewModel.addSubpage()

        XCTAssertEqual(child?.title, "Untitled subpage")
        XCTAssertNil(viewModel.subpages)
        XCTAssertNil(childrenCache.children(for: documentID))
    }

    func testDeletePurgesChildrenCache() async {
        let cached = decodeChild(id: "77777777-7777-4777-8777-777777777777", title: "Doomed child")
        childrenCache.save([cached], for: documentID)
        let viewModel = makeViewModel()

        viewModel.handleDidDelete()

        XCTAssertNil(childrenCache.children(for: documentID))
    }

    func testDeleteStripsDocumentFromItsParentsCachedList() async {
        // The deleted document must not survive as a ghost child inside its
        // parent's cached list (offline never gets a revalidation to fix it).
        let parentID = UUID(uuidString: "aaaaaaaa-1111-4aaa-8aaa-aaaaaaaaaaaa")!
        let sibling = decodeChild(id: "bbbbbbbb-1111-4bbb-8bbb-bbbbbbbbbbbb", title: "Sibling")
        let doomed = decodeChild(id: documentID.uuidString.lowercased(), title: "Doomed")
        childrenCache.save([sibling, doomed], for: parentID)
        let viewModel = makeViewModel()

        viewModel.handleDidDelete()

        XCTAssertEqual(childrenCache.children(for: parentID)?.map(\.title), ["Sibling"])
    }

    func testNotFoundRevalidationPurgesChildrenCache() async {
        let cached = decodeChild(id: "88888888-8888-4888-8888-888888888888", title: "Revoked child")
        childrenCache.save([cached], for: documentID)
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 404, headers: [:], body: Data(), error: nil) }

        await viewModel.load()

        XCTAssertNil(childrenCache.children(for: documentID))
        XCTAssertNil(viewModel.subpages)
    }

    func testNotFoundRevalidationStripsDocumentFromParentsCachedLists() async {
        // A revoked/remotely-deleted document must not survive as a ghost
        // child in its parent's cached list — offline never revalidates it.
        let parentID = UUID(uuidString: "cccccccc-2222-4ccc-8ccc-cccccccccccc")!
        let sibling = decodeChild(id: "dddddddd-2222-4ddd-8ddd-dddddddddddd", title: "Sibling")
        let doomed = decodeChild(id: documentID.uuidString.lowercased(), title: "Revoked")
        childrenCache.save([sibling, doomed], for: parentID)
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 404, headers: [:], body: Data(), error: nil) }

        await viewModel.load()

        XCTAssertEqual(childrenCache.children(for: parentID)?.map(\.title), ["Sibling"])
    }

    func testChildrenSnapshotLandingAfterDeletePurgeIsDiscarded() async {
        // A children fetch that started before the delete must not land
        // afterwards and re-cache the purged entry (undoing the purge).
        let existing = decodeChild(id: "abababab-2222-4aba-8aba-abababababab", title: "Existing child")
        childrenCache.save([existing], for: documentID)
        let viewModel = makeViewModel()
        let staleChildren = Self.childrenFixture(id: "abababab-2222-4aba-8aba-abababababab", title: "Existing child")
        let recorder = RequestRecorder()
        let gate = DispatchSemaphore(value: 0)
        MockURLProtocol.stubHandler = { request in
            recorder.record(request)
            gate.wait()  // hold the snapshot until after the purge
            return .init(statusCode: 200, headers: [:], body: staleChildren, error: nil)
        }

        let staleFetch = Task { await viewModel.loadChildren() }
        await waitUntil { recorder.methods.count >= 1 }  // snapshot in flight

        viewModel.handleDidDelete()
        XCTAssertNil(childrenCache.children(for: documentID))

        gate.signal()
        await staleFetch.value

        XCTAssertNil(
            childrenCache.children(for: documentID),
            "a stale snapshot must not resurrect the purged entry")
    }

    func testAddSubpageInvalidatesInFlightChildrenFetches() async {
        // The discard mechanics for a superseded snapshot are pinned by
        // testChildrenSnapshotLandingAfterDeletePurgeIsDiscarded (whose
        // superseding call needs no network). A live create racing a held
        // fetch can't be simulated — MockURLProtocol serializes requests per
        // session — so this pins the other half directly: a successful create
        // advances the generation those mechanics key on.
        let existing = decodeChild(id: "eeeeeeee-2222-4eee-8eee-eeeeeeeeeeee", title: "Existing child")
        childrenCache.save([existing], for: documentID)
        let viewModel = makeViewModel()
        await viewModel.load()  // seeds subpages from the cache (content fetch fails: stub not set)
        let generationBefore = viewModel.childrenGeneration

        let createdBody = """
            {
                "id": "ffffffff-2222-4fff-8fff-ffffffffffff",
                "title": "Untitled subpage",
                "excerpt": null,
                "abilities": {},
                "computed_link_reach": "restricted",
                "computed_link_role": null,
                "created_at": "2026-01-15T10:30:00Z",
                "creator": null,
                "depth": 2,
                "link_role": "reader",
                "link_reach": "restricted",
                "numchild": 0,
                "path": "00010004",
                "updated_at": "2026-01-15T10:30:00Z",
                "user_role": "owner",
                "is_favorite": false
            }
            """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 201, headers: [:], body: createdBody, error: nil) }

        let child = await viewModel.addSubpage()

        XCTAssertEqual(child?.title, "Untitled subpage")
        XCTAssertEqual(viewModel.childrenGeneration, generationBefore + 1)
    }

    // MARK: - Failure reporting

    /// Before this, `addSubpage()` swallowed every error with `try?` and set no message, so
    /// tapping "New page" against a rejecting server did nothing at all, visibly.
    func testFailedAddSubpageSurfacesAnErrorMessage() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 403, headers: [:], body: Data(), error: nil) }

        let child = await viewModel.addSubpage()

        XCTAssertNil(child)
        XCTAssertEqual(viewModel.errorKey, .editor_error_add_subpage)
    }

    /// A rejected sub-page must not tear the open document down the way a 403 on load does.
    func testFailedAddSubpageLeavesTheDocumentAvailable() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 403, headers: [:], body: Data(), error: nil) }

        _ = await viewModel.addSubpage()

        XCTAssertFalse(viewModel.isUnavailable)
    }

    // `nonisolated`: read from inside the `@Sendable` stub handler, which does not run on
    // the main actor this test class is isolated to.
    private nonisolated static func childFixture(id: String, title: String) -> Data {
        """
        {
            "id": "\(id)",
            "title": "\(title)",
            "excerpt": null,
            "abilities": {},
            "computed_link_reach": "restricted",
            "computed_link_role": null,
            "created_at": "2026-01-15T10:30:00Z",
            "creator": null,
            "depth": 2,
            "link_role": "reader",
            "link_reach": "restricted",
            "numchild": 0,
            "path": "00010004",
            "updated_at": "2026-01-15T10:30:00Z",
            "user_role": "owner",
            "is_favorite": false
        }
        """.data(using: .utf8)!
    }

    func testSuccessfulAddSubpageClearsAPreviousErrorMessage() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 403, headers: [:], body: Data(), error: nil) }
        _ = await viewModel.addSubpage()
        XCTAssertNotNil(viewModel.errorKey)

        MockURLProtocol.stubHandler = { _ in
            .init(
                statusCode: 201, headers: [:],
                body: Self.childFixture(id: "44444444-4444-4444-8444-444444444444", title: "Untitled subpage"),
                error: nil)
        }

        let child = await viewModel.addSubpage()

        XCTAssertEqual(child?.title, "Untitled subpage")
        XCTAssertNil(viewModel.errorKey)
    }

    // MARK: - Swipe-to-delete on a sub-page

    private func childDocument(_ id: UUID) -> Document {
        Document(
            id: id, title: "Child page", excerpt: nil, abilities: DocumentAbilities(),
            linkReach: .restricted, linkRole: .reader, isFavorite: false, depth: 2, numchild: 0,
            path: "00010001", createdAt: Date(), updatedAt: Date(), userRole: nil, creator: nil)
    }

    /// The row is dropped by `noteDocumentDeleted` — registered in `init` — not by
    /// `deleteSubpage` reaching into `subpages`.
    func testDeletingASubpageRemovesItFromTheList() async {
        let viewModel = makeViewModel()
        let child = childDocument(UUID(uuidString: "77777777-7777-4777-8777-777777777777")!)
        viewModel.subpages = [child]
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 204, headers: [:], body: Data(), error: nil) }

        await viewModel.deleteSubpage(child)

        XCTAssertEqual(viewModel.subpages ?? [], [])
        XCTAssertNil(viewModel.errorKey)
    }

    /// **Invariant 0b.** A `listChildren` issued before the DELETE still names the sub-page and
    /// would write it back into `subpages` *and* re-create the children-cache entry the purge
    /// just dropped — a tappable row for a deleted document, restored durably on disk.
    func testASubpageDeleteInvalidatesAChildrenFetchAlreadyInFlight() async {
        let viewModel = makeViewModel()
        let childID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
        let child = childDocument(childID)
        viewModel.subpages = [child]
        let body = Self.childrenFixture(id: childID.uuidString.lowercased(), title: "Child page")
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            if request.httpMethod == "DELETE" {
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
            }
            log.record(request)
            return .init(statusCode: 200, headers: [:], body: body, error: nil, delay: 0.2)
        }

        let loading = Task { await viewModel.loadChildren() }
        // **Ordered on the recorder, not a sleep.** The children fetch must have reached the
        // stub — and be held open — before the delete, or it resolves first and the assertion
        // below is vacuous (`subpages` ends empty either way).
        await waitUntil { log.count(ofMethod: "GET") >= 1 }
        await viewModel.deleteSubpage(child)
        await loading.value

        XCTAssertEqual(
            viewModel.subpages ?? [], [],
            "the stale children fetch must not restore the deleted row")
    }

    func testAFailedSubpageDeleteReportsAndKeepsTheRow() async {
        let viewModel = makeViewModel()
        let child = childDocument(UUID(uuidString: "77777777-7777-4777-8777-777777777777")!)
        viewModel.subpages = [child]
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 403, headers: [:], body: Data(), error: nil) }

        await viewModel.deleteSubpage(child)

        XCTAssertEqual(viewModel.subpages?.map(\.id), [child.id])
        XCTAssertEqual(viewModel.errorKey, .options_error_delete)
    }

    /// A screen already torn down has a stale list by construction — the same reasoning
    /// `addSubpage`'s guards give from the other direction.
    func testASubpageDeleteIsRefusedOnADiscardedParent() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        let viewModel = makeViewModel()
        let child = childDocument(UUID(uuidString: "77777777-7777-4777-8777-777777777777")!)
        viewModel.subpages = [child]
        viewModel.handleDidDelete()

        await viewModel.deleteSubpage(child)

        XCTAssertEqual(log.count(ofMethod: "DELETE"), 0)
    }

    // MARK: - Landed moves

    private func subpage(id: UUID, title: String = "Sub-page") -> Document {
        Document(
            id: id, title: title, excerpt: nil, abilities: DocumentAbilities(), linkReach: .restricted,
            linkRole: .reader, computedLinkReach: nil, computedLinkRole: nil, isFavorite: false,
            depth: 2, numchild: 0, path: "00010001", createdAt: Date(), updatedAt: Date(),
            userRole: .owner, creator: nil)
    }

    func testASubpageMovedAwayLeavesTheSubpagesList() {
        let viewModel = makeViewModel()
        let child = subpage(id: UUID())
        viewModel.subpages = [child]

        viewModel.saveCoordinator.announceDocumentMovedForTesting(
            DocumentMoveEvent(documentID: child.id, row: child, newParentID: UUID()))

        XCTAssertEqual(viewModel.subpages, [])
    }

    /// Home's feed is unfiltered, so a document promoted while its row is already on a list is
    /// an ordinary case — and a duplicate id in a `ForEach` is undefined row identity.
    func testADocumentAlreadyInSubpagesMovedInAgainIsNotDuplicated() {
        let viewModel = makeViewModel()
        let arriving = subpage(id: UUID(), title: "Arriving")
        viewModel.subpages = [arriving]

        viewModel.saveCoordinator.announceDocumentMovedForTesting(
            DocumentMoveEvent(documentID: arriving.id, row: arriving, newParentID: documentID))

        XCTAssertEqual(viewModel.subpages?.filter { $0.id == arriving.id }.count, 1)
    }

    func testADocumentMovedIntoThisOneJoinsTheSubpagesList() {
        let viewModel = makeViewModel()
        viewModel.subpages = []
        let arriving = subpage(id: UUID(), title: "Arriving")

        viewModel.saveCoordinator.announceDocumentMovedForTesting(
            DocumentMoveEvent(documentID: arriving.id, row: arriving, newParentID: documentID))

        XCTAssertEqual(viewModel.subpages?.map(\.id), [arriving.id])
    }

    /// nil means the level was never fetched, which is not the same as "fetched and empty" —
    /// the Subpages section reads exactly that difference.
    func testADocumentMovedInDoesNotFabricateANeverFetchedSubpagesList() {
        let viewModel = makeViewModel()
        XCTAssertNil(viewModel.subpages, "precondition")
        let arriving = subpage(id: UUID(), title: "Arriving")

        viewModel.saveCoordinator.announceDocumentMovedForTesting(
            DocumentMoveEvent(documentID: arriving.id, row: arriving, newParentID: documentID))

        XCTAssertNil(viewModel.subpages)
    }

    /// **Moving the document this editor is showing changes nothing here.** Its content, its
    /// drafts and its saves are all keyed by an id that has not moved, and the screen models
    /// no parent — so unlike a deletion, there is nothing to tear down.
    ///
    /// The teardown flags are checked, but they are not what makes this test bite: no branch
    /// of `noteDocumentMoved` can set them, so they pass with the early return deleted. What
    /// pins the guard is the **children fetch**, which the guard is what spares — without it
    /// the generation bump discards a perfectly good in-flight fetch of this document's own
    /// sub-pages, which is the mirror image of the sibling test below.
    func testMovingTheOpenDocumentSparesItsOwnChildrenFetch() async {
        let childID = UUID(uuidString: "9C2C2C2C-2C2C-4C2C-8C2C-2C2C2C2C2C2C")!
        let gate = MockURLProtocol.ResponseGate()
        let body = Self.childrenFixture(id: childID.uuidString.lowercased(), title: "Sub-page")
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: body, error: nil, releasedBy: gate)
        }
        let viewModel = makeViewModel()

        async let load: Void = viewModel.loadChildren()
        await waitUntil { MockURLProtocol.deferredDeliveryCount > 0 }
        // This document moves — not one of its sub-pages.
        viewModel.saveCoordinator.announceDocumentMovedForTesting(
            DocumentMoveEvent(
                documentID: documentID, row: subpage(id: documentID), newParentID: UUID()))
        gate.open()
        await load

        XCTAssertEqual(
            viewModel.subpages?.map(\.id), [childID],
            "the fetch is about this document's children, which a move of the document does not disturb")
        XCTAssertEqual(childrenCache.children(for: documentID)?.map(\.id), [childID])
        XCTAssertFalse(viewModel.isDocumentDiscarded)
        XCTAssertFalse(viewModel.isUnavailable)
        XCTAssertNil(viewModel.errorKey)
    }

    /// **Invariant 0b.** A children fetch issued before the move lands after it and still
    /// names the row; it must write neither `subpages` nor the shared children cache.
    func testAChildrenFetchInFlightWhenAMoveLandsCannotRestoreTheRow() async {
        let childID = UUID(uuidString: "9C1C1C1C-1C1C-4C1C-8C1C-1C1C1C1C1C1C")!
        let gate = MockURLProtocol.ResponseGate()
        let body = Self.childrenFixture(id: childID.uuidString.lowercased(), title: "Sub-page")
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: body, error: nil, releasedBy: gate)
        }
        let viewModel = makeViewModel()

        async let load: Void = viewModel.loadChildren()
        await waitUntil { MockURLProtocol.deferredDeliveryCount > 0 }
        viewModel.saveCoordinator.announceDocumentMovedForTesting(
            DocumentMoveEvent(
                documentID: childID, row: subpage(id: childID), newParentID: UUID()))
        gate.open()
        await load

        XCTAssertNil(viewModel.subpages, "the fetch predates the move, so its answer is discarded")
        XCTAssertNil(childrenCache.children(for: documentID), "and it must not reach the cache")
    }
}
