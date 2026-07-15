import XCTest

@testable import Schrift

/// The pure presence value types: local awareness JSON, peer parsing, and the
/// fold that turns awareness entries into a stable peer list.
final class CollaborationPresenceTests: XCTestCase {

    // MARK: - LocalAwarenessState.json

    func testJSONHasNameAndColor() throws {
        let json = LocalAwarenessState(name: "Ada", color: "#30bced").json()
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
        XCTAssertEqual(object, ["name": "Ada", "color": "#30bced"])
    }

    func testJSONEscapesQuotesInName() throws {
        // A name with a quote must be escaped, never string-interpolated.
        let json = LocalAwarenessState(name: "A\"B", color: "#000000").json()
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
        XCTAssertEqual(object["name"], "A\"B")
    }

    func testJSONDoesNotEscapeSlashes() {
        // Matches yjs/JSON.stringify, which leaves `/` unescaped.
        let json = LocalAwarenessState(name: "a/b", color: "#000000").json()
        XCTAssertTrue(json.contains("a/b"))
        XCTAssertFalse(json.contains("a\\/b"))
    }

    // MARK: - CollaborationPeer parsing

    func testParsesAValidPeer() throws {
        let peer = try XCTUnwrap(
            CollaborationPeer(clientID: 7, stateJSON: ##"{"name":"Ada","color":"#30bced"}"##))
        XCTAssertEqual(peer.clientID, 7)
        XCTAssertEqual(peer.name, "Ada")
        XCTAssertEqual(peer.color, "#30bced")
        XCTAssertEqual(peer.id, 7)
    }

    func testRejectsNullState() {
        // A removed client's state is the literal "null".
        XCTAssertNil(CollaborationPeer(clientID: 1, stateJSON: "null"))
    }

    func testRejectsEmptyName() {
        XCTAssertNil(CollaborationPeer(clientID: 1, stateJSON: ##"{"name":"","color":"#000000"}"##))
    }

    func testRejectsMissingName() {
        // The web sometimes broadcasts a color-only state before a name is set.
        XCTAssertNil(CollaborationPeer(clientID: 1, stateJSON: ##"{"color":"#000000"}"##))
    }

    func testRejectsMissingColor() {
        // A name-only state has no colour to paint the peer with — drop it.
        XCTAssertNil(CollaborationPeer(clientID: 1, stateJSON: ##"{"name":"Ada"}"##))
    }

    func testRejectsUnparseableState() {
        XCTAssertNil(CollaborationPeer(clientID: 1, stateJSON: "{not json"))
    }

    // MARK: - updatedPeers fold

    func testUpsertsNewPeers() {
        let peers = updatedPeers(
            [],
            applying: [
                AwarenessEntry(clientID: 2, clock: 1, stateJSON: ##"{"name":"Bo","color":"#111111"}"##),
                AwarenessEntry(clientID: 1, clock: 1, stateJSON: ##"{"name":"Ada","color":"#222222"}"##),
            ],
            excludingLocalClientID: 99)
        // Sorted by clientID for a stable avatar order.
        XCTAssertEqual(peers.map(\.clientID), [1, 2])
        XCTAssertEqual(peers.map(\.name), ["Ada", "Bo"])
    }

    func testExcludesLocalClientID() {
        // The server echoes our own awareness back; we must never show ourselves.
        let peers = updatedPeers(
            [],
            applying: [AwarenessEntry(clientID: 5, clock: 1, stateJSON: ##"{"name":"Me","color":"#333333"}"##)],
            excludingLocalClientID: 5)
        XCTAssertTrue(peers.isEmpty)
    }

    func testUpdatesAnExistingPeerInPlace() {
        let existing = try! XCTUnwrap(
            CollaborationPeer(clientID: 3, stateJSON: ##"{"name":"Old","color":"#000000"}"##))
        let peers = updatedPeers(
            [existing],
            applying: [AwarenessEntry(clientID: 3, clock: 2, stateJSON: ##"{"name":"New","color":"#ffffff"}"##)],
            excludingLocalClientID: 99)
        XCTAssertEqual(peers.count, 1)
        XCTAssertEqual(peers[0].name, "New")
    }

    func testNullStateRemovesAnExistingPeer() {
        let existing = try! XCTUnwrap(
            CollaborationPeer(clientID: 3, stateJSON: ##"{"name":"Bye","color":"#000000"}"##))
        let peers = updatedPeers(
            [existing],
            applying: [AwarenessEntry(clientID: 3, clock: 2, stateJSON: "null")],
            excludingLocalClientID: 99)
        XCTAssertTrue(peers.isEmpty)
    }

    func testInvalidStateRemovesAnExistingPeer() {
        // A state that no longer carries a name drops the peer rather than
        // leaving a stale avatar on screen.
        let existing = try! XCTUnwrap(
            CollaborationPeer(clientID: 3, stateJSON: ##"{"name":"Bye","color":"#000000"}"##))
        let peers = updatedPeers(
            [existing],
            applying: [AwarenessEntry(clientID: 3, clock: 2, stateJSON: ##"{"color":"#000000"}"##)],
            excludingLocalClientID: 99)
        XCTAssertTrue(peers.isEmpty)
    }
}
