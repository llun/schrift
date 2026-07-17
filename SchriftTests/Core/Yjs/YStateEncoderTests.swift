import XCTest

@testable import Schrift

/// Golden fixtures captured from yjs 13.6.31 (`new Y.Doc({gc:false})`, capture
/// script in the B3 session's fuzz harness). Pins `YStateEncoder` output —
/// full snapshots, diffs against a state vector, and state vectors — byte-for-byte.
final class YStateEncoderTests: XCTestCase {

    // MARK: - Fixtures (captured via `.superpowers/fuzz/capture.mjs`)

    private let helloUpdate = "01010100040101740568656c6c6f00"
    private let helloSV = "010105"
    private let helloDiffMidItem = "01010102840101036c6c6f00"
    private let surrogateFull = "010101000401017406f09f9880616200"
    private let surrogateDiffMidPair = "0101010184010005efbfbd616200"
    private let twoClientsUpdate = "02020200840101016284020001620201000401017401618401000161020201010101010001"
    private let twoClientsSV = "0202020102"
    private let mapNestedUpdate =
        "010401002801016d016b0177056669727374a801000177067365636f6e642701016d066e65737465640204000102016e0101010001"
    private let gcPeerIngested = "01030100040101740161810100038401030265660101010103"
    private let gcPeerSV = "010106"
    private let gcNestedUpdate = "010201002101016d066e65737465640100050101010006"
    private let gcNestedSV = "010106"
    private let deletedMidRangeFull = "010301000401017401618101000484010401660101010104"
    private let deletedMidRangeDiff = "010201038101020284010401660101010104"

    // MARK: - Helpers

    private func makeDoc(clientID: UInt = 9) -> YDoc { YDoc(clientID: clientID, gc: false) }

    private func applied(_ hexUpdates: [String]) throws -> YDoc {
        let doc = makeDoc()
        for hex in hexUpdates {
            try doc.applyUpdate(try YUpdateDecoder.decode(Data(hex: hex)))
        }
        return doc
    }

    private func assertEncodes(
        _ doc: YDoc, since: [UInt: UInt] = [:], expected: String, _ name: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let encoded = try YStateEncoder.encodeStateAsUpdate(doc, since: since)
        XCTAssertEqual(encoded.hexString, expected, "fixture \(name)", file: file, line: line)
    }

    // MARK: - Full snapshots

    func testEmptyDocEncodesZeroClientsZeroDeleteSet() throws {
        let doc = makeDoc()
        defer { doc.destroy() }
        try assertEncodes(doc, expected: "0000", "emptyDocUpdate")
        XCTAssertEqual(YStateEncoder.encodeStateVector(doc).hexString, "00", "emptyDocSV")
    }

    func testSingleClientStringRoundTripsAsFullSnapshot() throws {
        let doc = try applied([helloUpdate])
        defer { doc.destroy() }
        try assertEncodes(doc, expected: helloUpdate, "helloUpdate")
        XCTAssertEqual(YStateEncoder.encodeStateVector(doc).hexString, helloSV, "helloSV")
    }

    func testTwoClientsEncodeInDescendingClientOrder() throws {
        let doc = try applied([twoClientsUpdate])
        defer { doc.destroy() }
        try assertEncodes(doc, expected: twoClientsUpdate, "twoClientsUpdate")
        XCTAssertEqual(YStateEncoder.encodeStateVector(doc).hexString, twoClientsSV, "twoClientsSV")
    }

    func testMapOverwriteAndNestedTypeRoundTrip() throws {
        let doc = try applied([mapNestedUpdate])
        defer { doc.destroy() }
        try assertEncodes(doc, expected: mapNestedUpdate, "mapNestedUpdate")
    }

    /// Despite the fixture name, `gcPeerIngested` contains **no** literal `GC`
    /// struct (info byte `00`) — a `gc:true` peer's top-level deleted range
    /// (`tryGcDeleteSet` always calls `struct.gc(store, false)`) becomes
    /// `ContentDeleted` (info byte `81`, ref 1), never a real `GC`. This pins
    /// that re-encode, not the `writeUInt8(0)` GC branch — see
    /// `testEncodesAGCStruct` below for the real thing.
    func testContentDeletedFromACollectingPeerReencode() throws {
        let doc = try applied([gcPeerIngested])
        defer { doc.destroy() }
        guard let list = doc.store.clients[1] else {
            XCTFail("expected client 1 to exist")
            return
        }
        XCTAssertFalse(list.structs.contains { $0 is YGC }, "fixture is ContentDeleted, not a literal GC struct")
        try assertEncodes(doc, expected: gcPeerIngested, "gcPeerIngested")
        XCTAssertEqual(YStateEncoder.encodeStateVector(doc).hexString, gcPeerSV, "gcPeerSV")
    }

    /// A nested type's own items become literal `GC` structs (info byte `00`)
    /// when the type itself is deleted and collected under `gc:true`
    /// (`Item.gc`'s `parentGCd` branch) — distinct from `gcPeerIngested` above.
    /// Captured from real yjs (`.superpowers/fuzz/capture.mjs`'s `gcNested`
    /// block): `m.set('nested', new Y.Text('hello'))` then `m.delete('nested')`
    /// on a `gc:true` doc. Pins `YStateEncoder.write`'s `writeUInt8(0)` branch,
    /// which no other committed test reaches.
    func testEncodesAGCStruct() throws {
        let doc = try applied([gcNestedUpdate])
        defer { doc.destroy() }
        guard let list = doc.store.clients[1] else {
            XCTFail("expected client 1 to exist")
            return
        }
        XCTAssertTrue(list.structs.contains { $0 is YGC }, "fixture must contain a real GC struct")
        try assertEncodes(doc, expected: gcNestedUpdate, "gcNestedUpdate")
        XCTAssertEqual(YStateEncoder.encodeStateVector(doc).hexString, gcNestedSV, "gcNestedSV")
    }

    // MARK: - Diff path (encodeStateAsUpdate since a state vector)

    func testDiffAgainstMidItemStateVectorWritesPartialFirstStruct() throws {
        let doc = try applied([helloUpdate])
        defer { doc.destroy() }
        try assertEncodes(doc, since: [1: 2], expected: helloDiffMidItem, "helloDiffMidItem")
    }

    func testDiffSplittingASurrogatePairEmitsReplacementCharacter() throws {
        let doc = try applied([surrogateFull])
        defer { doc.destroy() }
        try assertEncodes(doc, since: [1: 1], expected: surrogateDiffMidPair, "surrogateDiffMidPair")
    }

    func testDiffAgainstFullStateVectorEncodesNoStructs() throws {
        let doc = try applied([helloUpdate])
        defer { doc.destroy() }
        // sv == state: no client qualifies; delete set still written (empty here).
        try assertEncodes(doc, since: [1: 5], expected: "0000", "diffAtFullState")
    }

    func testDiffIgnoresUnknownClientInStateVector() throws {
        let doc = try applied([helloUpdate])
        defer { doc.destroy() }
        try assertEncodes(doc, since: [777: 5], expected: helloUpdate, "diffUnknownClient")
    }

    /// A diff whose partial first struct is a `ContentDeleted` range cut
    /// mid-range — exercises `writeContent`'s `.deleted` offset path
    /// (`len - offset`), not just the offset-0 case every other fixture takes.
    func testDiffAgainstMidDeletedRangeWritesPartialContentDeleted() throws {
        let doc = try applied([deletedMidRangeFull])
        defer { doc.destroy() }
        try assertEncodes(doc, since: [1: 3], expected: deletedMidRangeDiff, "deletedMidRangeDiff")
    }

    // MARK: - The pending gate

    func testEncodeThrowsWhileStructsArePending() throws {
        // An update whose origin names a struct that never arrived: stashes, stays pending.
        // Capture: doc B inserts after doc A's text, but only B's incremental is delivered.
        let doc = try applied([pendingOnlyUpdate])
        defer { doc.destroy() }
        XCTAssertNotNil(doc.store.pendingStructs, "precondition: update must actually pend")
        assertThrows(YIntegrationError.unexpectedCase) {
            _ = try YStateEncoder.encodeStateAsUpdate(doc)
        }
    }

    private let pendingOnlyUpdate = "01010200840100017900"
}
