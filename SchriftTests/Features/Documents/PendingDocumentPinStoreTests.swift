import XCTest

@testable import Schrift

final class PendingDocumentPinStoreTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "PendingDocumentPinStoreTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func intent(
        documentID: UUID = UUID(), owner: UUID = UUID(), origin: String = "https://docs.example.org",
        pinned: Bool = true
    ) -> PendingDocumentPin {
        PendingDocumentPin(
            documentID: documentID, serverOrigin: origin, ownerUserID: owner,
            isPinned: pinned, previousValue: false, row: nil, intentID: UUID(),
            requestedAt: Date(timeIntervalSince1970: 1_000_000))
    }

    func testRoundTripAndLatestIntentWins() {
        let store = PendingDocumentPinStore(userDefaults: defaults)
        let first = intent()
        let latest = intent(documentID: first.documentID, owner: first.ownerUserID, pinned: false)
        XCTAssertTrue(store.save(first))
        XCTAssertTrue(store.save(latest))
        XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allPins(), [latest])
    }

    func testSameDocumentKeepsSeparateAccountsAndServers() {
        let store = PendingDocumentPinStore(userDefaults: defaults)
        let a = intent()
        let b = intent(documentID: a.documentID, pinned: false)
        let c = intent(documentID: a.documentID, owner: a.ownerUserID, origin: "https://other.example.org")
        for record in [a, b, c] { XCTAssertTrue(store.save(record)) }
        XCTAssertEqual(Set(store.allPins().map(\.key)), Set([a.key, b.key, c.key]))
    }

    func testAnOldCompletionCannotRemoveANewerToggle() {
        let store = PendingDocumentPinStore(userDefaults: defaults)
        let first = intent()
        let latest = intent(documentID: first.documentID, owner: first.ownerUserID, pinned: false)
        XCTAssertTrue(store.save(first))
        XCTAssertTrue(store.save(latest))
        store.remove(first)
        XCTAssertEqual(store.allPins(), [latest])
        store.remove(latest)
        XCTAssertTrue(store.allPins().isEmpty)
    }

    func testUnreadableIntentBlobIsPreservedBeforeANewWrite() {
        let bytes = Data("unreadable".utf8)
        defaults.set(bytes, forKey: "dev.llun.Schrift.pendingPins")
        let store = PendingDocumentPinStore(userDefaults: defaults)
        XCTAssertTrue(store.allPins().isEmpty)
        let newIntent = intent()
        XCTAssertTrue(store.save(newIntent))
        XCTAssertEqual(defaults.data(forKey: "dev.llun.Schrift.pendingPins.unreadable"), bytes)
        XCTAssertEqual(store.allPins(), [newIntent])
    }

    // MARK: - Key composition

    func testKeyComposesServerAccountAndDocument() {
        let documentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let owner = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let base = intent(documentID: documentID, owner: owner)

        XCTAssertEqual(
            base.key,
            "https://docs.example.org|22222222-2222-4222-8222-222222222222|11111111-1111-4111-8111-111111111111")
        XCTAssertNotEqual(base.key, intent(documentID: documentID, owner: owner, origin: "https://other.example").key)
        XCTAssertNotEqual(base.key, intent(documentID: documentID, owner: UUID()).key)
        XCTAssertNotEqual(base.key, intent(documentID: UUID(), owner: owner).key)
        XCTAssertEqual(base.key, intent(documentID: documentID, owner: owner, pinned: false).key, "bit is not identity")
    }

    // MARK: - Settled projection

    func testSettledStartsEmptyAndPersistsAcrossInstances() {
        XCTAssertTrue(PendingDocumentPinStore(userDefaults: defaults).allSettled().isEmpty)
        let settled = intent()

        XCTAssertTrue(PendingDocumentPinStore(userDefaults: defaults).saveSettled(settled))

        XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allSettled(), [settled])
    }

    func testSavingASettledBitForTheSameKeyReplacesIt() {
        let store = PendingDocumentPinStore(userDefaults: defaults)
        let first = intent()
        let later = intent(documentID: first.documentID, owner: first.ownerUserID, pinned: false)
        store.saveSettled(first)
        store.saveSettled(later)

        XCTAssertEqual(store.allSettled(), [later])
    }

    func testSettledEntriesStaySeparatePerServerAccountAndDocument() {
        let store = PendingDocumentPinStore(userDefaults: defaults)
        let document = UUID()
        let owner = UUID()
        let entries = [
            intent(documentID: document, owner: owner),
            intent(documentID: document, owner: owner, origin: "https://other.example"),
            intent(documentID: document, owner: UUID()),
            intent(documentID: UUID(), owner: owner),
        ]
        entries.forEach { store.saveSettled($0) }

        XCTAssertEqual(Set(store.allSettled().map(\.key)), Set(entries.map(\.key)))
        XCTAssertEqual(store.allSettled().count, 4)
    }

    func testRemoveSettledOnlyRemovesTheMatchingIntent() {
        let store = PendingDocumentPinStore(userDefaults: defaults)
        let original = intent()
        let superseding = intent(documentID: original.documentID, owner: original.ownerUserID, pinned: false)
        store.saveSettled(superseding)

        store.removeSettled(original)
        XCTAssertEqual(store.allSettled(), [superseding], "a stale intent id cannot remove the newer entry")

        store.removeSettled(superseding)
        XCTAssertTrue(store.allSettled().isEmpty)
    }

    func testSettledAndPendingStoresDoNotShareState() {
        let store = PendingDocumentPinStore(userDefaults: defaults)
        let pending = intent()
        let settled = intent()
        store.save(pending)
        store.saveSettled(settled)

        XCTAssertEqual(store.allPins(), [pending])
        XCTAssertEqual(store.allSettled(), [settled])

        store.remove(pending)
        XCTAssertEqual(store.allSettled(), [settled])
        XCTAssertTrue(store.allPins().isEmpty)
    }

    func testAnUnreadableSettledBlobReadsAsEmptyAndIsReplacedByTheNextSave() {
        defaults.set(Data("not json".utf8), forKey: "dev.llun.Schrift.settledPins")
        let store = PendingDocumentPinStore(userDefaults: defaults)
        XCTAssertTrue(store.allSettled().isEmpty)

        let settled = intent()
        XCTAssertTrue(store.saveSettled(settled))

        XCTAssertEqual(store.allSettled(), [settled])
    }
}
