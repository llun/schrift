import XCTest

@testable import Schrift

/// Oracle fixtures captured from **yjs 13.6.33** (the version the Docs 6 frontend
/// lockfile resolves) with a session-local node script (never committed — the
/// repo's zero-third-party-dependency rule):
///
/// ```js
/// const a = new Y.Doc(); a.clientID = 1
/// build(a)                                   // the scenario's seed document
/// const seed = Y.encodeStateAsUpdate(a)
/// const t = locate(a)
/// for (const assoc of [0, -1]) for (let i = 0; i <= t.length; i++) {
///   const rp = Y.createRelativePositionFromTypeIndex(t, i, assoc)
///   capture({ index: i, assoc, hex: hex(Y.encodeRelativePosition(rp)),
///             json: Y.relativePositionToJSON(rp) })
/// }
/// const b = new Y.Doc(); b.clientID = 2; Y.applyUpdate(b, seed)
/// for (const [label, fn] of mutations) {     // cumulative, one delta each
///   const sv = Y.encodeStateVector(b); fn(locate(b), b)
///   step({ label, update: hex(Y.encodeStateAsUpdate(b, sv)),
///          resolved: captures.map(c => {
///            const ap = Y.createAbsolutePositionFromRelativePosition(c.rp, b)
///            return ap && ap.type === locate(b) ? ap.index : null }) })
/// }
/// ```
///
/// Four scenarios cover the shapes that matter: a nested `XmlText` (positions
/// encode the type by **id**), a root `YText` (by **tname**), an empty root text
/// (length 0), and a root fragment's element children (list positions). The
/// mutations include an insert that splits an item, a delete of the captured
/// target, an append, and a delete-everything.
private enum YRelativePositionOracle {
    static let json = #"""
        {
          "yjs": "13.6.33",
          "scenarios": [
            {
              "name": "nested-xmltext",
              "seed": "0103010007010e646f63756d656e742d73746f726503097061726167726170680700010006040001010b68656c6c6f20776f726c6400",
              "length": 11,
              "captures": [
                { "index": 0, "assoc": 0, "hex": "00010200", "json": {"type":{"client":1,"clock":1},"item":{"client":1,"clock":2},"assoc":0} },
                { "index": 1, "assoc": 0, "hex": "00010300", "json": {"type":{"client":1,"clock":1},"item":{"client":1,"clock":3},"assoc":0} },
                { "index": 2, "assoc": 0, "hex": "00010400", "json": {"type":{"client":1,"clock":1},"item":{"client":1,"clock":4},"assoc":0} },
                { "index": 3, "assoc": 0, "hex": "00010500", "json": {"type":{"client":1,"clock":1},"item":{"client":1,"clock":5},"assoc":0} },
                { "index": 4, "assoc": 0, "hex": "00010600", "json": {"type":{"client":1,"clock":1},"item":{"client":1,"clock":6},"assoc":0} },
                { "index": 5, "assoc": 0, "hex": "00010700", "json": {"type":{"client":1,"clock":1},"item":{"client":1,"clock":7},"assoc":0} },
                { "index": 6, "assoc": 0, "hex": "00010800", "json": {"type":{"client":1,"clock":1},"item":{"client":1,"clock":8},"assoc":0} },
                { "index": 7, "assoc": 0, "hex": "00010900", "json": {"type":{"client":1,"clock":1},"item":{"client":1,"clock":9},"assoc":0} },
                { "index": 8, "assoc": 0, "hex": "00010a00", "json": {"type":{"client":1,"clock":1},"item":{"client":1,"clock":10},"assoc":0} },
                { "index": 9, "assoc": 0, "hex": "00010b00", "json": {"type":{"client":1,"clock":1},"item":{"client":1,"clock":11},"assoc":0} },
                { "index": 10, "assoc": 0, "hex": "00010c00", "json": {"type":{"client":1,"clock":1},"item":{"client":1,"clock":12},"assoc":0} },
                { "index": 11, "assoc": 0, "hex": "02010100", "json": {"type":{"client":1,"clock":1},"assoc":0} },
                { "index": 0, "assoc": -1, "hex": "02010141", "json": {"type":{"client":1,"clock":1},"assoc":-1} },
                { "index": 1, "assoc": -1, "hex": "00010241", "json": {"type":{"client":1,"clock":1},"item":{"client":1,"clock":2},"assoc":-1} },
                { "index": 2, "assoc": -1, "hex": "00010341", "json": {"type":{"client":1,"clock":1},"item":{"client":1,"clock":3},"assoc":-1} },
                { "index": 3, "assoc": -1, "hex": "00010441", "json": {"type":{"client":1,"clock":1},"item":{"client":1,"clock":4},"assoc":-1} },
                { "index": 4, "assoc": -1, "hex": "00010541", "json": {"type":{"client":1,"clock":1},"item":{"client":1,"clock":5},"assoc":-1} },
                { "index": 5, "assoc": -1, "hex": "00010641", "json": {"type":{"client":1,"clock":1},"item":{"client":1,"clock":6},"assoc":-1} },
                { "index": 6, "assoc": -1, "hex": "00010741", "json": {"type":{"client":1,"clock":1},"item":{"client":1,"clock":7},"assoc":-1} },
                { "index": 7, "assoc": -1, "hex": "00010841", "json": {"type":{"client":1,"clock":1},"item":{"client":1,"clock":8},"assoc":-1} },
                { "index": 8, "assoc": -1, "hex": "00010941", "json": {"type":{"client":1,"clock":1},"item":{"client":1,"clock":9},"assoc":-1} },
                { "index": 9, "assoc": -1, "hex": "00010a41", "json": {"type":{"client":1,"clock":1},"item":{"client":1,"clock":10},"assoc":-1} },
                { "index": 10, "assoc": -1, "hex": "00010b41", "json": {"type":{"client":1,"clock":1},"item":{"client":1,"clock":11},"assoc":-1} },
                { "index": 11, "assoc": -1, "hex": "00010c41", "json": {"type":{"client":1,"clock":1},"item":{"client":1,"clock":12},"assoc":-1} }
              ],
              "steps": [
                { "label": "peer inserts \"XY\" at 0", "update": "0101020044010202585900", "resolved": [2,3,4,5,6,7,8,9,10,11,12,13,0,3,4,5,6,7,8,9,10,11,12,13] },
                { "label": "peer inserts \"--\" at 5 (splits the item)", "update": "01010202c401040105022d2d00", "resolved": [2,3,4,7,8,9,10,11,12,13,14,15,0,3,4,5,8,9,10,11,12,13,14,15] },
                { "label": "peer deletes 3 at 4", "update": "00020201020201010401", "resolved": [2,3,4,4,5,6,7,8,9,10,11,12,0,3,4,4,5,6,7,8,9,10,11,12] },
                { "label": "peer appends \"!\"", "update": "0101020484010c0121020201020201010401", "resolved": [2,3,4,4,5,6,7,8,9,10,11,13,0,3,4,4,5,6,7,8,9,10,11,12] },
                { "label": "peer deletes everything", "update": "0002020100050101020b", "resolved": [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0] }
              ]
            },
            {
              "name": "root-text",
              "seed": "01010100040101740361626300",
              "length": 3,
              "captures": [
                { "index": 0, "assoc": 0, "hex": "00010000", "json": {"tname":"t","item":{"client":1,"clock":0},"assoc":0} },
                { "index": 1, "assoc": 0, "hex": "00010100", "json": {"tname":"t","item":{"client":1,"clock":1},"assoc":0} },
                { "index": 2, "assoc": 0, "hex": "00010200", "json": {"tname":"t","item":{"client":1,"clock":2},"assoc":0} },
                { "index": 3, "assoc": 0, "hex": "01017400", "json": {"tname":"t","assoc":0} },
                { "index": 0, "assoc": -1, "hex": "01017441", "json": {"tname":"t","assoc":-1} },
                { "index": 1, "assoc": -1, "hex": "00010041", "json": {"tname":"t","item":{"client":1,"clock":0},"assoc":-1} },
                { "index": 2, "assoc": -1, "hex": "00010141", "json": {"tname":"t","item":{"client":1,"clock":1},"assoc":-1} },
                { "index": 3, "assoc": -1, "hex": "00010241", "json": {"tname":"t","item":{"client":1,"clock":2},"assoc":-1} }
              ],
              "steps": [
                { "label": "peer inserts \"Z\" at 1", "update": "01010200c401000101015a00", "resolved": [0,2,3,4,0,1,3,4] },
                { "label": "peer deletes 0..2", "update": "00020201000101010001", "resolved": [0,0,1,2,0,0,1,2] }
              ]
            },
            {
              "name": "empty-root-text",
              "seed": "0000",
              "length": 0,
              "captures": [
                { "index": 0, "assoc": 0, "hex": "01016500", "json": {"tname":"e","assoc":0} },
                { "index": 0, "assoc": -1, "hex": "01016541", "json": {"tname":"e","assoc":-1} }
              ],
              "steps": [
                { "label": "peer inserts \"q\"", "update": "0101020004010165017100", "resolved": [1,0] }
              ]
            },
            {
              "name": "fragment-children",
              "seed": "0103010007010e646f63756d656e742d73746f726503016187010003016287010103016300",
              "length": 3,
              "captures": [
                { "index": 0, "assoc": 0, "hex": "00010000", "json": {"tname":"document-store","item":{"client":1,"clock":0},"assoc":0} },
                { "index": 1, "assoc": 0, "hex": "00010100", "json": {"tname":"document-store","item":{"client":1,"clock":1},"assoc":0} },
                { "index": 2, "assoc": 0, "hex": "00010200", "json": {"tname":"document-store","item":{"client":1,"clock":2},"assoc":0} },
                { "index": 3, "assoc": 0, "hex": "010e646f63756d656e742d73746f726500", "json": {"tname":"document-store","assoc":0} },
                { "index": 0, "assoc": -1, "hex": "010e646f63756d656e742d73746f726541", "json": {"tname":"document-store","assoc":-1} },
                { "index": 1, "assoc": -1, "hex": "00010041", "json": {"tname":"document-store","item":{"client":1,"clock":0},"assoc":-1} },
                { "index": 2, "assoc": -1, "hex": "00010141", "json": {"tname":"document-store","item":{"client":1,"clock":1},"assoc":-1} },
                { "index": 3, "assoc": -1, "hex": "00010241", "json": {"tname":"document-store","item":{"client":1,"clock":2},"assoc":-1} }
              ],
              "steps": [
                { "label": "peer inserts element at 1", "update": "01010200c70100010103017a00", "resolved": [0,2,3,4,0,1,3,4] },
                { "label": "peer deletes index 0", "update": "000101010001", "resolved": [0,1,2,3,0,0,2,3] }
              ]
            }
          ]
        }
        """#
}

private struct OracleFixture: Decodable {
    let yjs: String
    let scenarios: [Scenario]

    struct Scenario: Decodable {
        let name: String
        let seed: String
        let length: Int
        let captures: [Capture]
        let steps: [Step]
    }

    struct Capture: Decodable {
        let index: Int
        let assoc: Int
        let hex: String
        let json: YRelativePositionJSON
    }

    struct Step: Decodable {
        let label: String
        let update: String
        let resolved: [Int?]
    }
}

final class YRelativePositionTests: XCTestCase {
    // MARK: - Fixture

    private func oracle() throws -> OracleFixture {
        try JSONDecoder().decode(
            OracleFixture.self, from: Data(YRelativePositionOracle.json.utf8))
    }

    /// A replica built from a scenario's seed. gc is off (the golden-fixture
    /// default); the oracle's `new Y.Doc()` had it on, and the two agree here
    /// because every deleted item stays in the store either way — gc only swaps
    /// its content for a tombstone, and `resolve` reads `deleted`/`countable`.
    private func makeDoc(clientID: UInt, seed: String) throws -> YDoc {
        let doc = YDoc(clientID: clientID, gc: false)
        try doc.applyUpdate(try YUpdateDecoder.decode(Data(hex: seed)))
        return doc
    }

    /// The type each scenario captured positions in — the oracle's `locate`.
    private func locate(_ scenario: String, in doc: YDoc) throws -> YType {
        switch scenario {
        case "nested-xmltext":
            // document-store → paragraph (XmlElement) → its XmlText child.
            let paragraph = try XCTUnwrap(childType(of: doc.get("document-store"), at: 0))
            return try XCTUnwrap(childType(of: paragraph, at: 0))
        case "root-text":
            return doc.get("t")
        case "empty-root-text":
            return doc.get("e")
        case "fragment-children":
            return doc.get("document-store")
        default:
            throw YIntegrationError.unexpectedCase
        }
    }

    private func childType(of type: YType, at index: Int) -> YType? {
        var item = type.start
        var visible = 0
        while let current = item {
            if !current.deleted && current.countable {
                if visible == index, case .type(let child) = current.content { return child }
                visible += 1
            }
            item = current.right
        }
        return nil
    }

    // MARK: - Capture

    /// `createRelativePositionFromTypeIndex` for every index and assoc must encode
    /// to the oracle's bytes and convert to its JSON.
    func testCaptureMatchesYjsForEveryIndexAndAssoc() throws {
        let oracle = try oracle()
        XCTAssertEqual(oracle.yjs, "13.6.33")

        for scenario in oracle.scenarios {
            let doc = try makeDoc(clientID: 9, seed: scenario.seed)
            let type = try locate(scenario.name, in: doc)
            XCTAssertEqual(
                Int(type.length), scenario.length, "\(scenario.name): seed length")

            for capture in scenario.captures {
                let label = "\(scenario.name) index \(capture.index) assoc \(capture.assoc)"
                let position = try YRelativePosition.fromTypeIndex(
                    type, index: UInt(capture.index), assoc: capture.assoc)
                XCTAssertEqual(try position.encode().hexString, capture.hex, "\(label): bytes")
                XCTAssertEqual(position.json, capture.json, "\(label): JSON")
            }
        }
    }

    // MARK: - Decode

    /// Every captured byte string decodes and re-encodes byte-identically, and its
    /// JSON round-trips through the value type.
    ///
    /// The wire is **lossy in one direction**: yjs's case 1 (an item id) does not
    /// carry the type — it is implied by the item's parent — so only the
    /// end-of-type encodings (cases 2/3) round-trip `type`. The oracle's `json` is
    /// the *captured* position, so the type is expected back only when the item is
    /// absent.
    func testDecodeReEncodesByteIdenticallyAndRoundTripsJSON() throws {
        let oracle = try oracle()

        for scenario in oracle.scenarios {
            for capture in scenario.captures {
                let label = "\(scenario.name) index \(capture.index) assoc \(capture.assoc)"
                let decoded = try YRelativePosition.decode(Data(hex: capture.hex))
                XCTAssertEqual(try decoded.encode().hexString, capture.hex, "\(label): re-encode")
                let expected = YRelativePosition(
                    type: capture.json.item == nil ? capture.json.type : nil,
                    tname: capture.json.item == nil ? capture.json.tname : nil,
                    item: capture.json.item,
                    assoc: capture.json.assoc ?? 0)
                XCTAssertEqual(decoded, expected, "\(label): wire fields")
                XCTAssertEqual(
                    YRelativePosition(json: decoded.json), decoded, "\(label): JSON round-trip")
            }
        }
    }

    // MARK: - Resolve

    /// After each cumulative peer step, every capture resolves to the oracle's
    /// index in the same type — including a deleted target, a split target, an
    /// append, and a delete-everything.
    func testResolveMatchesYjsAfterEachCumulativeStep() throws {
        let oracle = try oracle()

        for scenario in oracle.scenarios {
            let doc = try makeDoc(clientID: 2, seed: scenario.seed)
            let captures = try scenario.captures.map {
                try YRelativePosition.decode(Data(hex: $0.hex))
            }

            for step in scenario.steps {
                try doc.applyUpdate(try YUpdateDecoder.decode(Data(hex: step.update)))
                let type = try locate(scenario.name, in: doc)

                for (offset, capture) in scenario.captures.enumerated() {
                    let label =
                        "\(scenario.name) / \(step.label) / index \(capture.index) assoc \(capture.assoc)"
                    let resolved = try captures[offset].resolve(in: doc)
                    guard let expected = step.resolved[offset] else {
                        XCTAssertNil(resolved, "\(label): expected nil")
                        continue
                    }
                    let absolute = try XCTUnwrap(resolved, "\(label): expected \(expected), got nil")
                    XCTAssertTrue(absolute.type === type, "\(label): resolved in a different type")
                    XCTAssertEqual(Int(absolute.index), expected, "\(label): index")
                }
            }
        }
    }

    // MARK: - The C2 end-of-paragraph regression

    /// The spike's IME bug: composing at the end of a paragraph committed one
    /// character early because the capture at `index == length` returned the last
    /// character's id and resolve ignored `assoc`.
    ///
    /// The two captures at `index == length` must differ: `assoc 0` is the
    /// end-of-type position (`item == nil`) and follows text a peer appends;
    /// `assoc -1` is pinned to the last character and stays before it.
    func testEndOfParagraphCaptureFollowsAppendedText() throws {
        let oracle = try oracle()
        let scenario = try XCTUnwrap(oracle.scenarios.first { $0.name == "nested-xmltext" })
        let doc = try makeDoc(clientID: 2, seed: scenario.seed)
        let type = try locate(scenario.name, in: doc)
        let length = UInt(scenario.length)

        let end = try YRelativePosition.fromTypeIndex(type, index: length, assoc: 0)
        let beforeEnd = try YRelativePosition.fromTypeIndex(type, index: length, assoc: -1)

        // The shape is the fix: the end capture names no item, the left-associated
        // one names the last character.
        XCTAssertNil(end.item, "the end-of-type capture must not name the last character")
        XCTAssertNotNil(end.type, "a nested type is encoded by id")
        XCTAssertEqual(beforeEnd.item, lastVisibleID(of: type))

        let endCapture = try XCTUnwrap(
            scenario.captures.first { $0.index == scenario.length && $0.assoc == 0 })
        let beforeEndCapture = try XCTUnwrap(
            scenario.captures.first { $0.index == scenario.length && $0.assoc == -1 })
        XCTAssertEqual(try end.encode().hexString, endCapture.hex)
        XCTAssertEqual(try beforeEnd.encode().hexString, beforeEndCapture.hex)

        // Steps 1-3 leave 12 visible units; both captures resolve to the end.
        for step in scenario.steps.prefix(3) {
            try doc.applyUpdate(try YUpdateDecoder.decode(Data(hex: step.update)))
        }
        XCTAssertEqual(try XCTUnwrap(end.resolve(in: doc)).index, 12)
        XCTAssertEqual(try XCTUnwrap(beforeEnd.resolve(in: doc)).index, 12)

        // The peer appends "!". The end capture follows it; the left-associated
        // capture stays before it. Capturing the last character's id for
        // `index == length` would leave both at 11.
        try doc.applyUpdate(try YUpdateDecoder.decode(Data(hex: scenario.steps[3].update)))
        XCTAssertEqual(try XCTUnwrap(end.resolve(in: doc)).index, 13)
        XCTAssertEqual(try XCTUnwrap(beforeEnd.resolve(in: doc)).index, 12)
    }

    private func lastVisibleID(of type: YType) -> YID? {
        var item = type.start
        var last: YID?
        while let current = item {
            if !current.deleted && current.countable { last = current.lastId }
            item = current.right
        }
        return last
    }

    // MARK: - JSON shape

    /// The JSON keys and their omission rules are yjs's, not just "some JSON that
    /// decodes": `type`/`item` are `{client, clock}` objects, `tname` is a string,
    /// and `assoc` is always written.
    func testJSONShapeMatchesYjsKeyNames() throws {
        let type = YID(client: 1, clock: 1)
        let item = YID(client: 1, clock: 2)
        let cases: [(YRelativePosition, String)] = [
            (
                YRelativePosition(type: type, item: item, assoc: 0),
                #"{"type":{"client":1,"clock":1},"item":{"client":1,"clock":2},"assoc":0}"#
            ),
            (YRelativePosition(tname: "t", assoc: -1), #"{"tname":"t","assoc":-1}"#),
            (YRelativePosition(type: type, assoc: 0), #"{"type":{"client":1,"clock":1},"assoc":0}"#),
        ]

        for (position, expected) in cases {
            let actual = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(position.json))
                    as? NSDictionary)
            let wanted = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(expected.utf8)) as? NSDictionary)
            XCTAssertEqual(actual, wanted)
        }
    }

    // MARK: - Compare

    func testCompareMatchesYjs() {
        let a = YRelativePosition(
            type: YID(client: 1, clock: 1), item: YID(client: 1, clock: 2), assoc: 0)
        let cases: [(YRelativePosition?, YRelativePosition?, Bool)] = [
            (nil, nil, true),
            (nil, a, false),
            (a, nil, false),
            (a, a, true),
            (a, YRelativePosition(type: YID(client: 1, clock: 1), item: YID(client: 1, clock: 2), assoc: 0), true),
            (a, YRelativePosition(type: YID(client: 1, clock: 1), item: YID(client: 1, clock: 2), assoc: -1), false),
            (a, YRelativePosition(type: YID(client: 1, clock: 1), item: YID(client: 1, clock: 3), assoc: 0), false),
            (a, YRelativePosition(tname: "t", item: YID(client: 1, clock: 2), assoc: 0), false),
        ]

        for (left, right, expected) in cases {
            XCTAssertEqual(
                YRelativePosition.compare(left, right), expected,
                "compare(\(String(describing: left)), \(String(describing: right)))")
        }
    }
}
