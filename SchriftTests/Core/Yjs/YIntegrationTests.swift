import XCTest

@testable import Schrift

/// Golden fixtures captured from **yjs@13.6.31** (the version the docs v5.4.1
/// lockfile resolves), with `doc.clientID` pinned (1/2, merged into 9) so the bytes
/// are reproducible.
///
/// Each fixture pins one branch of the YATA integration that a hand-written test
/// could otherwise assert wrongly-but-plausibly: the outcome here is whatever real
/// yjs computed, not what this implementation happens to do.
///
/// ## Regenerating
///
/// These come from a session-local node oracle (never committed — the repo's
/// zero-third-party-dependency rule):
///
/// ```sh
/// mkdir -p /tmp/yoracle && cd /tmp/yoracle
/// npm install yjs@13.6.31
/// # then the capture script from the PR body (capture-fixtures.mjs), which pins
/// # clientIDs and prints base64; convert to hex.
/// node capture-fixtures.mjs
/// ```
///
/// The same oracle backs the differential fuzz harness described in the PR body,
/// which compares this store against yjs across randomized op scripts and delivery
/// orders. These fixtures are the regression net for what that fuzz found and for
/// the branches it proved reachable.
final class YIntegrationTests: XCTestCase {

    // MARK: - Fixtures

    /// Two peers each insert one character at position 0 of the same text, with no
    /// knowledge of each other. Both items have origin=nil and rightOrigin=nil, so
    /// **YATA case 1** decides the order purely by client id. yjs merges to "AB".
    private let concurrentInsert = [
        "0101010004010174014100",  // client 1 inserts "A"
        "0101020004010174014200",  // client 2 inserts "B"
    ]

    /// A peer inserts inside an astral character, splitting its surrogate pair. yjs
    /// replaces both orphaned halves with U+FFFD (yjs#248).
    private let surrogateSplit = [
        "010101000401017404f09f988000",  // client 1 inserts "😀"
        "01010200c401000101015800",  // client 2 inserts "X" at UTF-16 offset 1
    ]

    /// Two updates from one client where the second causally depends on the first.
    /// Applied in reverse, the second must sit in `pendingStructs` until the first
    /// arrives, then integrate via the retry path.
    private let outOfOrder = [
        "01010100040101740361616100",  // "aaa"     (clocks 0..2)
        "010101038401020362626200",  // "bbb"     (clocks 3..5, origin 1:2)
    ]

    /// A delete set naming structs that have not arrived → `pendingDs`, replayed
    /// once they do.
    private let pendingDelete = [
        "01010100040101740568656c6c6f00",  // "hello"
        "000101010103",  // delete clocks 1..3, no structs
    ]

    /// A cumulative snapshot that overlaps a prefix already applied: the receiver
    /// holds "abc" (clocks 0..2) and then meets one merged item spanning 0..5.
    /// Drives `Item.integrate` with **offset 3** — the partially-applied path, which
    /// splits the incoming content inside integrate.
    private let partialOverlap = [
        "01010100040101740361626300",  // "abc"           (one item, len 3)
        "01010100040101740661626364656600",  // "abcdef" merged (one item, len 6)
    ]

    /// Overwriting a map key: the loser stays in the store but is deleted, and the
    /// map slot points at the winner.
    private let mapOverwrite = [
        "010101002801016d016b017705666972737400",  // m.k = "first"
        "01010200a801000177067365636f6e640101010001",  // m.k = "second"
    ]

    // MARK: - Helpers

    /// A fresh replica. gc is off for this milestone, matching the `Y.Doc({gc:false})`
    /// the fixtures were captured from.
    private func makeDoc(clientID: UInt = 9) -> YDoc {
        YDoc(clientID: clientID, gc: false)
    }

    private func apply(_ hexUpdates: [String], to doc: YDoc) throws {
        for hex in hexUpdates {
            try doc.applyUpdate(try YUpdateDecoder.decode(Data(hex: hex)))
        }
    }

    /// The visible text of a root type: its undeleted string content, in list order.
    /// A stand-in for the projection layer (B5) — enough to assert *ordering*, which
    /// is what YATA decides.
    private func visibleText(_ doc: YDoc, root: String = "t") -> String {
        var units: [UInt16] = []
        var item = doc.share[root]?.start
        while let current = item {
            if !current.deleted, case .string(let s) = current.content { units += s }
            item = current.right
        }
        return String(decoding: units, as: UTF16.self)
    }

    private func structs(_ doc: YDoc, client: UInt) -> [YStruct] {
        doc.store.clients[client]?.structs ?? []
    }

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
        // deleted — even though CLAUDE.md calls it mandatory and skipping it makes
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

    /// One client sets the same map key twice. The two items are adjacent and both
    /// carry `parentSub: "k"`, so cleanup merges them — and the map slot, which
    /// pointed at the right half, must be handed to the survivor.
    private let sameClientMapOverwrite = [
        "010101002801016d016b017702763100",  // m.k = "v1"
        "01010101a8010001770276320101010001",  // m.k = "v2"
    ]

    func testMergingMapItemsHandsTheSlotToTheSurvivor() throws {
        // yjs's tryToMergeWithLefts re-points `parent._map` when it forgets the right
        // half. Captured from yjs: the loser is deleted, so `deleted` differs and the
        // two do NOT merge — the slot must therefore still name 1:1.
        let doc = makeDoc()
        try apply(sameClientMapOverwrite, to: doc)

        let map = try XCTUnwrap(doc.share["m"])
        let slot = try XCTUnwrap(map.map["k"])
        XCTAssertEqual(slot.id, YID(client: 1, clock: 1))
        XCTAssertFalse(slot.deleted)
        // The map slot must always name a struct the store still holds — the
        // invariant the re-pointing exists to preserve.
        XCTAssertTrue(structs(doc, client: 1).contains { $0 === slot })
    }

    // MARK: - Malformed input

    /// A 10-byte update carrying `ContentDeleted(0)` — `Item(0:0)`, decoded and
    /// confirmed against yjs. Found in review; it used to SIGTRAP the process.
    private let zeroLengthStruct = "01010100010101720000"

    /// `Item(0:0)` followed by a real 1-long item, so the zero-length struct is not
    /// merely the last thing in the block.
    private let zeroLengthThenReal = "010201000201017200840100016100"

    func testAZeroLengthStructIsRejectedRatherThanCrashing() throws {
        // yjs integrates the degenerate item and then throws during cleanup
        // (`clock + len - 1 == -1` → findIndexSS); Swift would *trap* on the UInt
        // underflow — a remote crash from a 10-byte malformed frame. The store must
        // reach the same outcome (update refused) through a catchable error.
        for hex in [zeroLengthStruct, zeroLengthThenReal] {
            let doc = makeDoc()
            assertThrows(YIntegrationError.unexpectedCase) {
                try doc.applyUpdate(try YUpdateDecoder.decode(Data(hex: hex)))
            }
        }
    }

    /// One struct at clock `UInt.max` with 1 unit of content, so the block's clock
    /// runs past `UInt.max`. Hand-built with lib0's encoder — lib0's *reader* rejects
    /// it (`errorIntegerOutOfRange`), so no yjs peer can send it, but `Lib0Decoder`
    /// accepts the full 64-bit range for its encoder's sake and would trap.
    private let overflowingClock = "010101ffffffffffffffffff0104010174016100"

    /// One struct at clock 2^53 — past `Number.MAX_SAFE_INTEGER`, yet **harmless**:
    /// yjs's own guard sits inside `readVarUint`'s continuation branch, so a
    /// terminating varUInt slips past it and yjs just stashes the struct as
    /// unreachably far ahead.
    private let farAheadClock = "010101808080808080801004010174016100"

    func testAClockRangeThatOverflowsIsRejectedRatherThanTrapping() throws {
        // `decodeStructs` advances a block's clock by each struct's length; unbounded
        // wire clocks can run that past UInt.max, which traps — a remote crash on
        // bytes any peer can send.
        let doc = makeDoc()
        assertThrows(YWireError.clockOutOfRange) {
            try doc.applyUpdate(try YUpdateDecoder.decode(Data(hex: overflowingClock)))
        }
    }

    func testAFarAheadClockIsStashedRatherThanRejected() throws {
        // The counterpart, and the reason the ingest guard bounds only what would
        // *trap*: rejecting every clock above MAX_SAFE_INTEGER would be stricter than
        // yjs, which stashes this exact update. Captured from the oracle.
        let doc = makeDoc()
        try doc.applyUpdate(try YUpdateDecoder.decode(Data(hex: farAheadClock)))

        XCTAssertEqual(doc.store.pendingStructs?.missing[1], 9_007_199_254_740_991)
        XCTAssertTrue(structs(doc, client: 1).isEmpty)
    }

    // MARK: - Teardown

    func testDestroyBreaksTheGraphSoTheReplicaCanBeReclaimed() throws {
        // The item graph is a mesh of strong cycles (left ⇄ right, type ⇄ parent), so
        // ARC frees none of it when the YDoc goes away — a live session opens one
        // replica per document. `destroy()` is the owner's teardown hook.
        weak var weakType: YType?
        weak var weakItem: YItem?
        do {
            let doc = makeDoc()
            try apply(concurrentInsert, to: doc)
            weakType = doc.share["t"]
            weakItem = doc.share["t"]?.start
            XCTAssertNotNil(weakType)
            XCTAssertNotNil(weakItem)
            doc.destroy()
        }
        XCTAssertNil(weakType, "the root type must be reclaimed after destroy()")
        XCTAssertNil(weakItem, "the item graph must be reclaimed after destroy()")
    }
}
