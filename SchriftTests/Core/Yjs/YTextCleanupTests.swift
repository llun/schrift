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
}
