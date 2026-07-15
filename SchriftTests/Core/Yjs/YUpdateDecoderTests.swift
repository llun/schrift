import XCTest

@testable import Schrift

/// Golden fixtures captured from **yjs@13.6.31** (the version the docs v5.4.1
/// lockfile resolves): `Y.encodeStateAsUpdate(doc)` / `Y.encodeStateVector(doc)`
/// with `doc.clientID` pinned to 42 (111/222 for the two-client merge), so the
/// bytes are reproducible. Regenerate with the scratchpad oracle in the PR body.
///
/// The load-bearing property is **identity re-encode**: for every update yjs
/// produces, `decode` then `encode` must return the exact bytes. That single
/// check exercises the wire grammar the fixtures cover — info bits, origins,
/// parent/parentSub, content refs 0 (GC), 1 (deleted), 3 (binary), 4 (string),
/// 5 (embed), 6 (format), 7 (type: array/map/text/xmlElement/fragment/xmlText),
/// 8 (any, incl. object/bigint/-0), 9 (doc), 10 (skip), and single- and
/// multi-client/multi-range delete sets — without asserting internal shape.
/// (Content ref 2, legacy `ContentJSON`, is not producible from current yjs APIs
/// and stays decode-only-by-symmetry; type ref 5, deprecated `xmlHook`, likewise.)
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
        // A ContentAny holding a JS -0 (tag 125, byte 0x40) — the case Swift's
        // `Int` flattens; it round-trips only via `.negativeZero`.
        "negativeZero": "01012a0008010161017d4000",
        // A ContentAny holding a nested object (any-tag 118).
        "objectAny": "01012a002801016d036f626a01760301617d010162770374776f01637800",
        // ContentTypes for the type refs the other fixtures miss: array(0), text(2), fragment(4).
        "typeRefs": "01032a002701016d03617272002701016d03747874022701016d04667261670400",
        // A ContentAny bigint (any-tag 122) alongside a ContentBinary value.
        "bigIntAndBinary": "01022a002801016d03626967017a00000b3a73ce2ff22301016d0275380309080700",
        // Deleting a nested Y.Map gc's its child → a GC struct (content ref 0).
        "gc": "010205002101016d01780100010105010002",
        // A subdocument value → ContentDoc (content ref 9: guid + options).
        "subdoc": "01012a002901016d0373756203616263760000",
        // Multi-client structs AND a multi-client, multi-range delete set —
        // decoded shape [{222:[[0,1]]}, {111:[[0,1],[2,1]]}].
        "multiClientDelete":
            "0202de0100816f020184de0100026566036f000101017401846f000162816f010102de010100016f0200010201",
        // A gapped merge leaves a Skip struct (content ref 10) between two runs.
        "skip": "01030500040101740241420a0284050302454600",
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

    func testGCAndSkipStructsRoundTripAndAdvanceTheClock() throws {
        let gc = try YUpdateDecoder.decode(Data(hex: updates["gc"]!))
        XCTAssertTrue(gc.blocks[0].structs.contains { if case .gc = $0 { return true } else { return false } })

        let skip = try YUpdateDecoder.decode(Data(hex: updates["skip"]!))
        let structs = skip.blocks[0].structs
        guard case .skip(let id, let length) = structs[1] else { return XCTFail("expected a Skip struct") }
        XCTAssertEqual(id.clock, 2)  // after "AB" (clocks 0–1)
        XCTAssertEqual(length, 2)
        // The run after the skip resumes at clock 4.
        guard case .item(let after) = structs[2] else { return XCTFail("expected an item after the skip") }
        XCTAssertEqual(after.id.clock, 4)
    }

    func testNegativeZeroDecodesToItsOwnCase() throws {
        let update = try YUpdateDecoder.decode(Data(hex: updates["negativeZero"]!))
        let anyValues = update.blocks[0].structs.compactMap { s -> [YAnyValue]? in
            if case .item(let item) = s, case .any(let values) = item.content { return values }
            return nil
        }.first
        XCTAssertEqual(anyValues, [.negativeZero])
    }

    func testSubdocumentDecodesToContentDoc() throws {
        let update = try YUpdateDecoder.decode(Data(hex: updates["subdoc"]!))
        let doc = update.blocks[0].structs.compactMap { s -> String? in
            if case .item(let item) = s, case .doc(let guid, _) = item.content { return guid }
            return nil
        }.first
        XCTAssertEqual(doc, "abc")
    }

    // MARK: - readAny round-trip (the any-tag codec, both directions)

    func testEveryAnyValueRoundTripsThroughWriteThenReadAny() throws {
        let values: [YAnyValue] = [
            .string("hi"), .int(-7), .int(1_000_000), .negativeZero,
            .float32(Data(hex: "3fc00000")), .float64(Data(hex: "423cbe991a140000")),
            .bigInt(Data(hex: "00000b3a73ce2ff2")), .bool(true), .bool(false), .null, .undefined,
            .uint8Array(Data([1, 2, 3, 255])),
            .array([.int(1), .string("two"), .bool(false)]),
            .object([
                YAnyObjectEntry(key: "a", value: .int(1)),
                YAnyObjectEntry(key: "b", value: .array([.null, .negativeZero])),
            ]),
        ]
        for value in values {
            var e = Lib0Encoder()
            e.writeAny(value)
            var d = Lib0Decoder(e.data)
            XCTAssertEqual(try d.readAny(), value, "writeAny→readAny diverged for \(value)")
            XCTAssertEqual(d.remainingCount, 0, "readAny left trailing bytes for \(value)")
        }
    }

    // MARK: - error handling

    func testTruncatedBufferThrows() {
        // A struct that claims content ref 9 (ContentDoc) but has no guid bytes
        // must surface as a decoding error, never a trap.
        XCTAssertThrowsError(try YUpdateDecoder.decode(Data(hex: "01012a0009")))
    }

    func testUnsupportedContentRefThrowsTheTypedError() {
        // info 0x0b → content ref 11 (never emitted by yjs); parent "t" is valid,
        // then the content decode rejects the ref.
        do {
            _ = try YUpdateDecoder.decode(Data(hex: "01012a000b010174"))
            XCTFail("expected unsupportedContentRef")
        } catch let error as YWireError {
            XCTAssertEqual(error, .unsupportedContentRef(11))
        } catch {
            XCTFail("expected YWireError, got \(error)")
        }
    }

    func testUnsupportedTypeRefThrowsTheTypedError() {
        // info 0x07 → ContentType; parent "t"; then type ref 99 is out of range.
        do {
            _ = try YUpdateDecoder.decode(Data(hex: "01012a000701017463"))
            XCTFail("expected unsupportedTypeRef")
        } catch let error as YWireError {
            XCTAssertEqual(error, .unsupportedTypeRef(99))
        } catch {
            XCTFail("expected YWireError, got \(error)")
        }
    }
}
