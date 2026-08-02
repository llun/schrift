import XCTest

@testable import Schrift

final class SignedInUserStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SignedInUserStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testStartsEmptyAndRemembersAcrossLaunches() {
        XCTAssertNil(SignedInUserStore(userDefaults: defaults).userID)

        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        SignedInUserStore(userDefaults: defaults).remember(id)

        XCTAssertEqual(SignedInUserStore(userDefaults: defaults).userID, id, "survives a relaunch")
    }

    /// The wire field is Optional, and a response that omits it says nothing about the account.
    /// Treating that as "sign the user out of their own local documents" would make every
    /// offline-created document unlistable and unreplayable on one malformed response.
    func testANilIdDoesNotClearAGoodValue() {
        let id = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let store = SignedInUserStore(userDefaults: defaults)
        store.remember(id)

        store.remember(nil)

        XCTAssertEqual(store.userID, id)
        XCTAssertEqual(SignedInUserStore(userDefaults: defaults).userID, id, "and nothing was erased on disk")
    }

    func testRememberingADifferentUserReplacesTheId() {
        let first = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let second = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let store = SignedInUserStore(userDefaults: defaults)
        store.remember(first)

        store.remember(second)

        XCTAssertEqual(store.userID, second)
        XCTAssertEqual(SignedInUserStore(userDefaults: defaults).userID, second)
    }

    /// Records deliberately outlive a sign-out, so this must not: the next session has to learn
    /// the id from the server before anything of the previous user's is listed or sent.
    func testClearForgetsTheIdOnDisk() {
        let store = SignedInUserStore(userDefaults: defaults)
        store.remember(UUID(uuidString: "55555555-5555-4555-8555-555555555555")!)

        store.clear()

        XCTAssertNil(store.userID)
        XCTAssertNil(SignedInUserStore(userDefaults: defaults).userID)
    }

    /// The property the read-through design exists for: a reader built *before* the first
    /// write must still see it. A cached value would answer nil forever, and the mint path
    /// fails closed on nil — so the feature would silently do nothing on a fresh sign-in.
    func testAReaderBuiltBeforeTheWriteStillSeesTheId() {
        let reader = SignedInUserStore(userDefaults: defaults)
        XCTAssertNil(reader.userID)

        SignedInUserStore(userDefaults: defaults).remember(
            UUID(uuidString: "66666666-6666-4666-8666-666666666666")!)

        XCTAssertEqual(reader.userID?.uuidString, "66666666-6666-4666-8666-666666666666")
    }

    /// A damaged value must read as "unknown", not crash or half-apply — the whole feature
    /// fails closed on a nil id, which is the safe direction.
    func testAnUnparseableStoredValueReadsAsUnknown() {
        defaults.set("not a uuid", forKey: "dev.llun.Schrift.signedInUserID")

        XCTAssertNil(SignedInUserStore(userDefaults: defaults).userID)
    }
}
