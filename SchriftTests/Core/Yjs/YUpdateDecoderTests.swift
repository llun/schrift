import XCTest

@testable import Schrift

/// Golden fixtures captured from **yjs@13.6.31** (the version the docs v5.4.1
/// lockfile resolves): `Y.encodeStateAsUpdate(doc)` / `Y.encodeStateVector(doc)`
/// with `doc.clientID` pinned to 42 (111/222 for the two-client merge), so the
/// bytes are reproducible. Regenerate with the scratchpad oracle in the PR body.
///
/// The load-bearing property is **identity re-encode**: for every update yjs
/// produces, `decode` then `encode` must return the exact bytes. That single
/// check exercises the whole wire grammar (info bits, origins, parent/parentSub,
/// all content refs, the delete set) without needing to assert internal shape.
final class YUpdateDecoderTests: XCTestCase {
    private let updates: [String: String] = [
        "textInsert": "01012a000401017402486900",
        "textDelete": "01032a00040101740148812a0002842a02026c6f012a010102",
        "xml": "01032a0007010e646f63756d656e742d73746f7265030e626c6f636b436f6e7461696e657207002a000604002a01017800",
        "mapAny":
            "01062a002801016d0169017d2a2801016d0166017c406000002801016d016201782801016d016e017e2801016d017301770268692801016d036172720175037d01770374776f7900",
        "deleted": "01012a000101017403012a010003",
        "embed": "01012a00050101740d7b22696d616765223a2278227d00",
        "format": "01032a00040101740161462a0004626f6c640474727565862a0004626f6c64046e756c6c00",
        "nestedMap": "01022a002701016d05696e6e65720128002a00016b0177017600",
        "binary": "01012a002301016d0362696e04010203ff00",
        "anyNums":
            "01042a002801016d036e6567017d472801016d03666c74017c3fc000002801016d03626967017b423cbe991a1400002801016d06663332626967017c5a00000000",
        "mapOverwrite": "01022a002101016d016b02a82a0101770163012a010002",
        "twoClient": "0201de0100040101740142016f0004010174014100",
    ]

    private let stateVectors: [String: String] = [
        "textInsert": "012a02", "textDelete": "012a05", "mapAny": "012a06",
        "twoClient": "02de01016f01", "empty": "00",
    ]

    // MARK: - identity round-trip (the core property)

    func testEveryUpdateReEncodesToTheExactBytes() throws {
        for (name, hex) in updates {
            let data = Data(hex: hex)
            let update = try YUpdateDecoder.decode(data)
            XCTAssertEqual(
                YUpdateReencoder.encode(update).hexString, hex,
                "identity re-encode diverged for update '\(name)'")
        }
    }

    func testEveryStateVectorReEncodesToTheExactBytes() throws {
        for (name, hex) in stateVectors {
            let sv = try YUpdateDecoder.decodeStateVector(Data(hex: hex))
            XCTAssertEqual(
                YUpdateReencoder.encodeStateVector(sv).hexString, hex,
                "identity re-encode diverged for state vector '\(name)'")
        }
    }

    // MARK: - structural spot checks

    func testTextInsertDecodesToOneContentStringItem() throws {
        let update = try YUpdateDecoder.decode(Data(hex: updates["textInsert"]!))
        XCTAssertEqual(update.blocks.count, 1)
        XCTAssertEqual(update.blocks[0].client, 42)
        guard case .item(let item) = update.blocks[0].structs[0] else { return XCTFail("expected an item") }
        XCTAssertEqual(item.id, YID(client: 42, clock: 0))
        XCTAssertEqual(item.parent, .named("t"))
        XCTAssertNil(item.origin)
        XCTAssertEqual(item.content, .string("Hi"))
        XCTAssertTrue(update.deleteSet.isEmpty)
    }

    func testDeletedTextCarriesADeleteSet() throws {
        let update = try YUpdateDecoder.decode(Data(hex: updates["deleted"]!))
        guard case .item(let item) = update.blocks[0].structs[0] else { return XCTFail("expected an item") }
        XCTAssertEqual(item.content, .deleted(length: 3))
        XCTAssertEqual(update.deleteSet, [YDeleteBlock(client: 42, ranges: [YDeleteRange(clock: 0, length: 3)])])
    }

    func testFormatItemsCarryOriginAndRightOrigin() throws {
        let update = try YUpdateDecoder.decode(Data(hex: updates["format"]!))
        let structs = update.blocks[0].structs
        XCTAssertEqual(structs.count, 3)
        guard case .item(let open) = structs[1], case .item(let close) = structs[2] else {
            return XCTFail("expected two format items")
        }
        // The opening mark carries a right origin; the closing mark a left origin.
        XCTAssertEqual(open.content, .format(key: "bold", valueJSON: "true"))
        XCTAssertNotNil(open.rightOrigin)
        XCTAssertEqual(close.content, .format(key: "bold", valueJSON: "null"))
        XCTAssertEqual(close.origin, YID(client: 42, clock: 0))
    }

    func testOverwrittenMapKeyHasAnItemWithBothAnOriginAndTheParentSubBit() throws {
        // The subtle case the raw `info` byte exists for: struct 2 inherits its
        // parent from an origin, so no parentSub is on the wire, yet info keeps the
        // 0x20 bit — only a verbatim replay of `info` re-encodes byte-identically.
        let update = try YUpdateDecoder.decode(Data(hex: updates["mapOverwrite"]!))
        guard case .item(let second) = update.blocks[0].structs[1] else { return XCTFail("expected an item") }
        XCTAssertNotNil(second.origin)
        XCTAssertEqual(second.info & 0x20, 0x20, "parentSub bit is set even though the string is not on the wire")
        XCTAssertNil(second.parentSub, "no parentSub string is read when the parent is copied from an origin")
        XCTAssertEqual(second.content, .any([.string("c")]))
    }

    func testTwoClientUpdateHasABlockPerClientInWireOrder() throws {
        let update = try YUpdateDecoder.decode(Data(hex: updates["twoClient"]!))
        XCTAssertEqual(update.blocks.map(\.client), [222, 111])
    }

    func testNestedMapUsesAContentType() throws {
        let update = try YUpdateDecoder.decode(Data(hex: updates["nestedMap"]!))
        let hasMapType = update.blocks[0].structs.contains {
            if case .item(let item) = $0, case .type(.map) = item.content { return true }
            return false
        }
        XCTAssertTrue(hasMapType, "the nested Y.Map should decode as a ContentType(.map)")
    }

    func testBinaryContentRoundTripsItsBytes() throws {
        let update = try YUpdateDecoder.decode(Data(hex: updates["binary"]!))
        let binary = update.blocks[0].structs.compactMap { s -> Data? in
            if case .item(let item) = s, case .binary(let data) = item.content { return data }
            return nil
        }.first
        XCTAssertEqual(binary, Data([1, 2, 3, 255]))
    }

    // MARK: - error handling

    func testUnsupportedContentRefThrows() {
        // A struct claiming content ref 9 (ContentDoc) needs a guid+any; a
        // truncated buffer surfaces as a decoding error, never a trap.
        XCTAssertThrowsError(try YUpdateDecoder.decode(Data(hex: "01012a0009")))
    }
}
