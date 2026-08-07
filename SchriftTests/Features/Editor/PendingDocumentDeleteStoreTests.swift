import XCTest

@testable import Schrift

final class PendingDocumentDeleteStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private let origin = "https://docs.example.org"
    private let liveKey = "dev.llun.Schrift.pendingDeletes"
    private let quarantineKey = "dev.llun.Schrift.pendingDeletes.unreadable"

    override func setUp() {
        super.setUp()
        suiteName = "PendingDocumentDeleteStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore() -> PendingDocumentDeleteStore {
        PendingDocumentDeleteStore(userDefaults: defaults)
    }

    private func tombstone(
        documentID: UUID = UUID(),
        requestedAt: Date = Date(timeIntervalSince1970: 1_000_000),
        serverOrigin: String? = nil,
        ownerUserID: UUID? = UUID(uuidString: "11111111-1111-4111-8111-111111111111")
    ) -> PendingDocumentDelete {
        PendingDocumentDelete(
            documentID: documentID, requestedAt: requestedAt,
            serverOrigin: serverOrigin ?? origin, ownerUserID: ownerUserID)
    }

    // MARK: - Persistence

    func testATombstoneSurvivesAStoreRoundTrip() {
        let store = makeStore()
        let saved = tombstone()

        store.save(saved)

        XCTAssertEqual(makeStore().pendingDelete(for: saved.documentID), saved)
    }

    func testRemovingATombstoneLeavesTheRest() {
        let store = makeStore()
        let kept = tombstone()
        let dropped = tombstone()
        store.save(kept)
        store.save(dropped)

        store.remove(documentID: dropped.documentID)

        XCTAssertEqual(makeStore().allDeletes().map(\.documentID), [kept.documentID])
    }

    func testAnUnknownDocumentHasNoTombstone() {
        XCTAssertNil(makeStore().pendingDelete(for: UUID()))
    }

    /// The record must tolerate an owner it cannot attribute — an older or damaged schema.
    /// Decoding is all-or-nothing, so a non-optional field here would make *every* tombstone
    /// on the device unreadable at once.
    func testATombstoneMissingItsOwnerStillDecodes() {
        let store = makeStore()
        let unattributed = tombstone(ownerUserID: nil)

        store.save(unattributed)

        XCTAssertEqual(makeStore().pendingDelete(for: unattributed.documentID)?.ownerUserID, nil)
        XCTAssertEqual(makeStore().allDeletes().count, 1, "kept, even though nothing may send it")
    }

    // MARK: - Order

    func testAllDeletesOrdersOldestFirst() {
        let store = makeStore()
        let newer = tombstone(requestedAt: Date(timeIntervalSince1970: 2_000_000))
        let older = tombstone(requestedAt: Date(timeIntervalSince1970: 1_000_000))
        store.save(newer)
        store.save(older)

        XCTAssertEqual(store.allDeletes().map(\.documentID), [older.documentID, newer.documentID])
    }

    /// `values` has no defined order, `sorted` is not stable and `Date()` is not monotonic,
    /// so two deletions in the same millisecond need the id tie-break to replay the same way
    /// on every run.
    func testTombstonesRequestedAtTheSameInstantStillOrderDeterministically() {
        let store = makeStore()
        let instant = Date(timeIntervalSince1970: 1_000_000)
        let a = tombstone(documentID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, requestedAt: instant)
        let b = tombstone(documentID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!, requestedAt: instant)
        store.save(b)
        store.save(a)

        XCTAssertEqual(store.allDeletes().map(\.documentID), [a.documentID, b.documentID])
        XCTAssertEqual(
            makeStore().allDeletes().map(\.documentID), [a.documentID, b.documentID], "stable across reloads")
    }

    // MARK: - Corruption

    func testCorruptDataReadsAsEmptyRatherThanThrowing() {
        defaults.set(Data("not json".utf8), forKey: liveKey)

        XCTAssertTrue(makeStore().allDeletes().isEmpty)
    }

    /// Every method here is a read-modify-write through a `loadAll` that answers empty for a
    /// corrupt blob, so without quarantining the first queued deletion would overwrite — and
    /// destroy — tombstones that are still deletions the user is owed.
    func testAnUnreadableBlobIsQuarantinedRatherThanOverwritten() {
        let corrupt = Data("not json".utf8)
        defaults.set(corrupt, forKey: liveKey)
        let store = makeStore()
        XCTAssertTrue(store.holdsUnreadableData)

        store.save(tombstone())

        XCTAssertEqual(defaults.data(forKey: quarantineKey), corrupt, "the bytes survive")
        XCTAssertEqual(store.allDeletes().count, 1, "and the live key starts clean")
    }

    /// `remove` is a read-modify-write too, so it must quarantine on the same terms as `save`
    /// rather than resting on whichever caller happens to run first.
    func testRemovingAlsoQuarantinesAnUnreadableBlob() {
        let corrupt = Data("not json".utf8)
        defaults.set(corrupt, forKey: liveKey)

        makeStore().remove(documentID: UUID())

        XCTAssertEqual(defaults.data(forKey: quarantineKey), corrupt)
    }

    /// Sticky: quarantining leaves the live key clean, so an un-sticky answer would report a
    /// healthy store on the next launch while the deletions it moved aside stayed unknown.
    func testHoldsUnreadableDataStaysTrueWhileAQuarantineExists() {
        defaults.set(Data("not json".utf8), forKey: liveKey)
        let store = makeStore()
        store.save(tombstone())

        XCTAssertTrue(store.holdsUnreadableData, "the live key is healthy, but the quarantine remains")
        XCTAssertTrue(makeStore().holdsUnreadableData, "across reloads too")
    }

    /// The sticky flag must not make the next write move the *healthy* blob aside as well —
    /// which is why quarantining reads the live key directly rather than the sticky answer.
    func testAHealthyBlobIsNeverQuarantinedBecauseOfAnEarlierCorruption() {
        let corrupt = Data("not json".utf8)
        defaults.set(corrupt, forKey: liveKey)
        let store = makeStore()
        store.save(tombstone())
        let first = tombstone()

        store.save(first)

        XCTAssertEqual(defaults.data(forKey: quarantineKey), corrupt, "still the original corruption")
        XCTAssertEqual(store.allDeletes().count, 2)
    }

    /// First corruption wins. A second one means the store was rebuilt after the first, so
    /// the earlier blob is the one still holding tombstones nothing else has.
    func testASecondCorruptionKeepsTheFirstQuarantine() {
        let first = Data("first corruption".utf8)
        defaults.set(first, forKey: liveKey)
        makeStore().save(tombstone())
        defaults.set(Data("second corruption".utf8), forKey: liveKey)

        makeStore().save(tombstone())

        XCTAssertEqual(defaults.data(forKey: quarantineKey), first)
        XCTAssertTrue(makeStore().holdsUnreadableData)
    }
}
