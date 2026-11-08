import XCTest

@testable import Schrift

@MainActor
final class ReplicaOwnershipStoreTests: XCTestCase {
    private static let key = "dev.llun.Schrift.replicaOwnership"
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "ReplicaOwnershipStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        suite = nil
        super.tearDown()
    }

    private func scope(
        serverOrigin: String = "https://docs.example.org", org: String = "docs", documentID: UUID = UUID()
    ) -> ReplicaScope {
        ReplicaScope(serverOrigin: serverOrigin, ownerUserID: UUID(), org: org, documentID: documentID)
    }

    func testMissingBlobIsNotOwnedAndNotUnreadable() {
        let store = ReplicaOwnershipStore(userDefaults: defaults)
        XCTAssertEqual(store.owner(documentID: UUID(), serverOrigin: "https://docs.example.org"), .none)
        XCTAssertFalse(store.holdsUnreadableData)
    }

    func testMarkOwnerAndClearRoundTrip() {
        let store = ReplicaOwnershipStore(userDefaults: defaults)
        let scope = scope()
        XCTAssertTrue(store.mark(scope))
        XCTAssertEqual(store.owner(documentID: scope.documentID, serverOrigin: scope.serverOrigin), .owned(scope))
        XCTAssertFalse(store.holdsUnreadableData)
        XCTAssertTrue(store.clear(scope))
        XCTAssertEqual(store.owner(documentID: scope.documentID, serverOrigin: scope.serverOrigin), .none)
    }

    func testOwnerIsScopedByServerAndDocument() {
        let store = ReplicaOwnershipStore(userDefaults: defaults)
        let first = scope()
        let second = scope(serverOrigin: "https://other.example.org")
        let third = scope(org: "other")
        XCTAssertTrue(store.mark(first))
        XCTAssertTrue(store.mark(second))
        XCTAssertTrue(store.mark(third))
        XCTAssertEqual(store.owner(documentID: first.documentID, serverOrigin: first.serverOrigin), .owned(first))
        XCTAssertEqual(store.owner(documentID: second.documentID, serverOrigin: second.serverOrigin), .owned(second))
        XCTAssertEqual(store.owner(documentID: third.documentID, serverOrigin: third.serverOrigin), .owned(third))
        XCTAssertEqual(store.owner(documentID: first.documentID, serverOrigin: second.serverOrigin), .none)
        XCTAssertTrue(store.clear(first))
        XCTAssertEqual(store.owner(documentID: first.documentID, serverOrigin: first.serverOrigin), .none)
        XCTAssertEqual(store.owner(documentID: second.documentID, serverOrigin: second.serverOrigin), .owned(second))
    }

    func testAnotherScopeNeverReplacesOrClearsTheOwner() {
        let store = ReplicaOwnershipStore(userDefaults: defaults)
        let first = scope()
        let otherAccount = ReplicaScope(
            serverOrigin: first.serverOrigin, ownerUserID: UUID(), org: first.org, documentID: first.documentID)
        XCTAssertTrue(store.mark(first))
        XCTAssertFalse(store.mark(otherAccount), "the first owner's replica would become unreachable")
        XCTAssertTrue(store.clear(otherAccount), "nothing of that scope's to clear")
        XCTAssertEqual(store.owner(documentID: first.documentID, serverOrigin: first.serverOrigin), .owned(first))
        XCTAssertTrue(store.mark(first), "re-marking the same scope is idempotent")
    }

    func testInvalidScopeIsRefused() {
        let store = ReplicaOwnershipStore(userDefaults: defaults)
        let invalid = scope(serverOrigin: "not a url")
        XCTAssertFalse(store.mark(invalid))
        XCTAssertEqual(store.owner(documentID: invalid.documentID, serverOrigin: invalid.serverOrigin), .none)
    }

    func testCorruptBlobIsUnreadableAndSticky() {
        defaults.set(Data([0xff, 0x00]), forKey: Self.key)
        let store = ReplicaOwnershipStore(userDefaults: defaults)
        let scope = scope()
        XCTAssertEqual(store.owner(documentID: scope.documentID, serverOrigin: scope.serverOrigin), .unreadable)
        XCTAssertTrue(store.holdsUnreadableData)
        // Neither a mark nor a clear may overwrite the unknown blob: ownership
        // must stay unknown (read-only) rather than silently become "not owned".
        XCTAssertFalse(store.mark(scope))
        XCTAssertFalse(store.clear(scope))
        XCTAssertEqual(store.owner(documentID: scope.documentID, serverOrigin: scope.serverOrigin), .unreadable)
        XCTAssertEqual(defaults.data(forKey: Self.key), Data([0xff, 0x00]))
    }

    func testVersionMismatchIsUnreadable() throws {
        try writeEnvelope(version: 2, digest: replicaDigest(Data("{}".utf8)))
        let store = ReplicaOwnershipStore(userDefaults: defaults)
        XCTAssertEqual(store.owner(documentID: UUID(), serverOrigin: "https://docs.example.org"), .unreadable)
        XCTAssertTrue(store.holdsUnreadableData)
    }

    func testDigestMismatchIsUnreadable() throws {
        try writeEnvelope(version: 1, digest: "deadbeef")
        let store = ReplicaOwnershipStore(userDefaults: defaults)
        XCTAssertEqual(store.owner(documentID: UUID(), serverOrigin: "https://docs.example.org"), .unreadable)
        XCTAssertTrue(store.holdsUnreadableData)
    }

    func testMarkerSurvivesANewStoreInstance() {
        let scope = scope()
        XCTAssertTrue(ReplicaOwnershipStore(userDefaults: defaults).mark(scope))
        XCTAssertEqual(
            ReplicaOwnershipStore(userDefaults: defaults).owner(
                documentID: scope.documentID, serverOrigin: scope.serverOrigin), .owned(scope))
    }

    private func writeEnvelope(version: Int, digest: String) throws {
        let object: [String: Any] = ["version": version, "entries": [String: Any](), "digest": digest]
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: Self.key)
    }
}
