import XCTest

@testable import Schrift

final class CurrentUserCacheStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "CurrentUserCacheStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private let ada = CurrentUser(
        id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
        email: "ada@example.org",
        fullName: "Ada Lovelace",
        shortName: "Ada",
        language: "en-us"
    )

    func testStartsEmpty() {
        XCTAssertNil(CurrentUserCacheStore(userDefaults: defaults).user)
    }

    func testRemembersEveryFieldAcrossLaunches() {
        CurrentUserCacheStore(userDefaults: defaults).remember(ada)

        XCTAssertEqual(CurrentUserCacheStore(userDefaults: defaults).user, ada, "survives a relaunch")
    }

    func testRememberingADifferentUserReplacesTheEntry() {
        let store = CurrentUserCacheStore(userDefaults: defaults)
        let grace = CurrentUser(
            id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!, email: "grace@example.org")
        store.remember(ada)

        store.remember(grace)

        XCTAssertEqual(CurrentUserCacheStore(userDefaults: defaults).user, grace)
    }

    /// The account row and detail screen are the only readers, and both already render
    /// "we have nothing" for a nil user. A blob this build cannot decode — a field added or
    /// removed by a later schema — must therefore read as nil rather than trap or throw.
    func testAnUndecodableBlobReadsAsNoUser() {
        defaults.set(Data("not json".utf8), forKey: "dev.llun.Schrift.currentUser")

        XCTAssertNil(CurrentUserCacheStore(userDefaults: defaults).user)
    }

    /// Cleared at sign-in and sign-out, and this is what the next account's first offline
    /// launch depends on: the previous user's email must not still be on screen.
    func testClearForgetsTheUserOnDisk() {
        let store = CurrentUserCacheStore(userDefaults: defaults)
        store.remember(ada)

        store.clear()

        XCTAssertNil(store.user)
        XCTAssertNil(CurrentUserCacheStore(userDefaults: defaults).user)
    }
}
