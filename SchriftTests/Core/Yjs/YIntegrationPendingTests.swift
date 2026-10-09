import XCTest

@testable import Schrift

/// Part of the golden-fixture suite; see `YIntegrationTestCase` for provenance and regeneration.
final class YIntegrationPendingTests: YIntegrationTestCase {
    // MARK: - Pending structs

    func testAnUpdateWhoseDependencyIsMissingStaysPending() throws {
        // Deliver only the *second* update: it names origin 1:2, a struct we do not
        // have, so nothing may integrate.
        let doc = makeDoc()
        try apply([outOfOrder[1]], to: doc)

        XCTAssertEqual(visibleText(doc), "", "nothing may be visible")
        XCTAssertTrue(structs(doc, client: 1).isEmpty, "nothing may enter the store")
        XCTAssertNotNil(doc.store.pendingStructs)
        XCTAssertEqual(doc.store.pendingStructs?.missing[1], 2, "we are waiting on clock 2")
    }

    func testAPendingUpdateIntegratesOnceItsDependencyArrives() throws {
        // The retry path: the stash is replayed the moment the missing update lands.
        let doc = makeDoc()
        try apply([outOfOrder[1], outOfOrder[0]], to: doc)

        XCTAssertEqual(visibleText(doc), "aaabbb")
        XCTAssertNil(doc.store.pendingStructs, "the stash must be drained, not left behind")
    }

    func testOutOfOrderDeliveryConvergesWithInOrderDelivery() throws {
        let inOrder = makeDoc()
        try apply(outOfOrder, to: inOrder)

        let reversed = makeDoc()
        try apply(outOfOrder.reversed(), to: reversed)

        XCTAssertEqual(visibleText(inOrder), "aaabbb")
        XCTAssertEqual(visibleText(reversed), "aaabbb")
        XCTAssertNil(inOrder.store.pendingStructs)
        XCTAssertNil(reversed.store.pendingStructs)
    }

    // MARK: - Pending delete set

    func testADeleteNamingAbsentStructsStaysPending() throws {
        let doc = makeDoc()
        try apply([pendingDelete[1]], to: doc)

        XCTAssertNotNil(doc.store.pendingDs, "the delete must be held, not dropped")
        XCTAssertEqual(doc.store.pendingDs?.clients[1]?.first, YDeleteItem(clock: 1, len: 3))
    }

    func testAPendingDeleteAppliesOnceItsStructsArrive() throws {
        // Delete-then-insert: the held range must find its structs on the next update
        // and delete exactly the span it named.
        let doc = makeDoc()
        try apply([pendingDelete[1], pendingDelete[0]], to: doc)

        XCTAssertEqual(visibleText(doc), "ho", "clocks 1..3 of \"hello\" are deleted")
        XCTAssertNil(doc.store.pendingDs, "the held range must be consumed")
    }

    func testDeleteOrderDoesNotChangeTheResult() throws {
        let inOrder = makeDoc()
        try apply(pendingDelete, to: inOrder)

        let reversed = makeDoc()
        try apply(pendingDelete.reversed(), to: reversed)

        XCTAssertEqual(visibleText(inOrder), "ho")
        XCTAssertEqual(visibleText(reversed), "ho")
    }
}
