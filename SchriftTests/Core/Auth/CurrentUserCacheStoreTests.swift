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

    /// The twin of `SignedInUserStoreTests.testANilIdDoesNotClearAGoodValue`, and load-bearing
    /// for the same reason: a failed fetch has told us nothing about the account, so writing
    /// its nil through would blank the row this store exists to keep filled.
    func testANilUserDoesNotClearAGoodValue() {
        let store = CurrentUserCacheStore(userDefaults: defaults)
        store.remember(ada)

        store.remember(nil)

        XCTAssertEqual(store.user, ada)
        XCTAssertEqual(CurrentUserCacheStore(userDefaults: defaults).user, ada, "and nothing was erased on disk")
    }

    /// Every field of `CurrentUser` decodes with `decodeIfPresent`, so a `200` carrying `{}` —
    /// a proxy, a serializer change — decodes to a perfectly valid all-nil user. It is as
    /// uninformative as a failed fetch, so it gets the same treatment: without this it would
    /// pass a bare `if let` and destroy a good profile.
    func testAUserCarryingNoAccountDetailIsIgnoredLikeANilOne() {
        let store = CurrentUserCacheStore(userDefaults: defaults)
        store.remember(ada)

        store.remember(CurrentUser())
        store.remember(CurrentUser(email: "   "))

        XCTAssertEqual(store.user, ada)
    }

    /// `language` is a *preference*, not identity: a payload carrying only that says nothing
    /// about who is signed in, so letting it through would destroy a good profile — one junk
    /// field short of the `{}` case above.
    func testAUserCarryingOnlyALanguageIsIgnored() {
        let store = CurrentUserCacheStore(userDefaults: defaults)
        store.remember(ada)

        store.remember(CurrentUser(language: "en-us"))

        XCTAssertEqual(store.user, ada)
    }

    /// The mirror of the rule above: an id with no name or email is still *this* account, and
    /// the display falling back to "—" is honest where forgetting the account is not.
    func testAUserWithOnlyAnIdIsStillRemembered() {
        let idOnly = CurrentUser(id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!)
        let store = CurrentUserCacheStore(userDefaults: defaults)

        store.remember(idOnly)

        XCTAssertEqual(store.user, idOnly)
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
