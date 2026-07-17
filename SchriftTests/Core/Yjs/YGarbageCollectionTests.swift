import XCTest

@testable import Schrift

/// Golden fixtures captured from **yjs@13.6.31** with `new Y.Doc({ gc: true })`.
///
/// gc (B4) replaces a deleted item's content with a `ContentDeleted` tombstone
/// (content ref 1) and turns a deleted type's children into `GC` structs. Each
/// fixture pins the gc flag its oracle used; the gc-off mode is exercised
/// elsewhere (every other Yjs test constructs `YDoc(gc: false)` explicitly).
///
/// These come from the session-local node oracle / differential-fuzz harness
/// described in `YIntegrationTests` — the same one, run with `gc: true`.
final class YGarbageCollectionTests: XCTestCase {

    private func makeDoc(clientID: UInt = 9, gc: Bool = true) -> YDoc {
        YDoc(clientID: clientID, gc: gc)
    }

    private func apply(_ hexUpdates: [String], to doc: YDoc) throws {
        for hex in hexUpdates {
            try doc.applyUpdate(try YUpdateDecoder.decode(Data(hex: hex)))
        }
    }

    // MARK: - Fixtures (captured from the gc:true oracle)

    /// Client 1 inserts "hello" then deletes clocks 0..4. With gc on, the deleted
    /// run is a single `ContentDeleted` tombstone of length 5.
    private let insertThenDelete = [
        "01010100040101740568656c6c6f00",  // "hello"
        "000101010005",  // delete clocks 0..4 (no structs, one DS range)
    ]

    /// Client 1 sets map key "k" to a nested Text "hi", then deletes the key. gc
    /// recurses: the nested text's child ("hi") becomes a `GC` struct, and the
    /// map-value `ContentType` item becomes a `ContentDeleted` tombstone.
    private let deleteNestedType = [
        "010201002701016d016b020400010002686900",  // m.k = Text("hi")
        "000101010003",  // delete clocks 0..2
    ]

    // MARK: - Tombstoning

    func testDeletedTextIsGarbageCollectedToAContentDeletedTombstone() throws {
        // Oracle (gc:true) dump: `ITEM 1:0 len=5 del=1 content=1:05`, `DS 1 0 5`.
        let doc = makeDoc(gc: true)
        try apply(insertThenDelete, to: doc)

        let structs = doc.store.clients[1]?.structs ?? []
        XCTAssertEqual(structs.count, 1, "the gc'd deleted run is a single tombstone")
        let item = try XCTUnwrap(structs.first as? YItem)
        XCTAssertTrue(item.deleted)
        XCTAssertEqual(item.content.ref, 1, "content is a ContentDeleted tombstone")
        XCTAssertEqual(item.length, 5)
        XCTAssertEqual(doc.store.getState(1), 5)
    }

    func testGarbageCollectionIsOffByExplicitFlag() throws {
        // The same script with gc explicitly off keeps the live ContentString.
        let doc = makeDoc(gc: false)
        try apply(insertThenDelete, to: doc)

        let item = try XCTUnwrap(doc.store.clients[1]?.structs.first as? YItem)
        XCTAssertTrue(item.deleted)
        XCTAssertEqual(item.content.ref, 4, "gc off: content stays a ContentString")
    }

    // MARK: - Recursive gc of a deleted type

    func testDeletedNestedTypeGarbageCollectsItsChildrenIntoGCStructs() throws {
        // Oracle (gc:true) dump after the delete:
        //   ITEM 1:0 len=1 del=1 content=1:01   (map value → ContentDeleted)
        //   GC 1:1 len=2                          (nested text child → GC struct)
        //   DS 1 0 3
        let doc = makeDoc(gc: true)
        try apply(deleteNestedType, to: doc)

        let structs = doc.store.clients[1]?.structs ?? []
        XCTAssertEqual(structs.count, 2)

        let mapValue = try XCTUnwrap(structs[0] as? YItem)
        XCTAssertTrue(mapValue.deleted)
        XCTAssertEqual(mapValue.content.ref, 1, "the deleted map value is a ContentDeleted tombstone")
        XCTAssertEqual(mapValue.length, 1)

        let child = structs[1]
        XCTAssertTrue(child is YGC, "the deleted nested text's child is a GC struct")
        XCTAssertEqual(child.id, YID(client: 1, clock: 1))
        XCTAssertEqual(child.length, 2)
    }

    // MARK: - Malformed input throws, never traps

    func testGarbageCollectingANonDeletedItemThrows() throws {
        // Every clock is attacker-controlled; gc'ing a live item is malformed and
        // yjs throws `unexpectedCase` — Schrift must throw, never trap.
        let doc = makeDoc(gc: true)
        try apply(["01010100040101740568656c6c6f00"], to: doc)  // "hello", undeleted
        let item = try XCTUnwrap(doc.store.clients[1]?.structs.first as? YItem)
        do {
            try item.gc(doc.store, parentGCd: false)
            XCTFail("gc on a non-deleted item must throw")
        } catch let error as YIntegrationError {
            XCTAssertEqual(error, .unexpectedCase)
        }
    }
}
