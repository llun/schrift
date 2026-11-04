import XCTest

@testable import Schrift

/// Golden fixtures captured from the pinned yjs 13.6.33 in node for `Doc`'s
/// `'update'` event (`cleanupTransactions` @3388-3392): every transaction with content emits its
/// own v1 update, including the formatting-cleanup transaction the observer phase
/// opens with origin `null`.
final class YDocUpdateEventTests: XCTestCase {
    func testRemoteFormattingCleanupEmitsItsOwnUpdateAfterThePeerUpdate() throws {
        let doc = YDoc(clientID: 9, gc: false)
        var events: [(Data, YTransactionOrigin?)] = []
        doc.onUpdate = { origin, encode in
            if let update = encode() { events.append((update, origin)) }
        }

        let updates = [
            "01010100040101740b68656c6c6f20776f726c6400",  // t = "hello world"
            "0102020046010004626f6c640474727565c60104010504626f6c64046e756c6c00",  // client 2 bold [0,5)
            "0102010b46010004626f6c640474727565c60104010504626f6c64046e756c6c00",  // client 1 bold [0,5)
        ]
        for hex in updates {
            try doc.applyUpdate(try YUpdateDecoder.decode(Data(hex: hex)), origin: .remote)
        }

        // Three peer updates, then the cleanup transaction (origin nil) — yjs emits
        // the cleanup *after* the update that triggered it, never instead of it.
        XCTAssertEqual(events.count, 4)
        guard events.count == 4 else { return }
        XCTAssertEqual(events.map { $0.1 }, [YTransactionOrigin.remote, .remote, .remote, nil])
        XCTAssertEqual(events[2].0, Data(hex: updates[2]), "the peer update's own bytes")
        XCTAssertEqual(events[3].0, Data(hex: "000101010b01"), "the cleanup's delete-only update")

        // The replica's full state matches yjs's snapshot after the same sequence.
        XCTAssertEqual(
            try YStateEncoder.encodeStateAsUpdate(doc),
            Data(
                hex:
                    "0202020046010004626f6c640474727565c60104010504626f6c64046e756c6c040100040101740568656c6c6f8401040620776f726c6446010004626f6c640474727565c60104010504626f6c64046e756c6c0101010b01"
            ))
    }
}
