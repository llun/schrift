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
    private let suiteName = "dev.llun.Schrift.tests.RecentSearchesStoreTests"

    override func setUp() {
        super.setUp()
        userDefaults = UserDefaults(suiteName: suiteName)
        userDefaults.removePersistentDomain(forName: suiteName)
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

    func testBlankAddIsNotPersisted() {
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
