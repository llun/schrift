import XCTest

@testable import Schrift

/// Part of the golden-fixture suite; see `YIntegrationTestCase` for provenance and regeneration.
final class YIntegrationGCAndTeardownTests: YIntegrationTestCase {
    // MARK: - GC neighbours

    /// A `gc: true` peer collects a nested type: `Item(100:0:1) GC(100:1:3)`, state 4.
    /// The author then merges "abc"+"def" into one `Item(100:1:6)` and full-syncs, so
    /// integrating it runs with **offset 3 and a GC as the left neighbour**. Captured
    /// from yjs: the result is `Item(0:1) GC(1:6)` — the new struct becomes a GC and
    /// merges with the existing one.
    private let gcLeftNeighbour = [
        "0102640021010164016b0100030164010004",  // gc:true peer's snapshot
        "0102640027010164016b02040064000661626364656600",  // author's merged full state
    ]

    func testAGCLeftNeighbourMintsAGCRatherThanBeingRejected() throws {
        // GCs arrive from gc-enabled peers regardless of our own `gc: false`. The first
        // version of this code threw `unexpectedCase` here on the reasoning that yjs
        // would throw too — it does not: `getItemCleanEnd` declines to split a GC and
        // returns it, and yjs mints a GC. We were discarding an update yjs applies.
        let doc = makeDoc()
        try apply(gcLeftNeighbour, to: doc)

        let clientStructs = structs(doc, client: 100)
        XCTAssertEqual(clientStructs.count, 2)
        XCTAssertTrue(clientStructs[1] is YGC, "the partially-applied struct becomes a GC")
        XCTAssertEqual(clientStructs[1].id, YID(client: 100, clock: 1))
        XCTAssertEqual(clientStructs[1].length, 6, "and merges with the GC already there")
    }

    /// Forged: a GC'd range under a **live root**, so `getMissing` leaves the parent
    /// set and integrate's `offset > 0` lands on a GC with a live parent. No peer can
    /// produce this — a GC proves its ops were children of a *collected* type.
    private let forgedGCUnderLiveRoot = [
        "01026400040101640161000400",  // Item(100:0:1)"a" + GC(100:1:4) under live root "d"
        "010164000401016408616263646566676800",  // Item(100:0:8) origin=nil, parent="d"
    ]

    func testAGCUnderALiveParentIsRefusedAsYjsRefusesIt() throws {
        // The other half of the GC rule, and the one the first fix got wrong by
        // over-correcting: here yjs does **not** mint a GC — `if (this.parent)` is still
        // truthy, so it enters the conflict loop with `o = left.right === undefined` and
        // throws. Accepting it would have Schrift apply an update every yjs replica
        // refuses.
        let doc = makeDoc()
        assertThrows(YIntegrationError.unexpectedCase) {
            for hex in forgedGCUnderLiveRoot {
                try doc.applyUpdate(try YUpdateDecoder.decode(Data(hex: hex)))
            }
        }
    }

    // MARK: - Teardown

    /// `XmlFragment("document-store") > XmlElement("blockContainer") > XmlText("hello")`
    /// plus a second root holding a nested `Map` — i.e. the shape every real BlockNote
    /// document has, so the teardown's nested-type recursion is actually exercised.
    private let nestedDocument =
        "0104010007010e646f63756d656e742d73746f7265030e626c6f636b436f6e7461696e657207000100"
        + "06040001010568656c6c6f2701016d066e65737465640100"

    func testDestroyBreaksTheGraphSoTheReplicaCanBeReclaimed() throws {
        // The item graph is a mesh of strong cycles (left ⇄ right, type ⇄ parent), so
        // ARC frees none of it when the YDoc goes away — a live session opens one
        // replica per document. `destroy()` is the owner's teardown hook.
        //
        // The fixture is deliberately *nested*: the first version used a flat two-item
        // text, which contains no `ContentType` at all — so the branch that tears down
        // nested types, the one every real document depends on, could be deleted with
        // the test still green. Found in review.
        weak var weakRoot: YType?
        weak var weakNested: YType?
        weak var weakItem: YItem?
        do {
            let doc = makeDoc()
            try apply([nestedDocument], to: doc)

            weakRoot = doc.share["document-store"]
            weakItem = doc.share["document-store"]?.start
            // The XmlElement's own type — reachable only through an item's ContentType.
            if case .type(let element)? = doc.share["document-store"]?.start?.content {
                weakNested = element
            }
            XCTAssertNotNil(weakRoot)
            XCTAssertNotNil(weakItem)
            XCTAssertNotNil(weakNested, "fixture must actually contain a nested type")

            doc.destroy()
            doc.destroy()  // idempotent
        }
        XCTAssertNil(weakRoot, "the root type must be reclaimed after destroy()")
        XCTAssertNil(weakItem, "the item graph must be reclaimed after destroy()")
        XCTAssertNil(weakNested, "nested types must be reclaimed too")
    }
}
