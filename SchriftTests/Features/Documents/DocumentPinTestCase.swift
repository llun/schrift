import Observation
import XCTest

@testable import Schrift

/// Shared wiring for the `DocumentPin…Tests` classes (one per concern). Holds no tests.
@MainActor
class DocumentPinTestCase: XCTestCase {
    var suite: String!
    var defaults: UserDefaults!
    let owner = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let origin = "https://docs.example.org"

    override func setUp() {
        super.setUp()
        suite = "DocumentPinCoordinatorTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        SignedInUserStore(userDefaults: defaults).remember(owner)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        MockURLProtocol.reset()
        super.tearDown()
    }

    func row(pinned: Bool = false) -> Document {
        Document(
            id: id, title: "Document", excerpt: nil, abilities: DocumentAbilities(),
            linkReach: .restricted, linkRole: .reader, isFavorite: pinned, depth: 1, numchild: 0,
            path: "0001", createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
            userRole: nil, creator: nil)
    }

    func client(origin: String? = nil) -> DocsAPIClient {
        DocsAPIClient(
            baseURL: URL(string: (origin ?? self.origin) + "/api/v1.0/")!,
            session: MockURLProtocol.makeSession(), cookieProvider: { [] })
    }

    func pins(origin: String? = nil) -> DocumentPinCoordinator {
        DocumentPinCoordinator(
            client: client(origin: origin), store: PendingDocumentPinStore(userDefaults: defaults),
            cache: DocumentCacheStore(userDefaults: defaults), serverOrigin: origin ?? self.origin,
            signedInUser: SignedInUserStore(userDefaults: defaults), userDefaults: defaults)
    }

    func stub(
        status: Int = 204, error: Error? = nil, gate: MockURLProtocol.ResponseGate? = nil, user: UUID? = nil
    )
        -> RequestRecorder
    {
        let log = RequestRecorder()
        let userBody = Data("{\"id\":\"\((user ?? owner).uuidString)\"}".utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            if request.url?.absoluteString.hasSuffix("/users/me/") == true {
                return .init(statusCode: 200, headers: [:], body: userBody, error: nil)
            }
            return .init(
                statusCode: status, headers: ["Content-Type": "application/json"], body: Data(), error: error,
                releasedBy: gate)
        }
        return log
    }

    @discardableResult
    func queue(_ pins: DocumentPinCoordinator, pinned: Bool, row: Document? = nil) -> Bool {
        pins.queue(documentID: id, isPinned: pinned, row: row ?? self.row(), ownerUserID: owner)
    }

    func environment() -> (
        DocumentSaveCoordinator, HomeViewModel, OptionsViewModel, SharedViewModel, SearchViewModel
    ) {
        let client = client()
        let cache = DocumentCacheStore(userDefaults: defaults)
        let signedIn = SignedInUserStore(userDefaults: defaults)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: PendingDraftStore(userDefaults: defaults),
            createStore: PendingDocumentCreateStore(userDefaults: defaults),
            deleteStore: PendingDocumentDeleteStore(userDefaults: defaults),
            pinStore: PendingDocumentPinStore(userDefaults: defaults),
            attachmentStore: PendingAttachmentStore(userDefaults: defaults), listCache: cache,
            childrenCache: DocumentChildrenCacheStore(userDefaults: defaults), serverOrigin: origin,
            backgroundTasks: .noop)
        let home = HomeViewModel(
            client: client, cache: cache, saveCoordinator: coordinator, userDefaults: defaults, signedInUser: signedIn)
        let options = OptionsViewModel(
            client: client, documentID: id, isFavorite: false, saveCoordinator: coordinator, signedInUser: signedIn)
        let shared = SharedViewModel(
            client: client, cache: cache, userDefaults: defaults, saveCoordinator: coordinator, signedInUser: signedIn)
        let search = SearchViewModel(
            client: client, store: RecentSearchesStore(userDefaults: defaults), saveCoordinator: coordinator,
            signedInUser: signedIn)
        return (coordinator, home, options, shared, search)
    }
}
