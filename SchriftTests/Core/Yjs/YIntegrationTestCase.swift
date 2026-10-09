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
class YIntegrationTestCase: XCTestCase {
    // MARK: - Fixtures

    /// Two peers each insert one character at position 0 of the same text, with no
    /// knowledge of each other. Both items have origin=nil and rightOrigin=nil, so
    /// **YATA case 1** decides the order purely by client id. yjs merges to "AB".
    let concurrentInsert = [
        "0101010004010174014100",  // client 1 inserts "A"
        "0101020004010174014200",  // client 2 inserts "B"
    ]

    /// A peer inserts inside an astral character, splitting its surrogate pair. yjs
    /// replaces both orphaned halves with U+FFFD (yjs#248).
    let surrogateSplit = [
        "010101000401017404f09f988000",  // client 1 inserts "😀"
        "01010200c401000101015800",  // client 2 inserts "X" at UTF-16 offset 1
    ]

    /// Two updates from one client where the second causally depends on the first.
    /// Applied in reverse, the second must sit in `pendingStructs` until the first
    /// arrives, then integrate via the retry path.
    let outOfOrder = [
        "01010100040101740361616100",  // "aaa"     (clocks 0..2)
        "010101038401020362626200",  // "bbb"     (clocks 3..5, origin 1:2)
    ]

    /// A delete set naming structs that have not arrived → `pendingDs`, replayed
    /// once they do.
    let pendingDelete = [
        "01010100040101740568656c6c6f00",  // "hello"
        "000101010103",  // delete clocks 1..3, no structs
    ]

    /// A cumulative snapshot that overlaps a prefix already applied: the receiver
    /// holds "abc" (clocks 0..2) and then meets one merged item spanning 0..5.
    /// Drives `Item.integrate` with **offset 3** — the partially-applied path, which
    /// splits the incoming content inside integrate.
    let partialOverlap = [
        "01010100040101740361626300",  // "abc"           (one item, len 3)
        "01010100040101740661626364656600",  // "abcdef" merged (one item, len 6)
    ]

    /// Overwriting a map key: the loser stays in the store but is deleted, and the
    /// map slot points at the winner.
    let mapOverwrite = [
        "010101002801016d016b017705666972737400",  // m.k = "first"
        "01010200a801000177067365636f6e640101010001",  // m.k = "second"
    ]

    // MARK: - Helpers

    /// A fresh replica. gc is off for this milestone, matching the `Y.Doc({gc:false})`
    /// the fixtures were captured from.
    func makeDoc(clientID: UInt = 9) -> YDoc {
        YDoc(clientID: clientID, gc: false)
    }

    func apply(_ hexUpdates: [String], to doc: YDoc) throws {
        for hex in hexUpdates {
            try doc.applyUpdate(try YUpdateDecoder.decode(Data(hex: hex)))
        }
    }

    /// The visible text of a root type: its undeleted string content, in list order.
    /// A stand-in for the projection layer (B5) — enough to assert *ordering*, which
    /// is what YATA decides.
    func visibleText(_ doc: YDoc, root: String = "t") -> String {
        var units: [UInt16] = []
        var item = doc.share[root]?.start
        while let current = item {
            if !current.deleted, case .string(let s) = current.content { units += s }
            item = current.right
        }
        return String(decoding: units, as: UTF16.self)
    }

    func structs(_ doc: YDoc, client: UInt) -> [YStruct] {
        doc.store.clients[client]?.structs ?? []
    }
}
