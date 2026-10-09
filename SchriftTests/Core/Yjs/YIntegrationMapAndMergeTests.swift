import XCTest

@testable import Schrift

/// Part of the golden-fixture suite; see `YIntegrationTestCase` for provenance and regeneration.
final class YIntegrationMapAndMergeTests: YIntegrationTestCase {
    // MARK: - Map keys

    func testOverwritingAMapKeyDeletesTheLoserAndMovesTheSlot() throws {
        let doc = makeDoc()
        try apply(mapOverwrite, to: doc)

        let map = try XCTUnwrap(doc.share["m"])
        let winner = try XCTUnwrap(map.map["k"])
        XCTAssertEqual(winner.id, YID(client: 2, clock: 0), "the map slot points at the winner")
        XCTAssertFalse(winner.deleted)

        // The loser stays in the store — a CRDT never forgets an op — but is deleted.
        let loser = try XCTUnwrap(structs(doc, client: 1).first as? YItem)
        XCTAssertTrue(loser.deleted, "the overwritten value must be deleted, not removed")
        XCTAssertEqual(loser.parentSub, "k")

        // A map entry is `parentSub`-keyed, so it never counts toward list length.
        XCTAssertEqual(map.length, 0)
    }

    // MARK: - Merge cleanup

    /// Two adjacent inserts by one client. yjs merges them during transaction
    /// cleanup, so its store holds **one** item spanning 0..5, not two.
    private let adjacentInsertsMerge = [
        "01010100040101740361626300",  // "abc" at 0..2
        "010101038401020364656600",  // "def" at 3..5
    ]

    func testAdjacentInsertsFromOneClientMergeIntoASingleStruct() throws {
        // Store *shape*, not just projected text: merge cleanup is invisible to a
        // text assertion, so without this the whole suite passes with the merge
        // deleted — even though AGENTS.md calls it mandatory and skipping it makes
        // every later comparison with yjs disagree.
        let doc = makeDoc()
        try apply(adjacentInsertsMerge, to: doc)

        XCTAssertEqual(visibleText(doc), "abcdef")
        let clientStructs = structs(doc, client: 1)
        XCTAssertEqual(clientStructs.count, 1, "cleanup must merge the two adjacent items into one")
        XCTAssertEqual(clientStructs.first?.id, YID(client: 1, clock: 0))
        XCTAssertEqual(clientStructs.first?.length, 6)
    }

    func testAPartiallyAppliedStructLeavesOneMergedStruct() throws {
        // The offset>0 fixture's store shape: "abc" + the overlapping "abcdef"
        // snapshot must settle as one 6-long item, not "abc" plus a separate "def".
        let doc = makeDoc()
        try apply(partialOverlap, to: doc)
        XCTAssertEqual(structs(doc, client: 1).count, 1)
        XCTAssertEqual(structs(doc, client: 1).first?.length, 6)
    }

    // MARK: - Map slot handover on merge

    /// One client sets the same map key twice. The loser is deleted and the winner is
    /// not, so `left.deleted == right.deleted` fails and the two do **not** merge.
    private let sameClientMapOverwrite = [
        "010101002801016d016b017702763100",  // m.k = "v1"
        "01010101a8010001770276320101010001",  // m.k = "v2"
    ]

    /// `m.set(k,"v1")`, `m.set(k,"v2")`, `m.delete(k)` — as three **separate** updates,
    /// so the receiver integrates the two items and then merges them itself (both are
    /// deleted, adjacent, same client, same key). The map slot pointed at the right
    /// half, so the merge must hand it to the survivor.
    ///
    /// Delivering them separately is the whole point: a single cumulative update
    /// carries the *already merged* `ContentAny(["v1","v2"])`, so no merge — and no
    /// handover — happens on the receiving side at all.
    /// Captured from yjs: 1 struct at `1:0` (len 2), slot → `1:0`.
    private let mapItemsThatMerge = [
        "010101002801016d016b017702763100",  // m.k = "v1"
        "01010101a8010001770276320101010001",  // m.k = "v2"
        "000101010002",  // m.delete(k) — now both are deleted
    ]

    func testMergingMapItemsHandsTheSlotToTheSurvivor() throws {
        // The re-pointing in tryToMergeWithLefts (`parent._map[sub] = left`) only runs
        // when the two items actually merge. Two earlier versions of this test failed to
        // reach it — one whose items differ in `deleted` (so they never merge), one that
        // delivered a pre-merged update — and both passed with the handover deleted.
        // This fixture kills that mutant: without the handover the slot names 1:1, a
        // struct the store no longer holds.
        let doc = makeDoc()
        try apply(mapItemsThatMerge, to: doc)

        let clientStructs = structs(doc, client: 1)
        XCTAssertEqual(clientStructs.count, 1, "both items are deleted and adjacent — they must merge")
        XCTAssertEqual(clientStructs.first?.length, 2)

        let map = try XCTUnwrap(doc.share["m"])
        let slot = try XCTUnwrap(map.map["k"])
        XCTAssertEqual(slot.id, YID(client: 1, clock: 0), "the slot must follow the survivor")
        // The slot must always name a struct the store still holds — the invariant the
        // re-pointing exists to preserve. Without it the slot dangles at the forgotten
        // right half.
        XCTAssertTrue(clientStructs.contains { $0 === slot })
    }

    func testOverwritingAMapKeyLeavesTheLoserUnmergedBecauseOnlyItIsDeleted() throws {
        // The counterpart: `deleted` differs, so cleanup must *not* merge these.
        let doc = makeDoc()
        try apply(sameClientMapOverwrite, to: doc)

        XCTAssertEqual(structs(doc, client: 1).count, 2)
        let map = try XCTUnwrap(doc.share["m"])
        let slot = try XCTUnwrap(map.map["k"])
        XCTAssertEqual(slot.id, YID(client: 1, clock: 1))
        XCTAssertFalse(slot.deleted)
    }
}
