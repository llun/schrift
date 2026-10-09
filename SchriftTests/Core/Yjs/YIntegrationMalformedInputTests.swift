import XCTest

@testable import Schrift

/// Part of the golden-fixture suite; see `YIntegrationTestCase` for provenance and regeneration.
final class YIntegrationMalformedInputTests: YIntegrationTestCase {
    // MARK: - Duplicate client blocks

    /// Two blocks in one update both naming client 1 at clock 0 — malformed. yjs's
    /// `clientRefs.set(client, …)` means the **last block wins**; captured from yjs,
    /// whose text is "Y".
    private let duplicateClientBlock = "0201010004010174015801010004010174015900"

    func testADuplicateClientBlockKeepsTheLastOne() throws {
        // Appending the second run instead — the first version of `build` — is worse
        // than dropping it: the concatenation can descend, and the driver stashes a
        // client's entire remaining run once one struct runs ahead, stranding the rest
        // in a stash that never drains.
        let doc = makeDoc()
        try apply([duplicateClientBlock], to: doc)

        XCTAssertEqual(visibleText(doc), "Y")
        XCTAssertEqual(structs(doc, client: 1).count, 1)
        XCTAssertNil(doc.store.pendingStructs, "nothing may be stranded")
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
}
