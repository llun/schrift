import XCTest

@testable import Schrift

final class RecentSearchesStoreTests: XCTestCase {
    func testAddingTrimsSurroundingWhitespace() {
        XCTAssertEqual(addingRecentSearch("  roadmap \n", to: []), ["roadmap"])
    }

    func testBlankQueryLeavesTheListUntouched() {
        XCTAssertEqual(addingRecentSearch("   \n\t", to: ["a", "b"]), ["a", "b"])
        XCTAssertEqual(addingRecentSearch("", to: []), [])
    }

    func testDuplicateIsCaseInsensitiveAndMovesToFrontWithNewSpelling() {
        let result = addingRecentSearch("ROADMAP", to: ["a", "roadmap", "b"])
        XCTAssertEqual(result, ["ROADMAP", "a", "b"])
    }

    func testNewestComesFirstAndOthersKeepOrder() {
        XCTAssertEqual(addingRecentSearch("c", to: ["a", "b"]), ["c", "a", "b"])
    }

    func testLimitDropsTheOldest() {
        let result = addingRecentSearch("new", to: ["1", "2", "3"], limit: 3)
        XCTAssertEqual(result, ["new", "1", "2"])
    }

    func testDuplicateAtTheLimitDoesNotDropAnything() {
        let result = addingRecentSearch("3", to: ["1", "2", "3"], limit: 3)
        XCTAssertEqual(result, ["3", "1", "2"])
    }

    func testDefaultLimitIsEight() {
        let existing = (1...8).map(String.init)
        let result = addingRecentSearch("9", to: existing)
        XCTAssertEqual(result.count, 8)
        XCTAssertEqual(result.first, "9")
        XCTAssertFalse(result.contains("8"))
    }
}

final class RecentSearchesStorePersistenceTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private let suiteName = "dev.llun.Schrift.tests.RecentSearchesStoreTests.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        userDefaults = UserDefaults(suiteName: suiteName)
        userDefaults.removePersistentDomain(forName: suiteName)
        SignedInUserStore(userDefaults: userDefaults).remember(accountA)
    }

    private let accountA = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    /// Each account has its own list; with no known account nothing is shown or stored; clear
    /// empties every account's list.
    func testListsBelongToTheSignedInAccount() {
        let store = RecentSearchesStore(userDefaults: userDefaults)
        store.add("roadmap")
        let signedInUser = SignedInUserStore(userDefaults: userDefaults)

        signedInUser.remember(UUID(uuidString: "22222222-2222-4222-8222-222222222222")!)
        XCTAssertEqual(store.searches, [])
        store.add("budget")
        signedInUser.clear()
        XCTAssertEqual(store.searches, [])
        store.add("ignored")
        signedInUser.remember(accountA)
        XCTAssertEqual(store.searches, ["roadmap"])

        userDefaults.set(["shared"], forKey: "dev.llun.Schrift.recentSearches")  // an earlier build's list
        store.clear()
        XCTAssertEqual(store.searches, [])
        XCTAssertNil(userDefaults.object(forKey: "dev.llun.Schrift.recentSearches"))
        signedInUser.remember(UUID(uuidString: "22222222-2222-4222-8222-222222222222")!)
        XCTAssertEqual(store.searches, [], "every account's list goes")
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testStartsEmptyWhenNothingIsStored() {
        XCTAssertTrue(RecentSearchesStore(userDefaults: userDefaults).searches.isEmpty)
    }

    func testAddPersistsAcrossAFreshInstance() {
        let first = RecentSearchesStore(userDefaults: userDefaults)
        first.add("alpha")
        first.add("beta")
        XCTAssertEqual(first.searches, ["beta", "alpha"])

        let second = RecentSearchesStore(userDefaults: userDefaults)
        XCTAssertEqual(second.searches, ["beta", "alpha"])
    }

    func testBlankAddLeavesSearchesUnchanged() {
        let store = RecentSearchesStore(userDefaults: userDefaults)
        store.add("   ")
        XCTAssertTrue(store.searches.isEmpty)
        XCTAssertTrue(RecentSearchesStore(userDefaults: userDefaults).searches.isEmpty)
    }

    func testClearEmptiesMemoryAndStorage() {
        let store = RecentSearchesStore(userDefaults: userDefaults)
        store.add("alpha")
        store.clear()
        XCTAssertTrue(store.searches.isEmpty)
        XCTAssertTrue(RecentSearchesStore(userDefaults: userDefaults).searches.isEmpty)
    }
}
