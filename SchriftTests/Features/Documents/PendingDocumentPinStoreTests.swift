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
}
