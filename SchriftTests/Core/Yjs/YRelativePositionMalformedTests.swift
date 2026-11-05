import XCTest

@testable import Schrift

/// Malformed relative-position input: every case must throw or resolve to nil
/// exactly where yjs does, and **never trap** — these bytes can arrive from a peer
/// (a cursor in awareness state is a relative position), and a trap is a remote
/// crash that no `catch` can intercept.
final class YRelativePositionMalformedTests: XCTestCase {
    /// A root text `t` holding "abc" as one item at clocks 0..2, authored locally
    /// so the fixture needs no wire bytes.
    private func makeTextDoc() throws -> YDoc {
        let doc = YDoc(clientID: 9, gc: false)
        try doc.transact { transaction in
            try YWrite.insert(
                transaction, into: doc.get("t"), at: 0, [.string(Array("abc".utf16))])
        }
        return doc
    }

    // MARK: - Truncated bytes

    func testTruncatedBytesThrow() {
        let truncated = [
            "",  // no kind tag
            "00",  // item id: no client
            "0001",  // item id: no clock
            "01",  // tname: no length
            "0105",  // tname: length 5, no bytes
            "02",  // type id: no client
            "0201",  // type id: no clock
            "00010280",  // assoc varint with a dangling continuation byte
        ]

        for hex in truncated {
            assertThrows(Lib0DecodingError.truncated) {
                _ = try YRelativePosition.decode(Data(hex: hex))
            }
        }
    }

    // MARK: - Unknown kind tag

    /// yjs's `switch` has no `default`: an unknown tag leaves every field null and
    /// the assoc read still runs. Mirrored — the bytes are accepted, the position
    /// is just unusable (encoding or resolving it is `unexpectedCase`).
    func testUnknownKindTagDecodesToAnUnresolvablePosition() throws {
        let position = try YRelativePosition.decode(Data(hex: "03"))
        XCTAssertEqual(position, YRelativePosition())
        XCTAssertEqual(try YRelativePosition.decode(Data(hex: "0341")), YRelativePosition(assoc: -1))

        assertThrows(YIntegrationError.unexpectedCase) { _ = try position.encode() }
        let doc = try makeTextDoc()
        assertThrows(YIntegrationError.unexpectedCase) { _ = try position.resolve(in: doc) }
    }

    // MARK: - Varints

    /// Eleven continuation bytes. `Lib0Decoder`'s documented narrowing: lib0's own
    /// reader accumulates into a JS number and returns NaN here, so this is
    /// stricter than yjs — but it throws a catchable error instead of trapping,
    /// which is the property that matters for peer input.
    func testOverlongVarintThrowsRatherThanTrapping() {
        assertThrows(Lib0DecodingError.malformedVarInt) {
            _ = try YRelativePosition.decode(Data(hex: "8080808080808080808000"))
        }
    }

    /// A non-canonical encoding of a small number is accepted, as lib0 accepts it.
    /// Rejecting it would be stricter than yjs.
    func testNonCanonicalShortVarintIsAccepted() throws {
        XCTAssertEqual(
            try YRelativePosition.decode(Data(hex: "80000102")),
            YRelativePosition(item: YID(client: 1, clock: 2)))
    }

    /// `decodeRelativePosition` does not require the buffer to be consumed; trailing
    /// bytes are ignored. Being stricter here would reject bytes yjs accepts.
    func testTrailingBytesAreIgnored() throws {
        XCTAssertEqual(
            try YRelativePosition.decode(Data(hex: "01017400ff")), YRelativePosition(tname: "t"))
    }

    // MARK: - Encoding an empty position

    func testAnEmptyPositionCannotBeEncoded() {
        assertThrows(YIntegrationError.unexpectedCase) { _ = try YRelativePosition().encode() }
    }

    // MARK: - Resolving against a document

    /// A control, so the nil cases below mean "yjs returns nil here" rather than
    /// "resolve is broken".
    func testAControlPositionResolves() throws {
        let doc = try makeTextDoc()
        let resolved = try XCTUnwrap(
            YRelativePosition(item: YID(client: 9, clock: 1)).resolve(in: doc))
        XCTAssertTrue(resolved.type === doc.get("t"))
        XCTAssertEqual(resolved.index, 1)
    }

    /// yjs calls `doc.get(tname)`, which **creates** the root — so an unknown name
    /// is not nil, it resolves to index 0 of a fresh empty type.
    func testAnUnknownTnameResolvesToAFreshEmptyRoot() throws {
        let doc = try makeTextDoc()

        let right = try XCTUnwrap(YRelativePosition(tname: "nope", assoc: 0).resolve(in: doc))
        XCTAssertTrue(right.type === doc.get("nope"))
        XCTAssertEqual(right.index, 0)

        let left = try XCTUnwrap(YRelativePosition(tname: "nope", assoc: -1).resolve(in: doc))
        XCTAssertEqual(left.index, 0)
    }

    /// A clock past the client's state means the struct has not arrived: nil, for
    /// both the item and the type branch. An unknown client has state 0, so every
    /// clock is past it.
    func testAClockPastTheClientsStateResolvesToNil() throws {
        let doc = try makeTextDoc()

        XCTAssertNil(try YRelativePosition(item: YID(client: 9, clock: 3)).resolve(in: doc))
        XCTAssertNil(try YRelativePosition(item: YID(client: 9, clock: 99)).resolve(in: doc))
        XCTAssertNil(try YRelativePosition(type: YID(client: 9, clock: 3)).resolve(in: doc))
        XCTAssertNil(try YRelativePosition(item: YID(client: 7, clock: 0)).resolve(in: doc))
        XCTAssertNil(try YRelativePosition(type: YID(client: 7, clock: 0)).resolve(in: doc))
    }

    /// A type id that resolves to a struct which is not a `ContentType` — yjs's
    /// "struct is garbage collected" branch.
    func testATypeIDThatIsNotAContentTypeResolvesToNil() throws {
        let doc = try makeTextDoc()
        // (9, 0) is the "abc" string item, not a type.
        XCTAssertNil(try YRelativePosition(type: YID(client: 9, clock: 0)).resolve(in: doc))
    }

    // MARK: - JSON edge cases

    /// yjs's `if (rpos.tname)` drops an empty name, and
    /// `json.assoc == null ? 0 : json.assoc` defaults a missing assoc.
    func testJSONOmitsAnEmptyTnameAndDefaultsAMissingAssoc() throws {
        XCTAssertNil(YRelativePosition(tname: "").json.tname)

        let decoded = try JSONDecoder().decode(
            YRelativePositionJSON.self, from: Data(#"{"tname":"t"}"#.utf8))
        XCTAssertEqual(YRelativePosition(json: decoded), YRelativePosition(tname: "t", assoc: 0))
    }
}
