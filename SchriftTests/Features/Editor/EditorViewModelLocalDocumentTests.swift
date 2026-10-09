import XCTest

@testable import Schrift

@MainActor
final class EditorViewModelLocalDocumentTests: EditorViewModelTestCase {
    /// The registration is tied to `deinit` rather than to `onDisappear`, which fires on mere
    /// invisibility: this pins the release to the view model's lifetime.
    ///
    /// It calls `noteEditorAppeared` twice, but note what that does **not** prove. Deleting
    /// the idempotence `guard` leaves this green, because assigning a second token deallocates
    /// the first and that release balances the second retain — the guard avoids churn, it is
    /// not load-bearing, and the code says so. What this does pin is the token itself:
    /// removing it times the wait out.
    ///
    /// Observed on the coordinator's registry directly. Routing it through the replay would
    /// let it pass whenever the replay simply did not run — the vacuous shape this project
    /// keeps finding.
    func testTheEditorRegistrationIsIdempotentAndReleasedOnDealloc() async {
        let env = makeLocalEnvironment()
        XCTAssertFalse(env.coordinator.hasOpenEditorForTesting(documentID: env.document.id))

        do {
            let transient = EditorViewModel(
                client: env.viewModel.client, documentID: env.document.id, title: "Doc",
                saveCoordinator: env.coordinator)
            transient.noteEditorAppeared()
            transient.noteEditorAppeared()  // a repeated `onAppear` must not double-count
            XCTAssertTrue(env.coordinator.hasOpenEditorForTesting(documentID: env.document.id))
        }

        // `deinit` hops to the main actor to release, so let that turn run. Timing out here
        // means either the token was never created or the retain was counted twice.
        await waitUntil { !env.coordinator.hasOpenEditorForTesting(documentID: env.document.id) }
    }

    /// **A local sub-page must never be readable by the next account.** The children cache is
    /// neither account-scoped nor cleared on sign-out, and `load()` seeds `subpages` from it
    /// synchronously — so persisting a synthetic there hands the previous user's draft, title
    /// and body, to whoever signs in next, who can then edit or delete it.
    func testALocalSubpageIsNeverPersistedIntoTheSharedChildrenCache() async {
        let env = makeEnvironment()
        let viewModel = EditorViewModel(
            client: env.viewModel.client, documentID: documentID, title: "Doc",
            saveCoordinator: env.coordinator, signedInUser: makeSignedInUser(),
            childrenCache: DocumentChildrenCacheStore(userDefaults: UserDefaults(suiteName: childrenSuiteName)!))
        // A known level, so `appendChild` writes through at all.
        MockURLProtocol.stubHandler = { _ in
            .init(
                statusCode: 200, headers: [:],
                body: Data(#"{"count":0,"next":null,"previous":null,"results":[]}"#.utf8), error: nil)
        }
        await viewModel.loadChildren()
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        let child = await viewModel.addSubpage()

        XCTAssertNotNil(child)
        XCTAssertEqual(viewModel.mergedSubpages?.map(\.id), [child!.id], "still on screen")
        let cache = DocumentChildrenCacheStore(userDefaults: UserDefaults(suiteName: childrenSuiteName)!)
        XCTAssertEqual(
            cache.children(for: documentID)?.map(\.id), [],
            "but nothing a stranger's session could read")
    }

    /// A local sub-page must survive a successful children fetch. `appendChild` writes it
    /// into `subpages` and the cache optimistically, but `loadChildren` replaces **both**
    /// wholesale with the server's answer — which cannot contain a document the server has
    /// never seen. Without the read-time merge it simply disappears, and if its replay parks
    /// it is unreachable from every list in the app while its body sits on disk.
    func testALocalSubpageSurvivesASuccessfulChildrenFetch() async {
        let env = makeEnvironment()
        let signedIn = makeSignedInUser()
        let viewModel = EditorViewModel(
            client: env.viewModel.client, documentID: documentID, title: "Doc",
            saveCoordinator: env.coordinator, signedInUser: signedIn)
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        let child = await viewModel.addSubpage()
        XCTAssertNotNil(child)

        // The server answers with a level that knows nothing about it.
        MockURLProtocol.stubHandler = { _ in
            .init(
                statusCode: 200, headers: [:],
                body: Data(#"{"count":0,"next":null,"previous":null,"results":[]}"#.utf8), error: nil)
        }
        await viewModel.loadChildren()

        XCTAssertEqual(viewModel.subpages?.count, 0, "the fetched list is the server's, unchanged")
        XCTAssertEqual(
            viewModel.mergedSubpages?.map(\.id), [child!.id],
            "but the screen still shows the local child")
    }

    /// The fallback-minted sub-page reaches the screen through the **merge**, never through
    /// `subpages` itself. That is what makes it removable: the merge withholds it the instant
    /// its record dies, while a row pushed into the fetched array is one nothing can take back.
    func testAnOfflineSubpageNeverEntersTheFetchedChildrenArray() async {
        let env = makeEnvironment()
        let viewModel = EditorViewModel(
            client: env.viewModel.client, documentID: documentID, title: "Doc",
            saveCoordinator: env.coordinator, signedInUser: makeSignedInUser(),
            childrenCache: DocumentChildrenCacheStore(userDefaults: UserDefaults(suiteName: childrenSuiteName)!))
        // A *known* level — the shape where the old code appended, and the only one where this
        // assertion can fail. With a nil level `appendChild` declined anyway.
        MockURLProtocol.stubHandler = { _ in
            .init(
                statusCode: 200, headers: [:],
                body: Data(#"{"count":0,"next":null,"previous":null,"results":[]}"#.utf8), error: nil)
        }
        await viewModel.loadChildren()
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        let child = await viewModel.addSubpage()

        XCTAssertNotNil(child)
        XCTAssertEqual(viewModel.subpages?.map(\.id), [], "the fetched level stays the server's")
        XCTAssertEqual(viewModel.mergedSubpages?.map(\.id), [child!.id], "the merge is what shows it")
    }

    /// **The reported bug.** Deleting a sub-page created offline under an ordinary *server*
    /// parent left its row rendering under Subpages with nothing to say it was gone — and
    /// tapping it opened an editor for an id no record names. `appendChild` had pushed a
    /// synthetic into `subpages`; once the record died `mergedSubpages` short-circuits
    /// (`guard !local.isEmpty`) and hands back `subpages` unfiltered, and offline nothing
    /// refetches the level to correct it.
    func testDeletingAnOfflineSubpageUnderAServerParentRemovesItsRow() async {
        let env = makeEnvironment()
        let viewModel = EditorViewModel(
            client: env.viewModel.client, documentID: documentID, title: "Doc",
            saveCoordinator: env.coordinator, signedInUser: makeSignedInUser(),
            childrenCache: DocumentChildrenCacheStore(userDefaults: UserDefaults(suiteName: childrenSuiteName)!))
        MockURLProtocol.stubHandler = { _ in
            .init(
                statusCode: 200, headers: [:],
                body: Data(#"{"count":0,"next":null,"previous":null,"results":[]}"#.utf8), error: nil)
        }
        await viewModel.loadChildren()
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        let child = await viewModel.addSubpage()
        XCTAssertEqual(viewModel.mergedSubpages?.map(\.id), [child!.id], "precondition: on screen")

        // What `OptionsViewModel.delete()` does for a document that exists only here.
        env.coordinator.discardPendingWork(documentID: child!.id)

        XCTAssertEqual(viewModel.mergedSubpages?.map(\.id), [], "the row goes with the record")
    }

    /// **The drop must survive its own in-flight children fetch** (invariant 0b). A
    /// `listChildren` issued before the DELETE landed still names the sub-page, and on
    /// resolving would write it back into `subpages` *and* re-create the children-cache entry
    /// the coordinator just purged — a tappable row for a deleted document, restored durably
    /// on disk and surviving relaunch.
    func testALandedSubpageDeletionSurvivesAnInFlightChildrenFetch() async {
        let doomed = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
        let childrenCache = DocumentChildrenCacheStore(userDefaults: UserDefaults(suiteName: childrenSuiteName)!)
        let env = makeEnvironment()
        let viewModel = EditorViewModel(
            client: env.viewModel.client, documentID: documentID, title: "Doc",
            saveCoordinator: env.coordinator, signedInUser: makeSignedInUser(),
            childrenCache: childrenCache)
        let body = Data(
            """
            {"count":1,"next":null,"previous":null,"results":[{
              "id": "\(doomed.uuidString.lowercased())", "title": "Doomed", "excerpt": null,
              "abilities": {}, "computed_link_reach": "restricted", "computed_link_role": null,
              "created_at": "2026-01-15T10:30:00Z", "creator": null, "depth": 2,
              "link_role": "reader", "link_reach": "restricted", "numchild": 0, "path": "00010001",
              "updated_at": "2026-01-15T10:30:00Z", "user_role": "owner", "is_favorite": false}]}
            """.utf8)
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: body, error: nil, delay: 0.2)
        }

        let fetching = Task { await viewModel.loadChildren() }
        // The deletion lands while that fetch is still on the wire.
        try? await Task.sleep(for: .milliseconds(60))
        env.coordinator.announceDocumentDeletedForTesting(doomed)
        await fetching.value

        XCTAssertEqual(viewModel.subpages?.map(\.id) ?? [], [], "the stale fetch is not applied")
        XCTAssertNil(
            childrenCache.children(for: documentID),
            "and never re-creates the cache entry the deletion purged")
    }

    /// A sub-page deleted from its own screen strikes through in the parent's list the
    /// moment the user pops back — no children refetch, which offline never comes.
    func testASubpageIsAnnotatedOnceItsDeletionIsQueued() async {
        let user = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let env = makeEnvironment()
        let viewModel = EditorViewModel(
            client: env.viewModel.client, documentID: documentID, title: "Doc",
            saveCoordinator: env.coordinator, signedInUser: makeSignedInUser(userID: user))
        let child = Document(
            id: UUID(), title: "Doomed", excerpt: nil, abilities: DocumentAbilities(),
            linkReach: .restricted, linkRole: .reader, isFavorite: false, depth: 2, numchild: 0,
            path: "0002", createdAt: Date(), updatedAt: Date(), userRole: nil, creator: nil)
        XCTAssertFalse(viewModel.isDeletePending(child))

        env.coordinator.recordPendingDelete(documentID: child.id, ownerUserID: user)
        XCTAssertTrue(viewModel.isDeletePending(child))

        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: Data(), error: nil) }
        viewModel.undoPendingDelete(child)
        XCTAssertFalse(viewModel.isDeletePending(child), "and the undo takes it off again")
    }

    /// Never another account's deletion: the create/children caches outlive sign-out, so an
    /// unscoped predicate would strike one user's document through another's list.
    func testASubpageIsNeverAnnotatedForAnotherAccountsDeletion() async {
        let env = makeEnvironment()
        let viewModel = EditorViewModel(
            client: env.viewModel.client, documentID: documentID, title: "Doc",
            saveCoordinator: env.coordinator,
            signedInUser: makeSignedInUser(userID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!))
        let child = Document(
            id: UUID(), title: "Doomed", excerpt: nil, abilities: DocumentAbilities(),
            linkReach: .restricted, linkRole: .reader, isFavorite: false, depth: 2, numchild: 0,
            path: "0002", createdAt: Date(), updatedAt: Date(), userRole: nil, creator: nil)

        env.coordinator.recordPendingDelete(
            documentID: child.id, ownerUserID: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!)

        XCTAssertFalse(viewModel.isDeletePending(child))
    }

    /// A transport failure on "Add a subpage" keeps the page on the device rather than
    /// reporting an error, exactly as Home's create does.
    func testAddSubpageFallsBackToALocalChildOnATransportError() async {
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        let env = makeEnvironment()
        let signedIn = makeSignedInUser()
        let viewModel = EditorViewModel(
            client: env.viewModel.client, documentID: documentID, title: "Doc",
            saveCoordinator: env.coordinator, signedInUser: signedIn)

        let child = await viewModel.addSubpage()

        XCTAssertNotNil(child)
        XCTAssertNil(viewModel.errorKey, "kept on the device, not reported")
        XCTAssertTrue(env.coordinator.isPendingCreate(documentID: child!.id))
    }

    /// A rejection on the merits still errors: minting there would promise a replay the
    /// server will decline again.
    func testAddSubpageStillReportsARejectionOnTheMerits() async {
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 403, headers: [:], body: Data(), error: nil)
        }
        let env = makeEnvironment()
        let viewModel = EditorViewModel(
            client: env.viewModel.client, documentID: documentID, title: "Doc",
            saveCoordinator: env.coordinator, signedInUser: makeSignedInUser())

        let child = await viewModel.addSubpage()

        XCTAssertNil(child)
        XCTAssertEqual(viewModel.errorKey, .editor_error_add_subpage)
    }

    /// A sub-page of a **local** parent is minted with no request at all. Trying the POST first
    /// would address `documents/{local-uuid}/children/` and take a 404 — not retryable, so the
    /// transport fallback above would never fire and the user would be told this is impossible.
    /// The replay orders the two creates instead.
    func testAddSubpageUnderALocalParentMintsLocallyWithoutAnyRequest() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 404, headers: [:], body: Data(), error: nil)
        }
        let env = makeLocalEnvironment()

        let child = await env.viewModel.addSubpage()

        XCTAssertNotNil(child)
        XCTAssertEqual(log.methods.count, 0, "no request may name a client-minted id")
        XCTAssertNil(env.viewModel.errorKey)
        XCTAssertTrue(env.coordinator.isPendingCreate(documentID: child!.id))
        XCTAssertEqual(
            env.coordinator.pendingCreateForTesting(localID: child!.id)?.parentID, env.document.id,
            "and it is filed under the parent, which is what the replay reorders on")
        XCTAssertEqual(env.viewModel.mergedSubpages?.map(\.id), [child!.id], "and it shows immediately")
    }

    /// Nothing may be filed inside a document that has just been deleted. The screen stays
    /// interactive between the Options sheet dismissing and the pop, and offline the POST fails
    /// `.network` — so without this the fallback mints a sub-page naming a record the delete has
    /// already removed, which nothing then gates: the replay POSTs it, the probe 404s, and a
    /// document the user threw away returns as a stray root.
    func testAddSubpageDoesNothingOnceTheDocumentIsDeleted() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        let env = makeLocalEnvironment()
        env.viewModel.handleDidDelete()

        let child = await env.viewModel.addSubpage()

        XCTAssertNil(child)
        XCTAssertEqual(log.methods.count, 0, "and it does not even ask")
        // Asserted against the store, **not** `hasPendingLocalChildren`. That predicate answers
        // "would the cascade delete anything", and the delete has just removed this record — so
        // it returns false whether or not a dangling child exists, which makes it incapable of
        // failing here. Verified by reverting the guard: this line kept passing while the record
        // it names sat on disk.
        XCTAssertTrue(
            env.createStore.allCreates().allSatisfy { $0.parentID != env.document.id },
            "no record may name the parent the delete just removed")
    }

    /// Minting needs an account to attribute the record to: without one it would be listed by
    /// nothing and replayed by nothing, so saying so beats a document that silently never syncs.
    func testAddSubpageUnderALocalParentReportsWhenNoAccountIsKnown() async {
        let env = makeLocalEnvironment(signedInUserID: nil)

        let child = await env.viewModel.addSubpage()

        XCTAssertNil(child)
        XCTAssertEqual(env.viewModel.errorKey, .editor_error_add_subpage)
    }

    /// The server has never seen this document, so it provably holds nothing under it — the
    /// level is known-**empty**, not unknown. Reporting nil left the section a bare "Subpages"
    /// heading with no rows and not even the line saying there are none.
    func testALocalDocumentReportsAKnownEmptySubpagesLevel() async {
        let env = makeLocalEnvironment()

        XCTAssertEqual(env.viewModel.mergedSubpages?.count, 0)
    }

    /// A synthetic row must never reach `DocumentChildrenCacheStore`: it is neither
    /// account-scoped nor cleared on sign-out, so a level keyed by a local parent id would
    /// serve the previous user's document to the next one.
    func testAddSubpageUnderALocalParentWritesNoChildrenCacheLevel() async {
        let env = makeLocalEnvironment()

        _ = await env.viewModel.addSubpage()

        XCTAssertNil(env.children.children(for: env.document.id))
    }

    /// Opening a locally-created document must issue **no** request. Its id is client-minted,
    /// so every fetch 404s — and `revalidate`'s catch calls `becomeUnavailable`, which clears
    /// `hasLoadedContent` and leaves a document the user is writing in reading "no longer
    /// available". Nothing is lost when that happens, but the screen is unusable, which is the
    /// whole feature.
    func testOpeningALocalDocumentRendersItsDraftAndIssuesNoRequest() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 404, headers: [:], body: Data(), error: nil)
        }
        let env = makeLocalEnvironment()
        env.coordinator.enqueue(documentID: env.document.id, title: "Notes", markdown: "# Written offline")

        await env.viewModel.load()

        XCTAssertEqual(log.methods.count, 0, "no request may name a client-minted id")
        XCTAssertTrue(env.viewModel.hasLoadedContent, "and the screen is usable")
        XCTAssertFalse(env.viewModel.isUnavailable)
        XCTAssertEqual(env.viewModel.currentMarkdown(), "# Written offline")
    }

    /// Pull-to-refresh is the other way in, and it must not tear the screen down either.
    func testRefreshingALocalDocumentDoesNotTearTheScreenDown() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 404, headers: [:], body: Data(), error: nil)
        }
        let env = makeLocalEnvironment()
        env.coordinator.enqueue(documentID: env.document.id, title: "Notes", markdown: "# Written offline")
        await env.viewModel.load()

        await env.viewModel.refresh()
        await env.viewModel.loadChildren()

        XCTAssertEqual(log.methods.count, 0)
        XCTAssertFalse(env.viewModel.isUnavailable)
        XCTAssertEqual(env.viewModel.currentMarkdown(), "# Written offline")
    }
}
