import XCTest

@testable import Schrift

final class RecentServersStoreTests: XCTestCase {
    func testAddingToEmptyListInsertsIt() {
        let url = URL(string: "https://docs.llun.dev")!
        XCTAssertEqual(addingRecentServer(url, to: []), [url])
    }

    func testAddingDuplicateMovesItToFront() {
        let a = URL(string: "https://a.example.com")!
        let b = URL(string: "https://b.example.com")!
        let result = addingRecentServer(a, to: [b, a])
        XCTAssertEqual(result, [a, b])
    }

    func testAddingBeyondLimitDropsOldest() {
        let urls = (0..<5).map { URL(string: "https://server\($0).example.com")! }
        let newURL = URL(string: "https://new.example.com")!
        let result = addingRecentServer(newURL, to: urls, limit: 5)
        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(result.first, newURL)
        XCTAssertFalse(result.contains(urls.last!))
    }

    func testOrderOfOthersIsPreserved() {
        let a = URL(string: "https://a.example.com")!
        let b = URL(string: "https://b.example.com")!
        let c = URL(string: "https://c.example.com")!
        XCTAssertEqual(addingRecentServer(c, to: [a, b]), [c, a, b])
    }
}

final class RecentServersStorePersistenceTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private let suiteName = "dev.llun.Schrift.tests.RecentServersStoreTests"

    override func setUp() {
        super.setUp()
        userDefaults = UserDefaults(suiteName: suiteName)
        userDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testStartsEmptyWhenNoStoredData() {
        let store = RecentServersStore(userDefaults: userDefaults)
        XCTAssertTrue(store.servers.isEmpty)
    }

    func testAddServerPersistsAcrossFreshInit() {
        let url = URL(string: "https://docs.llun.dev")!
        let first = RecentServersStore(userDefaults: userDefaults)
        first.addServer(url)

        let second = RecentServersStore(userDefaults: userDefaults)
        XCTAssertEqual(second.servers, [url])
    }
}
