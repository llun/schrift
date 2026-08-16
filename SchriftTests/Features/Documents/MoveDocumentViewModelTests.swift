import XCTest

@testable import Schrift

/// What the destination picker offers, and what it sends.
@MainActor
final class MoveDocumentViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let ownerID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let rootID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let otherRootID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let subpageID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!

    private var suiteNames: [String] = []
    private var cacheDirectories: [URL] = []

    override func tearDown() {
        for name in suiteNames { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suiteNames.removeAll()
        for directory in cacheDirectories { try? FileManager.default.removeItem(at: directory) }
        cacheDirectories.removeAll()
        MockURLProtocol.reset()
        super.tearDown()
    }

    private struct Environment {
        let client: DocsAPIClient
        let coordinator: DocumentSaveCoordinator
        let defaults: UserDefaults
        let signedIn: SignedInUserStore
    }

    private func makeEnvironment() -> Environment {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let suiteName = "MoveDocumentViewModelTests.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoveDocumentViewModelTests/\(UUID().uuidString)", isDirectory: true)
        cacheDirectories.append(cacheDirectory)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: PendingDraftStore(userDefaults: defaults),
            contentCache: DocumentContentCacheStore(directory: cacheDirectory),
            createStore: PendingDocumentCreateStore(userDefaults: defaults),
            deleteStore: PendingDocumentDeleteStore(userDefaults: defaults),
            listCache: DocumentCacheStore(userDefaults: defaults),
            childrenCache: DocumentChildrenCacheStore(userDefaults: defaults),
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)
        let signedIn = SignedInUserStore(userDefaults: defaults)
        signedIn.remember(ownerID)
        return Environment(client: client, coordinator: coordinator, defaults: defaults, signedIn: signedIn)
    }

    private func makeViewModel(
        _ env: Environment, documentID: UUID? = nil, row: Document? = nil
    ) -> MoveDocumentViewModel {
        MoveDocumentViewModel(
            client: env.client, documentID: documentID ?? self.documentID, row: row,
            saveCoordinator: env.coordinator, signedInUser: env.signedIn, userDefaults: env.defaults)
    }

    private func document(id: UUID, title: String, depth: Int) -> Document {
        Document(
            id: id, title: title, excerpt: nil, abilities: DocumentAbilities(), linkReach: .restricted,
            linkRole: .reader, computedLinkReach: nil, computedLinkRole: nil, isFavorite: false,
            depth: depth, numchild: 0, path: String(repeating: "0", count: 4 * depth),
            createdAt: Date(), updatedAt: Date(), userRole: .owner, creator: nil)
    }

    private nonisolated static func entry(id: UUID, title: String, depth: Int) -> String {
        """
        {"id": "\(id.uuidString.lowercased())", "title": "\(title)", "abilities": {}, \
        "link_reach": "restricted", "link_role": "reader", "is_favorite": false, "depth": \(depth), \
        "numchild": 0, "path": "\(String(repeating: "0", count: 4 * depth))", \
        "created_at": "2026-08-01T10:00:00Z", "updated_at": "2026-08-01T10:00:00Z"}
        """
    }

    /// The list response the picker reads its candidates from.
    private func stubList(_ entries: [String], log: RequestRecorder? = nil) {
        let body = """
            {"count": \(entries.count), "next": null, "previous": null, "results": [\(entries.joined(separator: ","))]}
            """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { request in
            log?.record(request)
            if request.url?.absoluteString.contains("/move/") == true {
                return .init(
                    statusCode: 200, headers: [:],
                    body: #"{"message": "Document moved successfully."}"#.data(using: .utf8)!, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: body, error: nil)
        }
    }

    // MARK: - What is offered

    func testOnlyTopLevelDocumentsAreOfferedAsDestinations() async {
        stubList([
            Self.entry(id: rootID, title: "Root", depth: 1),
            Self.entry(id: subpageID, title: "Sub-page", depth: 2),
        ])
        let env = makeEnvironment()
        let viewModel = makeViewModel(env)

        await viewModel.loadDestinations()

        XCTAssertEqual(viewModel.destinations.map(\.id), [rootID], "the picker offers one level")
    }

    func testTheDocumentBeingMovedIsNeverOfferedAsItsOwnDestination() async {
        stubList([
            Self.entry(id: documentID, title: "Itself", depth: 1),
            Self.entry(id: rootID, title: "Root", depth: 1),
        ])
        let env = makeEnvironment()
        let viewModel = makeViewModel(env)

        await viewModel.loadDestinations()

        XCTAssertEqual(viewModel.destinations.map(\.id), [rootID])
    }

    func testADocumentAwaitingDeletionIsNotOfferedAsADestination() async {
        stubList([
            Self.entry(id: rootID, title: "Root", depth: 1),
            Self.entry(id: otherRootID, title: "Doomed", depth: 1),
        ])
        let env = makeEnvironment()
        env.coordinator.recordPendingDelete(documentID: otherRootID, ownerUserID: ownerID)
        let viewModel = makeViewModel(env)

        await viewModel.loadDestinations()

        XCTAssertEqual(viewModel.destinations.map(\.id), [rootID])
    }

    /// A local document can be filed under another local one — the replay orders the two
    /// creates — so those are worth offering with no network at all.
    func testALocalDocumentIsOfferedTheOtherLocalRoots() async {
        stubList([])
        let env = makeEnvironment()
        let target = env.coordinator.createLocalDocument(
            title: "Local root", parentID: nil, ownerUserID: ownerID)
        let moving = env.coordinator.createLocalDocument(
            title: "Moving", parentID: nil, ownerUserID: ownerID)
        let viewModel = makeViewModel(env, documentID: moving.id, row: moving)

        await viewModel.loadDestinations()

        XCTAssertEqual(viewModel.localDestinations.map(\.id), [target.id])
    }

    /// A server document filed under a client-minted id would POST to a route that 404s, so
    /// those destinations are never offered for one.
    func testAServerDocumentIsNeverOfferedALocalDestination() async {
        stubList([Self.entry(id: rootID, title: "Root", depth: 1)])
        let env = makeEnvironment()
        _ = env.coordinator.createLocalDocument(title: "Local", parentID: nil, ownerUserID: ownerID)
        let viewModel = makeViewModel(env)

        await viewModel.loadDestinations()

        XCTAssertTrue(viewModel.localDestinations.isEmpty)
    }

    func testARootDocumentIsNotOfferedAMoveToWhereItAlreadyIs() {
        let env = makeEnvironment()
        let viewModel = makeViewModel(
            env, row: document(id: documentID, title: "Root", depth: 1))

        XCTAssertFalse(viewModel.offersHome)
    }

    func testASubPageIsOfferedAMoveToTheTopLevelOnceARootHasBeenFetched() async {
        stubList([Self.entry(id: rootID, title: "Root", depth: 1)])
        let env = makeEnvironment()
        let viewModel = makeViewModel(env, row: document(id: documentID, title: "Sub-page", depth: 2))

        await viewModel.loadDestinations()

        XCTAssertTrue(viewModel.offersHome)
    }

    /// A caller with an id but no row — the editor's Options sheet — gets the affordance once
    /// there is a root to name: a root filed beside another root is a harmless no-op if it
    /// turns out not to have been needed.
    func testACallerWithNoRowIsOfferedTheTopLevelOnceARootHasBeenFetched() async {
        stubList([Self.entry(id: rootID, title: "Root", depth: 1)])
        let env = makeEnvironment()
        let viewModel = makeViewModel(env)

        await viewModel.loadDestinations()

        XCTAssertTrue(viewModel.offersHome)
    }

    /// The Options sheet holds an id, not a row, so its depth can only come from the fetch —
    /// without which it would go on offering a root document a move to where it already is.
    func testAnOptionsSheetCallerLearnsFromTheFetchThatItIsAlreadyAtTheTopLevel() async {
        stubList([
            Self.entry(id: documentID, title: "Itself", depth: 1),
            Self.entry(id: rootID, title: "Root", depth: 1),
        ])
        let env = makeEnvironment()
        let viewModel = makeViewModel(env)

        await viewModel.loadDestinations()

        XCTAssertFalse(viewModel.offersHome)
    }

    func testAnOptionsSheetCallerOnASubPageIsStillOfferedTheTopLevel() async {
        stubList([
            Self.entry(id: documentID, title: "Itself", depth: 2),
            Self.entry(id: rootID, title: "Root", depth: 1),
        ])
        let env = makeEnvironment()
        let viewModel = makeViewModel(env)

        await viewModel.loadDestinations()

        XCTAssertTrue(viewModel.offersHome)
    }

    /// **A server document is promoted by being filed beside a root**, so with none fetched
    /// the row could only ever produce the generic move error. Reachable through Work Offline,
    /// a failed load, or a first page that happens to hold no roots.
    func testTheTopLevelIsWithheldFromAServerDocumentWhenNoRootWasFetched() async {
        stubList([])
        let env = makeEnvironment()
        let viewModel = makeViewModel(env, row: document(id: documentID, title: "Moving", depth: 2))

        await viewModel.loadDestinations()

        XCTAssertFalse(viewModel.offersHome)
    }

    /// A local document needs no target, so Work Offline still offers it the top level.
    func testALocalDocumentIsStillOfferedTheTopLevelWithNoNetwork() async {
        let env = makeEnvironment()
        env.defaults.set(true, forKey: "schrift.workOffline")
        let parent = env.coordinator.createLocalDocument(
            title: "Parent", parentID: nil, ownerUserID: ownerID)
        let moving = env.coordinator.createLocalDocument(
            title: "Moving", parentID: parent.id, ownerUserID: ownerID)
        let viewModel = makeViewModel(env, documentID: moving.id, row: moving)

        await viewModel.loadDestinations()

        XCTAssertTrue(viewModel.offersHome)
    }

    /// The body renders before `.task` runs, so an `isLoading`-only gate would flash the empty
    /// state on every open; and a failed load already says why, so saying "no destinations"
    /// underneath it would state a second, contradictory reason.
    func testTheEmptyStateWaitsForALoadAndDefersToAnError() async {
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }
        let env = makeEnvironment()
        let viewModel = makeViewModel(env, row: document(id: documentID, title: "Root", depth: 1))
        XCTAssertFalse(viewModel.isEmpty, "nothing has loaded yet")

        await viewModel.loadDestinations()

        XCTAssertEqual(viewModel.errorKey, .move_error_load)
        XCTAssertFalse(viewModel.isEmpty, "the error is the reason; two would contradict")
    }

    func testALocalDocumentAtTheTopLevelIsNotOfferedAMoveThere() {
        let env = makeEnvironment()
        let moving = env.coordinator.createLocalDocument(
            title: "Moving", parentID: nil, ownerUserID: ownerID)

        XCTAssertFalse(makeViewModel(env, documentID: moving.id, row: moving).offersHome)
    }

    func testALocalSubPageIsOfferedAMoveToTheTopLevel() {
        let env = makeEnvironment()
        let parent = env.coordinator.createLocalDocument(
            title: "Parent", parentID: nil, ownerUserID: ownerID)
        let moving = env.coordinator.createLocalDocument(
            title: "Moving", parentID: parent.id, ownerUserID: ownerID)

        XCTAssertTrue(makeViewModel(env, documentID: moving.id, row: moving).offersHome)
    }

    // MARK: - What is sent

    func testMovingUnderADestinationSendsTheChildPosition() async throws {
        let log = RequestRecorder()
        stubList([Self.entry(id: rootID, title: "Root", depth: 1)], log: log)
        let env = makeEnvironment()
        let viewModel = makeViewModel(env, row: document(id: documentID, title: "Moving", depth: 2))
        await viewModel.loadDestinations()

        await viewModel.move(under: try XCTUnwrap(viewModel.destinations.first))

        XCTAssertTrue(viewModel.didMove)
        XCTAssertNil(viewModel.errorKey)
        let body = MockURLProtocol.lastRequest.flatMap(bodyData(from:))
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        XCTAssertEqual(json?["position"], "last-child")
        XCTAssertEqual(json?["target_document_id"], rootID.uuidString.lowercased())
    }

    func testMovingToTheTopLevelTargetsAFetchedRootWithTheSiblingPosition() async {
        stubList([Self.entry(id: rootID, title: "Root", depth: 1)])
        let env = makeEnvironment()
        let viewModel = makeViewModel(env, row: document(id: documentID, title: "Moving", depth: 2))
        await viewModel.loadDestinations()

        await viewModel.moveToHome()

        XCTAssertTrue(viewModel.didMove)
        let body = MockURLProtocol.lastRequest.flatMap(bodyData(from:))
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        XCTAssertEqual(json?["position"], "last-sibling")
        XCTAssertEqual(json?["target_document_id"], rootID.uuidString.lowercased())
    }

    /// Promotion needs a root to sit beside; with none fetched there is no request to make.
    func testAServerDocumentCannotBePromotedWithNoRootToSitBeside() async {
        let log = RequestRecorder()
        stubList([], log: log)
        let env = makeEnvironment()
        let viewModel = makeViewModel(env, row: document(id: documentID, title: "Moving", depth: 2))
        await viewModel.loadDestinations()

        await viewModel.moveToHome()

        XCTAssertFalse(viewModel.didMove)
        XCTAssertEqual(viewModel.errorKey, .move_error)
        XCTAssertEqual(log.count(ofMethod: "POST"), 0)
    }

    func testALocalDocumentIsPromotedWithNoRequestAtAll() async {
        let log = RequestRecorder()
        stubList([], log: log)
        let env = makeEnvironment()
        let parent = env.coordinator.createLocalDocument(
            title: "Parent", parentID: nil, ownerUserID: ownerID)
        let moving = env.coordinator.createLocalDocument(
            title: "Moving", parentID: parent.id, ownerUserID: ownerID)
        let viewModel = makeViewModel(env, documentID: moving.id, row: moving)

        await viewModel.moveToHome()

        XCTAssertTrue(viewModel.didMove)
        XCTAssertEqual(log.count(ofMethod: "POST"), 0)
    }

    func testARejectedMoveReportsTheErrorAndLeavesTheSheetOpen() async throws {
        let listBody = """
            {"count": 1, "next": null, "previous": null, "results": [\(Self.entry(id: rootID, title: "Root", depth: 1))]}
            """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { request in
            // `URL.path` drops a trailing slash, so a `hasSuffix("/move/")` test never
            // matches — match the absolute string instead.
            if request.url?.absoluteString.contains("/move/") == true {
                return .init(statusCode: 400, headers: [:], body: Data(), error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: listBody, error: nil)
        }
        let env = makeEnvironment()
        let viewModel = makeViewModel(env, row: document(id: documentID, title: "Moving", depth: 2))
        await viewModel.loadDestinations()

        await viewModel.move(under: try XCTUnwrap(viewModel.destinations.first))

        XCTAssertFalse(viewModel.didMove, "the sheet stays up so another destination can be picked")
        XCTAssertEqual(viewModel.errorKey, .move_error)
    }

    // MARK: - Loading

    func testAFailedFetchWithNothingElseToOfferReportsTheLoadError() async {
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }
        let env = makeEnvironment()
        let viewModel = makeViewModel(env)

        await viewModel.loadDestinations()

        XCTAssertEqual(viewModel.errorKey, .move_error_load)
    }

    /// The cached-data silence rule: a local document still has somewhere to go, so a failed
    /// fetch is not worth an error over.
    func testAFailedFetchStaysSilentWhenLocalDestinationsRemain() async {
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }
        let env = makeEnvironment()
        _ = env.coordinator.createLocalDocument(title: "Local root", parentID: nil, ownerUserID: ownerID)
        let moving = env.coordinator.createLocalDocument(
            title: "Moving", parentID: nil, ownerUserID: ownerID)
        let viewModel = makeViewModel(env, documentID: moving.id, row: moving)

        await viewModel.loadDestinations()

        XCTAssertNil(viewModel.errorKey)
        XCTAssertFalse(viewModel.localDestinations.isEmpty)
    }

    /// Work Offline is a no-network contract on every read path — the same early return the
    /// three list view models make.
    func testWorkOfflineNeverReachesTheNetwork() async {
        let log = RequestRecorder()
        stubList([Self.entry(id: rootID, title: "Root", depth: 1)], log: log)
        let env = makeEnvironment()
        env.defaults.set(true, forKey: "schrift.workOffline")
        let viewModel = makeViewModel(env)

        await viewModel.loadDestinations()

        XCTAssertEqual(log.count(ofMethod: "GET"), 0)
        XCTAssertTrue(viewModel.destinations.isEmpty)
    }
}
