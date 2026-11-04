import XCTest

@testable import Schrift

/// Update-event oracles captured with node yjs 13.6.33 (whose transaction encoding
/// matches 13.6.31), gc on, deterministic clientIDs. Session-local capture:
/// `.oracle/capture.cjs`; no npm dependency or harness is shipped. Each fixture
/// listens to `doc.on('update')`, rather than calling `encodeStateAsUpdate`.
final class YTransactionEncoderTests: XCTestCase {
    private let textSeed = "01010700040101740568656c6c6f00"
    private let baseID = "11111111-1111-4111-8111-111111111111"
    private let splitID = "22222222-2222-4222-8222-222222222222"

    private func seeded(_ hex: String, clientID: UInt = 7) throws -> YDoc {
        let doc = YDoc(clientID: clientID)
        try doc.applyUpdate(try YUpdateDecoder.decode(Data(hex: hex)))
        // These fixtures continue their author's deterministic clientID. Remote
        // ingestion correctly rerolls a colliding ID, so restore it only here.
        doc.clientID = clientID
        return doc
    }

    /// Returning the existing generic closure's argument exposes the transaction
    /// only after cleanup has completed. No additional YDoc API is necessary.
    private func edit(_ doc: YDoc, _ body: (YTransaction) throws -> Void) throws -> YTransaction {
        try doc.transact { tx in
            try body(tx)
            return tx
        }
    }

    private func nestedType(_ item: YItem?) throws -> YType {
        let item = try XCTUnwrap(item)
        guard case .type(let type) = item.content else {
            throw YIntegrationError.unexpectedCase
        }
        return type
    }

    private func paragraph(_ text: String, id: String) -> BlockNoteBlock {
        BlockNoteBlock(
            node: "paragraph",
            props: [
                ("backgroundColor", .string("default")), ("textColor", .string("default")),
                ("textAlignment", .string("left")),
            ],
            runs: [InlineRun(text)], id: id)
    }

    /// Node: getText('t').insert(0, 'hello'); then t.insert(2, 'X').
    func testTextInsertMatchesNodeUpdateEvent() throws {
        let doc = try seeded(textSeed)
        defer { doc.destroy() }
        let tx = try edit(doc) {
            try YWrite.insert($0, into: doc.get("t"), at: 2, [.string(Array("X".utf16))])
        }
        XCTAssertEqual(try YTransactionEncoder.encodeUpdate(tx)?.hexString, "01010705c407010702015800")
    }

    /// Node: t.insert(5, '!'). Cleanup merges the old and new strings; the
    /// shared struct writer must substitute the diff origin inside that item.
    func testAppendAfterCleanupMergesMatchesNodeUpdateEvent() throws {
        let doc = try seeded(textSeed)
        defer { doc.destroy() }
        let tx = try edit(doc) {
            try YWrite.insert($0, into: doc.get("t"), at: 5, [.string(Array("!".utf16))])
        }
        XCTAssertEqual(doc.store.clients[7]?.structs.count, 1)
        XCTAssertEqual(tx.afterState[7], 6)
        XCTAssertEqual(try YTransactionEncoder.encodeUpdate(tx)?.hexString, "01010705840704012100")
    }

    /// Node: t.delete(1, 3). No clock moves, but the delete set must be sent.
    func testRangeDeleteMatchesNodeUpdateEvent() throws {
        let doc = try seeded(textSeed)
        defer { doc.destroy() }
        let tx = try edit(doc) { try YWrite.delete($0, from: doc.get("t"), at: 1, length: 3) }
        XCTAssertEqual(tx.beforeState, tx.afterState)
        XCTAssertEqual(try YTransactionEncoder.encodeUpdate(tx)?.hexString, "000107010103")
    }

    /// Node: t.format(1, 3, {bold:true}). Reproduce its two ContentFormat
    /// insertions around the same clean boundaries, leaving the text untouched.
    func testFormatMatchesNodeUpdateEvent() throws {
        let doc = try seeded(textSeed)
        defer { doc.destroy() }
        let tx = try edit(doc) { tx in
            let first = try XCTUnwrap(YStructStore.getItemCleanStart(tx, YID(client: 7, clock: 1)) as? YItem)
            try YWrite.insertAfter(
                tx, into: doc.get("t"), after: first.left, [.format(key: "bold", valueJSON: "true")])
            let last = try XCTUnwrap(YStructStore.getItemCleanStart(tx, YID(client: 7, clock: 4)) as? YItem)
            try YWrite.insertAfter(
                tx, into: doc.get("t"), after: last.left, [.format(key: "bold", valueJSON: "null")])
        }
        XCTAssertEqual(
            try YTransactionEncoder.encodeUpdate(tx)?.hexString,
            "01020705c60700070104626f6c640474727565c60703070404626f6c64046e756c6c00")
    }

    /// Node: client 1 builds blockGroup → blockContainer → paragraph → XmlText
    /// ('hello'), then sets backgroundColor/textColor/textAlignment and id, in
    /// golden-encoder order. In one client-42 transaction: text.delete(2, 3),
    /// append a second container in the same order with text 'llo'.
    func testBlockNoteSplitMatchesNodeUpdateEvent() throws {
        let old = paragraph("hello", id: baseID)
        let doc = try seeded(BlockNoteYjs.encode([old], clientID: 1).hexString, clientID: 42)
        defer { doc.destroy() }
        let update = try BlockNoteWrite.applyEdit(
            old: [old], new: [paragraph("he", id: baseID), paragraph("llo", id: splitID)], to: doc)
        XCTAssertEqual(
            update.hexString,
            "01082a00870101030e626c6f636b436f6e7461696e657207002a00030970617261677261706807002a010604002a02036c6c6f28002a010f6261636b67726f756e64436f6c6f7201770764656661756c7428002a010974657874436f6c6f7201770764656661756c7428002a010d74657874416c69676e6d656e740177046c65667428002a0002696401772432323232323232322d323232322d343232322d383232322d3232323232323232323232320101010603"
        )
    }

    /// Node: client 7 inserts 'abcdef', deletes index 1 ('b') in an earlier
    /// transaction, then this transaction deletes visible index 2 ('d').
    func testHistoricalTombstonesAreExcludedAndBothUpdatePathsConverge() throws {
        let seed = "010307000401017401618107000184070104636465660107010101"
        let doc = try seeded(seed)
        let transactionPeer = try seeded(seed, clientID: 8)
        let statePeer = try seeded(seed, clientID: 9)
        defer {
            doc.destroy()
            transactionPeer.destroy()
            statePeer.destroy()
        }
        let before = doc.store.getStateVector()
        let tx = try edit(doc) { try YWrite.delete($0, from: doc.get("t"), at: 2, length: 1) }
        let update = try XCTUnwrap(YTransactionEncoder.encodeUpdate(tx))
        XCTAssertEqual(update.hexString, "000107010301")
        let decoded = try YUpdateDecoder.decode(update)
        XCTAssertEqual(decoded.deleteSet, [YDeleteBlock(client: 7, ranges: [YDeleteRange(clock: 3, length: 1)])])
        let stateUpdate = try YStateEncoder.encodeStateAsUpdate(doc, since: before)
        XCTAssertEqual(try YUpdateDecoder.decode(stateUpdate).deleteSet.first?.ranges.count, 2)
        try transactionPeer.applyUpdate(decoded)
        try statePeer.applyUpdate(try YUpdateDecoder.decode(stateUpdate))
        XCTAssertEqual(
            try YStateEncoder.encodeStateAsUpdate(transactionPeer), try YStateEncoder.encodeStateAsUpdate(doc))
        XCTAssertEqual(try YStateEncoder.encodeStateAsUpdate(statePeer), try YStateEncoder.encodeStateAsUpdate(doc))
    }

    func testOneCharacterUpdateSizeDoesNotGrowWithParagraphsAndPriorTombstones() throws {
        func insertUpdate(paragraphCount: Int) throws -> Data {
            let doc = YDoc(clientID: 42)
            defer { doc.destroy() }
            let blocks = (0..<paragraphCount).map {
                paragraph("abc", id: String(format: "%08d-1111-4111-8111-111111111111", $0))
            }
            try doc.applyUpdate(try YUpdateDecoder.decode(BlockNoteYjs.encode(blocks, clientID: 1)))
            let group = try nestedType(doc.get(BlockNoteWrite.fragmentField).start)
            var texts: [YType] = []
            var container = group.start
            while let item = container {
                let containerType = try nestedType(item)
                let element = try nestedType(containerType.start)
                texts.append(try nestedType(element.start))
                container = item.right
            }
            XCTAssertEqual(texts.count, paragraphCount)
            try doc.transact { tx in
                for text in texts { try YWrite.delete(tx, from: text, at: 1, length: 1) }
            }
            let tx = try edit(doc) { try YWrite.insert($0, into: texts[0], at: 1, [.string(Array("X".utf16))]) }
            let update = try XCTUnwrap(YTransactionEncoder.encodeUpdate(tx))
            let decoded = try YUpdateDecoder.decode(update)
            XCTAssertTrue(decoded.deleteSet.isEmpty, "Earlier per-paragraph tombstones must never be carried")
            XCTAssertEqual(decoded.blocks.flatMap(\.structs).count, 1)
            return update
        }
        // The same references near the head, and a fresh local client, keep even
        // varint widths identical. A whole-store delete set would grow by ~5 KB.
        XCTAssertEqual(try insertUpdate(paragraphCount: 100), try insertUpdate(paragraphCount: 5_000))
    }

    /// Node: client 7 creates a='abc', client 42 creates b='xyz'; one
    /// transaction deletes each first character and inserts '!' at index 1 in
    /// both, switching clientID back to the respective owner for each insert.
    func testStructsAndDeletesUseDescendingClientOrder() throws {
        let doc = try seeded("02012a00040101620378797a010700040101610361626300", clientID: 42)
        defer { doc.destroy() }
        let tx = try edit(doc) { tx in
            try YWrite.delete(tx, from: doc.get("a"), at: 0, length: 1)
            try YWrite.delete(tx, from: doc.get("b"), at: 0, length: 1)
            doc.clientID = 7
            try YWrite.insert(tx, into: doc.get("a"), at: 1, [.string(Array("!".utf16))])
            doc.clientID = 42
            try YWrite.insert(tx, into: doc.get("b"), at: 1, [.string(Array("!".utf16))])
        }
        let update = try XCTUnwrap(YTransactionEncoder.encodeUpdate(tx))
        XCTAssertEqual(update.hexString, "02012a03c42a012a020121010703c4070107020121022a01000107010001")
        let decoded = try YUpdateDecoder.decode(update)
        XCTAssertEqual(decoded.blocks.map(\.client), [42, 7])
        XCTAssertEqual(decoded.deleteSet.map(\.client), [42, 7])
    }

    func testUnchangedBlockNoteEditReturnsCanonicalEmptyUpdateWithHistoricalDeletes() throws {
        let doc = YDoc(clientID: 7)
        defer { doc.destroy() }
        let original = paragraph("hello", id: baseID)
        let shortened = paragraph("ho", id: baseID)
        _ = try BlockNoteWrite.applyEdit(old: [], new: [original], to: doc)
        _ = try BlockNoteWrite.applyEdit(old: [original], new: [shortened], to: doc)
        XCTAssertFalse(YDeleteSet.from(store: doc.store).isEmpty)
        XCTAssertEqual(
            try BlockNoteWrite.applyEdit(old: [shortened], new: [shortened], to: doc).hexString, "0000")
    }

    func testEmptyTransactionReturnsNil() throws {
        let doc = try seeded(textSeed)
        defer { doc.destroy() }
        XCTAssertNil(try YTransactionEncoder.encodeUpdate(edit(doc) { _ in }))
    }

    func testEncodingBeforeCleanupThrows() throws {
        let doc = YDoc(clientID: 7)
        defer { doc.destroy() }
        try doc.transact { tx in
            do {
                _ = try YTransactionEncoder.encodeUpdate(tx)
                XCTFail("An active transaction has no finished afterState or merged store")
            } catch let error as YIntegrationError {
                XCTAssertEqual(error, .unexpectedCase)
            }
        }
    }

    func testPendingStructsAndPendingDeletesRefuseEvenAnEmptyTransaction() throws {
        for seed in ["01010200840100017900", "000101010001"] {
            let doc = try seeded(seed)
            defer { doc.destroy() }
            XCTAssertTrue(doc.store.pendingStructs != nil || doc.store.pendingDs != nil)
            let tx = try edit(doc) { _ in }
            do {
                _ = try YTransactionEncoder.encodeUpdate(tx)
                XCTFail("A pending replica must not be encoded")
            } catch let error as YIntegrationError {
                XCTAssertEqual(error, .unexpectedCase)
            }
        }
    }
}
