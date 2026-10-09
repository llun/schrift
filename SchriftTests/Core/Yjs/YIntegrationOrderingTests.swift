import XCTest

@testable import Schrift

/// Part of the golden-fixture suite; see `YIntegrationTestCase` for provenance and regeneration.
final class YIntegrationOrderingTests: YIntegrationTestCase {
    // MARK: - YATA ordering

    func testConcurrentInsertsAtTheSamePositionAreOrderedByClientID() throws {
        // Both items are the first child of the same parent with identical (nil)
        // origins, so case 1 fires and the lower client id wins the left slot.
        let doc = makeDoc()
        try apply(concurrentInsert, to: doc)
        XCTAssertEqual(visibleText(doc), "AB")
    }

    func testConcurrentInsertsConvergeRegardlessOfDeliveryOrder() throws {
        // The CRDT property itself: the same two updates in the opposite order must
        // land in the same place.
        let forward = makeDoc()
        try apply(concurrentInsert, to: forward)

        let reversed = makeDoc()
        try apply(concurrentInsert.reversed(), to: reversed)

        XCTAssertEqual(visibleText(forward), "AB")
        XCTAssertEqual(visibleText(reversed), "AB")
    }

    // MARK: - Splitting

    func testSplittingASurrogatePairYieldsReplacementCharactersOnBothSides() throws {
        // Captured from yjs: inserting into the middle of "😀" destroys it, leaving
        // U+FFFD "X" U+FFFD. Lossy, and deliberately so — the alternative is an
        // unencodable document (yjs#248). Pinned here because it is the one place the
        // store's UTF-16 representation is observable.
        let doc = makeDoc()
        try apply(surrogateSplit, to: doc)
        XCTAssertEqual(visibleText(doc), "\u{FFFD}X\u{FFFD}")
    }

    func testAPartiallyAppliedStructIntegratesFromItsOffset() throws {
        // The receiver holds "abc"; the snapshot's single item spans "abcdef". The
        // first 3 units are already applied, so integrate runs with offset 3 and
        // splices the content down to "def" — rather than duplicating "abc".
        let doc = makeDoc()
        try apply(partialOverlap, to: doc)
        XCTAssertEqual(visibleText(doc), "abcdef")
        XCTAssertEqual(doc.store.getState(1), 6)
    }

    // MARK: - Idempotence

    func testApplyingTheSameUpdateTwiceChangesNothing() throws {
        // The offset guard (`offset === 0 || offset < length`) drops a struct that is
        // wholly applied already. Without it, a redelivered update — routine over a
        // relay — would duplicate content.
        let once = makeDoc()
        try apply(concurrentInsert, to: once)

        let twice = makeDoc()
        try apply(concurrentInsert + concurrentInsert, to: twice)

        XCTAssertEqual(visibleText(twice), "AB")
        XCTAssertEqual(structs(twice, client: 1).count, structs(once, client: 1).count)
        XCTAssertEqual(structs(twice, client: 2).count, structs(once, client: 2).count)
    }

    // MARK: - Client-id collision

    func testARemoteUpdateUsingOurClientIDReRollsIt() throws {
        // yjs re-rolls the client id when a *remote* update advances our own client's
        // state: another peer is minting ids we would collide with, and a collision
        // means two different ops share an id — silent corruption.
        let doc = makeDoc(clientID: 1)  // deliberately the fixture's author id
        try apply([outOfOrder[0]], to: doc)
        XCTAssertNotEqual(doc.clientID, 1, "a colliding client id must not survive")
    }

    // MARK: - Skip padding

    /// `Y.mergeUpdates([insert@4, insert@8])` — two runs with a hole between them. A
    /// serialized update must tile a client's clock range with no gaps, so yjs pads
    /// the hole: `Item(4:1) Skip(5:3) Item(8:1)`. Then the real `Item(5:3)` arrives.
    private let skipPadding = [
        "0103010484010301650a03840107016900",  // merged: Item(4:1) Skip(5:3) Item(8:1)
        "010101058401040366676800",  // the real "fgh" at 5..7
        "0101010004010174046162636400",  // "abcd" at 0..3 — unblocks everything
    ]

    func testAHeldSkipDoesNotSwallowTheRealStructCoveringItsRange() throws {
        // Regression, found in review. The pending stash deduped on (clock, length)
        // alone, so the held `Skip(5,3)` matched the real `Item(5,3)` arriving next
        // and dropped it as a redelivery: "fgh" was lost forever, and the stash then
        // stalled permanently — nothing would ever supply clocks 5..7 again.
        //
        // Not exotic: every update that has been through mergeUpdates/diffUpdate can
        // carry a Skip, which is what y-websocket/hocuspocus persistence store.
        let doc = makeDoc()
        try apply(skipPadding, to: doc)

        XCTAssertEqual(visibleText(doc), "abcdefghi", "no content may be dropped")
        XCTAssertNil(doc.store.pendingStructs, "the stash must drain, not stall")
        XCTAssertEqual(doc.store.getState(1), 9)
    }

    // MARK: - YATA case 2

    /// Three peers insert at the same position of a shared base. Their items share an
    /// origin, so resolving the order walks items whose own origin is already in
    /// `itemsBeforeOrigin` — the conflict loop's **case 2**, which case 1 alone
    /// cannot decide. yjs settles on "XaaabbbcccY".
    private let case2ThreePeers = [
        "010107000401017402585900",  // base: client 7 inserts "XY"
        "01010100c4070007010361616100",  // client 1 inserts "aaa" at 1
        "01010200c4070007010362626200",  // client 2 inserts "bbb" at 1
        "01010300c4070007010363636300",  // client 3 inserts "ccc" at 1
    ]

    func testThreeWayConcurrentInsertResolvesThroughCase2() throws {
        // Without case 2 the loop stops at the first non-matching origin and the
        // peers' runs interleave into a different order — silently wrong text that
        // every other fixture here still passes.
        let doc = makeDoc()
        try apply(case2ThreePeers, to: doc)
        XCTAssertEqual(visibleText(doc), "XaaabbbcccY")
    }

    func testThreeWayConcurrentInsertConvergesRegardlessOfOrder() throws {
        let doc = makeDoc()
        try apply([case2ThreePeers[0]] + case2ThreePeers.dropFirst().reversed(), to: doc)
        XCTAssertEqual(visibleText(doc), "XaaabbbcccY")
    }
}
