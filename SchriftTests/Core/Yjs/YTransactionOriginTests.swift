import XCTest

@testable import Schrift

final class YTransactionOriginTests: XCTestCase {
    func testOriginDefaultsToNone() throws {
        let doc = YDoc(clientID: 1)
        try doc.transact { transaction in
            XCTAssertNil(transaction.origin)
        }
    }

    func testExplicitOriginIsRecordedAndNestedTransactionKeepsOuterOrigin() throws {
        let doc = YDoc(clientID: 1)
        try doc.transact(origin: .remote) { outer in
            XCTAssertEqual(outer.origin, .remote)
            try doc.transact(origin: .localUser) { nested in
                XCTAssertTrue(outer === nested)
                XCTAssertEqual(nested.origin, .remote)
            }
        }
    }

    func testBlockNoteWriteRecordsLocalUserOrigin() throws {
        let doc = YDoc(clientID: 1)
        let block = BlockNoteBlock(
            node: "paragraph",
            props: [
                (key: "backgroundColor", value: .string("default")),
                (key: "textColor", value: .string("default")),
                (key: "textAlignment", value: .string("left")),
            ],
            runs: [InlineRun("hello")],
            id: "00010000-0000-4000-8000-000000000000"
        )

        _ = try BlockNoteWrite.applyEdit(old: [], new: [block], to: doc)

        XCTAssertEqual(doc.lastTransactionOrigin, .localUser)
    }

    func testApplyUpdateDefaultsToNoOrigin() throws {
        let doc = YDoc(clientID: 9)
        let update = try YUpdateDecoder.decode(Data(hex: "01010100040101740568656c6c6f00"))

        try doc.applyUpdate(update)

        XCTAssertNil(doc.lastTransactionOrigin)
    }

    func testApplyUpdateCanRecordRemoteOrigin() throws {
        let doc = YDoc(clientID: 9)
        let update = try YUpdateDecoder.decode(Data(hex: "01010100040101740568656c6c6f00"))

        try doc.applyUpdate(update, origin: .remote)

        XCTAssertEqual(doc.lastTransactionOrigin, .remote)
    }

    func testRemoteFormattingUpdateCleanupHasNoOrigin() throws {
        let doc = YDoc(clientID: 9, gc: false)
        let updates = [
            "010201002701016d016b02040001000361626300",
            "0102020046010104626f6c64047472756586010304626f6c64046e756c6c00",
            "0102030046010104626f6c64047472756586010304626f6c64046e756c6c00",
        ]

        for hex in updates {
            try doc.applyUpdate(try YUpdateDecoder.decode(Data(hex: hex)), origin: .remote)
        }

        // B4 opens a separate transact without an origin, matching yjs's null default.
        // Its cleanup is drained after the peer transaction and is therefore last.
        XCTAssertNil(doc.lastTransactionOrigin)
    }
}
