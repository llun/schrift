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

    func testTheSameStateAlwaysEncodesToTheSameBytes() {
        // Peers compare re-broadcasts byte for byte; Swift dictionaries don't keep key order.
        for wire in [CollaborationWireProtocol.hocuspocus, .yWebSocket] {
            let encodings = Set(
                (0..<50).map { _ in LocalAwarenessState(name: "Ada", color: "#123456").json(wireProtocol: wire) })
            XCTAssertEqual(encodings.count, 1, "\(wire): \(encodings)")
        }
        XCTAssertEqual(
            LocalAwarenessState(name: "Ada", color: "#123456").json(wireProtocol: .yWebSocket),
            ##"{"user":{"color":"#123456","name":"Ada"}}"##, "keys are sorted, so every encoding is identical")
    }

    func testNestedAwarenessIsProtocolSpecificAndEscapesUserName() throws {
        let state = LocalAwarenessState(name: "A\"da\\B", color: "#123456")
        let json = state.json(wireProtocol: .yWebSocket)
        let peer = try XCTUnwrap(CollaborationPeer(clientID: 7, stateJSON: json, wireProtocol: .yWebSocket))
        XCTAssertEqual(peer.name, state.name)
        XCTAssertEqual(peer.color, state.color)
        XCTAssertNil(CollaborationPeer(clientID: 7, stateJSON: json), "Hocuspocus keeps its flat shape")
        XCTAssertNil(CollaborationPeer(clientID: 7, stateJSON: state.json(), wireProtocol: .yWebSocket))
        for invalid in ["null", "{}", "{\"user\":null}", "{\"user\":{\"name\":\"\",\"color\":\"red\"}}"] {
            XCTAssertNil(CollaborationPeer(clientID: 7, stateJSON: invalid, wireProtocol: .yWebSocket))
        }
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
        let folded = updatedPeers(
            [], clocks: [:],
            applying: [
                AwarenessEntry(clientID: 2, clock: 1, stateJSON: ##"{"name":"Bo","color":"#111111"}"##),
                AwarenessEntry(clientID: 1, clock: 1, stateJSON: ##"{"name":"Ada","color":"#222222"}"##),
            ],
            excludingLocalClientID: 99)
        // Sorted by clientID for a stable avatar order.
        XCTAssertEqual(folded.peers.map(\.clientID), [1, 2])
        XCTAssertEqual(folded.peers.map(\.name), ["Ada", "Bo"])
        XCTAssertEqual(folded.clocks, [1: 1, 2: 1])
    }

    func testExcludesLocalClientID() {
        // The server echoes our own awareness back; we must never show ourselves.
        let folded = updatedPeers(
            [], clocks: [:],
            applying: [AwarenessEntry(clientID: 5, clock: 1, stateJSON: ##"{"name":"Me","color":"#333333"}"##)],
            excludingLocalClientID: 5)
        XCTAssertTrue(folded.peers.isEmpty)
    }

    func testUpdatesAnExistingPeerInPlace() throws {
        let existing = try XCTUnwrap(
            CollaborationPeer(clientID: 3, stateJSON: ##"{"name":"Old","color":"#000000"}"##))
        let folded = updatedPeers(
            [existing], clocks: [3: 1],
            applying: [AwarenessEntry(clientID: 3, clock: 2, stateJSON: ##"{"name":"New","color":"#ffffff"}"##)],
            excludingLocalClientID: 99)
        XCTAssertEqual(folded.peers.count, 1)
        XCTAssertEqual(folded.peers.first?.name, "New")
    }

    func testNullStateRemovesAnExistingPeer() throws {
        let existing = try XCTUnwrap(
            CollaborationPeer(clientID: 3, stateJSON: ##"{"name":"Bye","color":"#000000"}"##))
        let folded = updatedPeers(
            [existing], clocks: [3: 1],
            applying: [AwarenessEntry(clientID: 3, clock: 2, stateJSON: "null")],
            excludingLocalClientID: 99)
        XCTAssertTrue(folded.peers.isEmpty)
    }

    func testInvalidStateRemovesAnExistingPeer() throws {
        // A state that no longer carries a name drops the peer rather than
        // leaving a stale avatar on screen.
        let existing = try XCTUnwrap(
            CollaborationPeer(clientID: 3, stateJSON: ##"{"name":"Bye","color":"#000000"}"##))
        let folded = updatedPeers(
            [existing], clocks: [3: 1],
            applying: [AwarenessEntry(clientID: 3, clock: 2, stateJSON: ##"{"color":"#000000"}"##)],
            excludingLocalClientID: 99)
        XCTAssertTrue(folded.peers.isEmpty)
    }

    // MARK: - updatedPeers bounds (inbound awareness is untrusted)

    func testIgnoresAnEntryOverTheStateByteCap() {
        let oversized =
            ##"{"name":"\##(String(repeating: "a", count: NativeAwarenessController.maxStateBytes))","color":"#000000"}"##
        let folded = updatedPeers(
            [], clocks: [:],
            applying: [AwarenessEntry(clientID: 1, clock: 1, stateJSON: oversized)],
            excludingLocalClientID: 99)
        XCTAssertTrue(folded.peers.isEmpty, "an entry over the byte cap is skipped")
    }

    func testRefusesANewPeerOnceTheCapIsReached() {
        let full = (1...NativeAwarenessController.maxPeers).map {
            AwarenessEntry(clientID: UInt($0), clock: 1, stateJSON: ##"{"name":"P\##($0)","color":"#000000"}"##)
        }
        let folded = updatedPeers(
            [], clocks: [:], applying: full, excludingLocalClientID: 99)
        XCTAssertEqual(folded.peers.count, NativeAwarenessController.maxPeers)

        let over = updatedPeers(
            folded.peers, clocks: folded.clocks,
            applying: [AwarenessEntry(clientID: 999, clock: 1, stateJSON: ##"{"name":"Late","color":"#000000"}"##)],
            excludingLocalClientID: 99)
        XCTAssertEqual(over.peers.count, NativeAwarenessController.maxPeers, "a new client is refused at the cap")
        XCTAssertNil(over.peers.first { $0.clientID == 999 })
    }

    func testIgnoresAnEntryWhoseClockIsNotNewer() throws {
        let existing = try XCTUnwrap(
            CollaborationPeer(clientID: 3, stateJSON: ##"{"name":"New","color":"#ffffff"}"##))
        for clock in [1, 2] {
            let folded = updatedPeers(
                [existing], clocks: [3: 2],
                applying: [
                    AwarenessEntry(clientID: 3, clock: UInt(clock), stateJSON: ##"{"name":"Old","color":"#000000"}"##)
                ],
                excludingLocalClientID: 99)
            XCTAssertEqual(folded.peers.first?.name, "New", "clock \(clock) is not newer than 2")
        }
    }
}
