import XCTest

@testable import Schrift

final class PendingDocumentCreateStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private let origin = "https://docs.example.org"

    override func setUp() {
        super.setUp()
        suiteName = "PendingDocumentCreateStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore() -> PendingDocumentCreateStore {
        PendingDocumentCreateStore(userDefaults: defaults)
    }

    private func record(
        localID: UUID = UUID(),
        title: String = "Untitled document",
        parentID: UUID? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 1_000_000),
        serverOrigin: String? = nil
    ) -> PendingDocumentCreate {
        PendingDocumentCreate(
            localID: localID, title: title, parentID: parentID, createdAt: createdAt,
            serverOrigin: serverOrigin ?? origin)
    }

    // MARK: - Persistence

    func testARecordSurvivesAStoreRoundTrip() {
        let store = makeStore()
        let parent = UUID()
        let saved = record(title: "Notes", parentID: parent)

        store.save(saved)

        XCTAssertEqual(makeStore().create(for: saved.localID), saved)
    }

    /// Millisecond dates, like every other store carrying recency semantics: `.iso8601`
    /// truncates to whole seconds, which would make two creates minted in the same second
    /// tie — and `createdAt` is the replay order.
    func testCreatedAtKeepsSubSecondPrecision() {
        let store = makeStore()
        let precise = Date(timeIntervalSince1970: 1_000_000.123)
        let saved = record(createdAt: precise)

        store.save(saved)

        let reloaded = makeStore().create(for: saved.localID)
        XCTAssertEqual(reloaded?.createdAt.timeIntervalSince1970 ?? 0, 1_000_000.123, accuracy: 0.0005)
    }

    func testRemovingARecordLeavesTheOthers() {
        let store = makeStore()
        let kept = record(title: "Kept")
        let dropped = record(title: "Dropped")
        store.save(kept)
        store.save(dropped)

        store.remove(localID: dropped.localID)

        XCTAssertNil(store.create(for: dropped.localID))
        XCTAssertEqual(store.create(for: kept.localID), kept)
    }

    /// Replay order: a child created after its parent must never be POSTed first.
    func testAllCreatesAreOldestFirst() {
        let store = makeStore()
        let second = record(title: "Second", createdAt: Date(timeIntervalSince1970: 2_000))
        let first = record(title: "First", createdAt: Date(timeIntervalSince1970: 1_000))
        store.save(second)
        store.save(first)

        XCTAssertEqual(store.allCreates().map(\.title), ["First", "Second"])
    }

    func testCorruptDataReadsAsEmptyRatherThanThrowing() {
        defaults.set(Data("not json".utf8), forKey: "dev.llun.Schrift.pendingCreates")

        XCTAssertTrue(makeStore().allCreates().isEmpty)
    }

    /// The two-phase replay checkpoint: the server id is persisted the instant the POST
    /// lands, *before* anything is migrated, so a relaunch resumes instead of re-POSTing.
    func testTheServerIDCheckpointIsPersisted() {
        let store = makeStore()
        var saved = record()
        store.save(saved)
        let serverID = UUID()

        saved.syncedServerID = serverID
        store.save(saved)

        XCTAssertEqual(makeStore().create(for: saved.localID)?.syncedServerID, serverID)
    }

    // MARK: - The synthetic Document

    func testTheSyntheticDocumentCarriesTheRecordsIdentity() {
        let created = Date(timeIntervalSince1970: 1_234_567)
        let saved = record(title: "Notes", createdAt: created)

        let document = localDocument(from: saved)

        XCTAssertEqual(document.id, saved.localID)
        XCTAssertEqual(document.title, "Notes")
        XCTAssertEqual(document.createdAt, created)
        XCTAssertEqual(document.updatedAt, created)
        XCTAssertEqual(document.userRole, .owner)
        XCTAssertFalse(document.isFavorite, "nothing server-side exists to favorite yet")
    }

    /// Abilities are the honest set for a document that exists only here: it can be
    /// edited and deleted locally, and nothing else — every other ability is a server
    /// call against an id the server has never seen. `childrenCreate` false is also what
    /// keeps children-of-local-parents out of scope until the replay can order them.
    func testTheSyntheticDocumentClaimsOnlyLocallyTrueAbilities() {
        let document = localDocument(from: record())

        XCTAssertTrue(document.abilities.update)
        XCTAssertTrue(document.abilities.partialUpdate)
        XCTAssertTrue(document.abilities.destroy)
        XCTAssertFalse(document.abilities.childrenCreate)
        XCTAssertFalse(document.abilities.favorite)
        XCTAssertFalse(document.abilities.accessesManage)
        XCTAssertFalse(document.abilities.linkConfiguration)
        XCTAssertFalse(document.abilities.duplicate)
    }

    /// `path` is the server's treebeard segment and `depth`/`numchild` its tree bookkeeping;
    /// none can be computed here. They are placeholders, and the app reads none of them —
    /// which is why a synthetic document must never be written into a metadata cache, where
    /// it would later be indistinguishable from a real one.
    func testTheSyntheticDocumentUsesInertTreePlaceholders() {
        let document = localDocument(from: record())

        XCTAssertEqual(document.path, "")
        XCTAssertEqual(document.depth, 1)
        XCTAssertEqual(document.numchild, 0)
        XCTAssertEqual(document.linkReach, .restricted, "a document only on this device is not shared")
    }

    // MARK: - Merging into a fetched list

    func testLocalDocumentsAreMergedNewestFirstAheadOfFetchedRows() {
        let fetched = [serverDocument(title: "From the server")]
        let older = record(title: "Older", createdAt: Date(timeIntervalSince1970: 1_000))
        let newer = record(title: "Newer", createdAt: Date(timeIntervalSince1970: 2_000))

        let merged = mergedWithLocalDocuments(fetched: fetched, local: [older, newer])

        XCTAssertEqual(merged.map(\.title), ["Newer", "Older", "From the server"])
    }

    func testMergingWithNoLocalDocumentsReturnsTheFetchedListUnchanged() {
        let fetched = [serverDocument(title: "A"), serverDocument(title: "B")]

        XCTAssertEqual(mergedWithLocalDocuments(fetched: fetched, local: []), fetched)
    }

    /// Defence in depth for the window between a create replay landing and the next list
    /// fetch: the real document may already be in `fetched` while the record is still being
    /// torn down, and the list must not show it twice.
    func testAFetchedRowWinsOverALocalRecordWithTheSameID() {
        let shared = UUID()
        let fetched = [serverDocument(id: shared, title: "Server copy")]
        let local = record(localID: shared, title: "Local copy")

        let merged = mergedWithLocalDocuments(fetched: fetched, local: [local])

        XCTAssertEqual(merged.map(\.title), ["Server copy"])
    }

    private func serverDocument(id: UUID = UUID(), title: String) -> Document {
        Document(
            id: id, title: title, excerpt: nil, abilities: DocumentAbilities(), linkReach: .restricted,
            linkRole: .reader, computedLinkReach: nil, computedLinkRole: nil, isFavorite: false, depth: 1,
            numchild: 0, path: "00000A", createdAt: Date(timeIntervalSince1970: 500),
            updatedAt: Date(timeIntervalSince1970: 500), userRole: .owner, creator: nil)
    }
}
