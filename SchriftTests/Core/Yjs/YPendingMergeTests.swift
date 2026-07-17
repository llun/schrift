import XCTest

@testable import Schrift

/// Regression for `YStructIntegrator.mergePending` dropping a content-differing
/// struct at the same clock range.
///
/// The stash merge (yjs `mergeUpdatesV2([pending.update, restStructs.update])`,
/// yjs.cjs@1718) once de-duped two stashed pending structs by
/// `(clock, length, kind)`. A garbage-collecting peer re-encodes a deleted item's
/// content as `ContentDeleted` while a non-gc peer keeps the live
/// `ContentType`/`ContentString`; both name the same op `(client, clock)`, so they
/// collided on that key and the second was filtered as a "duplicate." Schrift then
/// kept whichever was stashed first, while yjs deterministically keeps the
/// representation carried by the run that reaches the clock first (`mergeUpdatesV2`'s
/// coverage discard, yjs.cjs@4200) — so the settled store diverged from yjs by
/// **network delivery order**, violating the store's "converges exactly when yjs
/// converges" invariant.
///
/// The fixture is `.superpowers/fuzz/failures/seed-7.json`, captured by the
/// differential fuzz harness and settled on both sides. Its three v1 updates
/// deliver the same op `1:17` as a live `ContentType` (update 0) and as a
/// `ContentDeleted` tombstone from a gc'd peer (update 1), with update 2 filling
/// the causal gap so both integrate. Real yjs converges to **`ContentDeleted`** at
/// `1:17` in every one of the six delivery orders (gc on or off — the astral parent
/// makes the outcome gc-invariant here). Before the fix Schrift kept `ContentType`;
/// after it, `ContentDeleted`, order-independently.
final class YPendingMergeTests: XCTestCase {

    /// Update 0 — client 1 inserts a nested `YType` at clock 17 (depends on the
    /// unarrived clocks 0…16, so it stashes as a live `ContentType`).
    private let liveType = "010101112701016d066e65737465640600"
    /// Update 1 — client 1's run 8…17 where clock 17 is a `ContentDeleted` tombstone
    /// (depends on the unarrived clocks 0…7, so the whole run stashes).
    private let deletedTombstone =
        "01070108c401000104016b2101016d026b320184010304f48fbfbfc40105010105e1ba9ec39f4401000162c40106010704f09f98802101016d066e65737465640101010209011101"
    /// Update 2 — client 1's clocks 0…7, the causal gap; supplying it drains the
    /// stash and integrates clock 17.
    private let causalGap =
        "010501000401017403efbfbd84010007efbfbdf09d94abc40100010103efbfbdc40104010103efbfbdc40104010504f09f988000"

    private func makeDoc() -> YDoc { YDoc(clientID: 9, gc: false) }

    private func apply(_ hexUpdates: [String], to doc: YDoc) throws {
        for hex in hexUpdates {
            try doc.applyUpdate(try YUpdateDecoder.decode(Data(hex: hex)))
        }
    }

    /// The struct covering `1:17` in a settled store.
    private func item1_17(_ doc: YDoc) -> YItem? {
        doc.store.clients[1]?.structs.first {
            $0.id.clock <= 17 && $0.id.clock + $0.length > 17
        } as? YItem
    }

    func testAContentDeletedTombstoneWinsOverALiveTypeAtTheSameClock() throws {
        // Seed-7's own delivery order: live type stashes first, the tombstone second.
        let doc = makeDoc()
        try apply([liveType, deletedTombstone, causalGap], to: doc)

        XCTAssertNil(doc.store.pendingStructs, "the stash must drain")
        let item = item1_17(doc)
        XCTAssertNotNil(item, "1:17 must be in the store")
        XCTAssertTrue(item?.deleted ?? false, "1:17 is deleted in both stores")
        guard case .deleted = item?.content else {
            return XCTFail(
                "1:17 must keep yjs's ContentDeleted (ref 1), not the live "
                    + "ContentType (ref \(item?.content.ref.description ?? "nil")) — "
                    + "the mergePending content-drop regression")
        }
    }

    func testTheResolutionIsIndependentOfDeliveryOrder() throws {
        // The heart of the bug: the winner must not depend on which representation
        // arrived first. yjs converges to ContentDeleted in every valid order; the
        // three updates are causally interdependent, so every permutation settles.
        let orders: [[String]] = [
            [liveType, deletedTombstone, causalGap],
            [causalGap, deletedTombstone, liveType],
            [deletedTombstone, liveType, causalGap],
            [causalGap, liveType, deletedTombstone],
            [liveType, causalGap, deletedTombstone],
            [deletedTombstone, causalGap, liveType],
        ]
        for order in orders {
            let doc = makeDoc()
            try apply(order, to: doc)
            XCTAssertNil(doc.store.pendingStructs, "the stash must drain for \(order)")
            guard case .deleted = item1_17(doc)?.content else {
                return XCTFail("1:17 must be ContentDeleted regardless of delivery order; failed for \(order)")
            }
        }
    }
}
