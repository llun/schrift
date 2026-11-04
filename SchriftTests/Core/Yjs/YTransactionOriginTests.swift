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
            try doc.transact(origin: .formatCleanup) { nested in
                XCTAssertTrue(outer === nested)
                XCTAssertEqual(nested.origin, .remote)
            }
        }
    }

    func testLocalEditOriginCanBeRecorded() throws {
        let doc = YDoc(clientID: 1)
        try doc.transact(origin: .localUser) { transaction in
            XCTAssertEqual(transaction.origin, .localUser)
        }
    }

    func testApplyUpdateTransactionHasRemoteOrigin() throws {
        let doc = YDoc(clientID: 9)
        let update = try YUpdateDecoder.decode(Data(hex: "01010100040101740568656c6c6f00"))

        try doc.applyUpdate(update)

        XCTAssertEqual(doc.lastTransactionOrigin, .remote)
    }

    func testRemoteFormattingUpdateSpawnsFormatCleanupOrigin() throws {
        let doc = YDoc(clientID: 9, gc: false)
        let updates = [
            "010201002701016d016b02040001000361626300",
            "0102020046010104626f6c64047472756586010304626f6c64046e756c6c00",
            "0102030046010104626f6c64047472756586010304626f6c64046e756c6c00",
        ]

        for hex in updates {
            try doc.applyUpdate(try YUpdateDecoder.decode(Data(hex: hex)))
        }

        XCTAssertEqual(doc.lastTransactionOrigin, .formatCleanup)
    }
}
