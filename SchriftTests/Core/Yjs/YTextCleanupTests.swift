import XCTest

@testable import Schrift

/// Golden fixtures captured from **yjs@13.6.31** exercising the remote-change
/// format cleanup (`cleanupYTextAfterTransaction`, B4).
///
/// On a *remote* transaction touching a formatted text (`_hasFormatting`), yjs
/// deletes `ContentFormat` items a concurrent edit rendered redundant. The trigger
/// only fires for a **concretely-instantiated** `YText`; in the wire, that means a
/// **nested** text (a `ContentType` typeRef that `applyUpdate` auto-instantiates as
/// a `YText`), which is exactly how BlockNote stores formatted content
/// (`XmlFragment > blockContainer > XmlText`). A root text — never how the app
/// stores formatting — would be a bare `AbstractType` and is not exercised here.
///
/// These come from the session-local node oracle / differential-fuzz harness (see
/// `YIntegrationTests`), which the `--formatting` lane drives with nested texts.
final class YTextCleanupTests: XCTestCase {

    private func makeDoc(clientID: UInt = 9, gc: Bool = false) -> YDoc {
        YDoc(clientID: clientID, gc: gc)
    }

    private func apply(_ hexUpdates: [String], to doc: YDoc) throws {
        for hex in hexUpdates {
            try doc.applyUpdate(try YUpdateDecoder.decode(Data(hex: hex)))
        }
    }

    private func structs(_ doc: YDoc, client: UInt) -> [YStruct] {
        doc.store.clients[client]?.structs ?? []
    }

    // MARK: - Fixtures (captured from the oracle)

    /// A nested `Text("abc")` (map key "k"); two peers concurrently bold [0,3).
    /// Client 2's and client 3's `{bold:true}` land adjacent before 'a'; cleanup
    /// deletes the non-rightmost one (client 2's, `2:0`).
    private let concurrentBoldNestedText = [
        "010201002701016d016b02040001000361626300",  // m.k = Text("abc")
        "0102020046010104626f6c64047472756586010304626f6c64046e756c6c00",  // client 2 bold(0,3)
        "0102030046010104626f6c64047472756586010304626f6c64046e756c6c00",  // client 3 bold(0,3)
    ]

    /// The same shape with an **object-valued** mark (`{link:{href:...}}`), which
    /// exercises `YFormatAttrValue.object` identity equality. `2:0` is deleted.
    private let concurrentLinkNestedText = [
        "010201002701016d016b02040001000361626300",  // m.k = Text("abc")
        "01020200460101046c696e6b157b2268726566223a2268747470733a2f2f782f227d860103046c696e6b046e756c6c00",
        "01020300460101046c696e6b157b2268726566223a2268747470733a2f2f782f227d860103046c696e6b046e756c6c00",
    ]

    // MARK: - Remote format cleanup

    func testRedundantFormattingIsDeletedOnRemoteTransaction() throws {
        // Oracle dump: `ITEM 2:0 del=1`, all other formats del=0, `DS 2 0 1`.
        let doc = makeDoc(gc: false)
        try apply(concurrentBoldNestedText, to: doc)

        let c2 = structs(doc, client: 2)
        XCTAssertEqual(c2.count, 2)
        let redundant = try XCTUnwrap(c2[0] as? YItem)
        XCTAssertTrue(redundant.deleted, "the non-rightmost concurrent bold is cleaned up")
        XCTAssertEqual(redundant.content.ref, 6, "it is still a ContentFormat, just deleted")

        // The rightmost concurrent bold (client 3) survives.
        let c3 = structs(doc, client: 3)
        let kept = try XCTUnwrap(c3[0] as? YItem)
        XCTAssertFalse(kept.deleted)

        // Exactly one format was cleaned up (the store's own delete set).
        XCTAssertEqual(YDeleteSet.from(store: doc.store).clients[2].map { $0.count }, 1)
    }

    func testRedundantObjectValuedMarkIsDeletedOnRemoteTransaction() throws {
        // The object-valued (`link`) mark path: `2:0` deleted, `3:0` kept.
        let doc = makeDoc(gc: false)
        try apply(concurrentLinkNestedText, to: doc)

        let redundant = try XCTUnwrap(structs(doc, client: 2).first as? YItem)
        XCTAssertTrue(redundant.deleted)
        let kept = try XCTUnwrap(structs(doc, client: 3).first as? YItem)
        XCTAssertFalse(kept.deleted)
    }

    func testFormatCleanupCombinesWithGarbageCollection() throws {
        // With gc on, the cleaned-up format is also gc'd to a ContentDeleted
        // tombstone (content ref 1). Oracle (gc:true): `ITEM 2:0 del=1 content=1:01`.
        let doc = makeDoc(gc: true)
        try apply(concurrentBoldNestedText, to: doc)

        let redundant = try XCTUnwrap(structs(doc, client: 2).first as? YItem)
        XCTAssertTrue(redundant.deleted)
        XCTAssertEqual(redundant.content.ref, 1, "the deleted format is gc'd to a tombstone")
    }

    // MARK: - Multi-client delete set: insertion-order routing (the non-confluence)

    /// A cumulative/diffed delivery whose triggering remote transaction carries a
    /// **multi-client** delete set — client 1's text runs *and* client 2's/3's format
    /// items in one transaction. `iterateDeletedStructs` must walk that delete set in
    /// yjs `Map` insertion order (`YDeleteSet.orderedClients`): the format-owning
    /// client is processed first, adds its parent to `needFullCleanup`, and thereby
    /// **suppresses the contextless cleanup** of client 1's text run. Under ascending
    /// client order (`clients.keys.sorted()`) the contextless pass runs first and
    /// **wrongly deletes the live `bold:true` at `1:9`** — this fixture is the
    /// regression net for that (differential-fuzz seed-174, captured from the oracle).
    private let multiClientFormatDeleteSet = [
        "010201002701016d016b02040001000661626364656600",
        "01040107c601020103046c696e6b157b2268726566223a2268747470733a2f2f792f227d"
            + "c601040105046c696e6b046e756c6cc60108010504626f6c640474727565"
            + "c60105010604626f6c64046e756c6c01010202030702",
        "01020200c601050106066974616c69630474727565860106066974616c6963046e756c6c020201000201010106",
        "01050300c6010401050974657874436f6c6f72052272656422c6010501060974657874436f6c6f72046e756c6c"
            + "c4010201030171c601040300046c696e6b157b2268726566223a2268747470733a2f2f782f227d"
            + "c603010106046c696e6b046e756c6c00",
    ]

    func testMultiClientDeleteSetRoutesInInsertionOrder() throws {
        // Oracle: `ITEM 1:9 del=0` survives; the client-1 delete set is clocks 1..8
        // (`DS 1 1 8`). Under ascending order 1:9 would be deleted (`DS 1 1 9`).
        let doc = makeDoc(gc: false)
        try apply(multiClientFormatDeleteSet, to: doc)

        let bold = try XCTUnwrap(doc.store.clients[1]?.structs.first { $0.id.clock == 9 } as? YItem)
        XCTAssertFalse(bold.deleted, "the live bold mark survives; ascending order would delete it")
        XCTAssertEqual(bold.content.ref, 6)

        // The store's own delete set for client 1 is a single 1..8 run, not 1..9.
        let client1DS = try XCTUnwrap(YDeleteSet.from(store: doc.store).clients[1])
        XCTAssertEqual(client1DS, [YDeleteItem(clock: 1, len: 8)])
    }

    // MARK: - Contextless formatting cleanup path

    /// A formatted nested text, then a *remote* update that deletes the plain text
    /// (no format inserted or deleted in that transaction) — so `needFullCleanup`
    /// stays empty and the deleted text routes to `cleanupContextlessFormattingGap`
    /// rather than the full cleanup. Captured from the oracle.
    private let plainTextDeleteInFormattedText = [
        "010401002701016d016b02040001000361626346010104626f6c64047472756586010304626f6c64046e756c6c00",
        "000101010105",  // delete clocks 1..5 (the text + its now-redundant bold formats)
    ]

    // MARK: - Trap safety

    /// `iterateStructs` computes `clockStart + len`, and the cleanup's insert-scan
    /// passes `len == afterClock` (the full after-state clock), so `clockStart + len`
    /// can exceed `UInt.max`. yjs does this in JS floating point harmlessly; Swift's
    /// `UInt + UInt` traps on overflow — a remote crash. The saturating add must keep
    /// it from trapping (reverting the fix crashes this test process).
    func testIterateStructsDoesNotTrapWhenClockPlusLengthOverflows() throws {
        let doc = makeDoc(gc: false)
        try apply(["01010100040101740568656c6c6f00"], to: doc)  // "hello", clocks 0..4
        let list = try XCTUnwrap(doc.store.clients[1])
        try doc.transact(local: false) { txn in
            var visited = 0
            // clockStart 3 (inside the struct → clean split), len UInt.max → the sum
            // overflows and must saturate to UInt.max rather than trap.
            try YStructStore.iterateStructs(txn, list, clockStart: 3, len: .max) { _ in visited += 1 }
            XCTAssertGreaterThan(visited, 0)
        }
    }

    func testContextlessCleanupOnPlainTextDeleteMatchesOracle() throws {
        // Oracle: the text (`1:1`) and both bold formats (`1:4`, `1:5`) end deleted;
        // `DS 1 1 5`. This drives the contextless routing (verified in the harness).
        let doc = makeDoc(gc: false)
        try apply(plainTextDeleteInFormattedText, to: doc)

        for clock in [UInt(1), 4, 5] {
            let item = try XCTUnwrap(doc.store.clients[1]?.structs.first { $0.id.clock == clock } as? YItem)
            XCTAssertTrue(item.deleted, "clock \(clock) is deleted after the plain-text delete")
        }
        XCTAssertEqual(YDeleteSet.from(store: doc.store).clients[1], [YDeleteItem(clock: 1, len: 5)])
    }
}
