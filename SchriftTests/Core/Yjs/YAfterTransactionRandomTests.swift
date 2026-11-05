import XCTest

@testable import Schrift

/// The change signal against the yjs 13.6.33 oracle's random two-peer run: a base
/// update and 40 edits on a nested `XmlText` (inserts including emoji, deletes,
/// format on/off, formatted inserts, embeds), each applied as a remote update.
///
/// The oracle's `finalDelta` is the text's delta after the run. The final
/// assertions check the store the deltas described: the visible text is the
/// delta's string inserts, and the embed count is its object inserts.
final class YAfterTransactionRandomTests: XCTestCase {

    private static var expected: [YChangeRecord] {
        [
            YChangeRecord(
                origin: .remote,
                local: false,
                events: []),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(target: [0, 0], delta: [.retain(11), .delete(3)])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(target: [0, 0], delta: [.retain(14), .delete(2)])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(target: [0, 0], delta: [.retain(7), .insert(" ")])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(target: [0, 0], delta: [.retain(7), .insert("é😀")])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: []),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(target: [0, 0], delta: [.retain(9), .insert("Z", attributes: ["italic": "true"])])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(target: [0, 0], delta: [.retain(16), .insert("X")])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(target: [0, 0], delta: [.retain(8), .delete(1)])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(target: [0, 0], delta: [.retain(11), .retain(1, attributes: ["bold": "true"])])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(target: [0, 0], delta: [.retain(14), .delete(3)])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(target: [0, 0], delta: [.retain(4), .delete(1)])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(target: [0, 0], delta: [.retain(10), .insert("Z", attributes: ["italic": "true"])])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(
                        target: [0, 0],
                        delta: [.retain(1), .insert(.embed(json: "{\"type\":\"mention\",\"id\":\"m13\"}"))])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: []),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(
                        target: [0, 0],
                        delta: [
                            .retain(8), .delete(2), .retain(1, attributes: ["italic": .null]),
                            .retain(1, attributes: ["italic": "true"]),
                        ])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(target: [0, 0], delta: [.retain(11), .insert("é😀", attributes: ["bold": "true"])])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(target: [0, 0], delta: [.retain(3), .insert("Z", attributes: ["italic": "true"])])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(
                        target: [0, 0],
                        delta: [.retain(2), .insert(.embed(json: "{\"type\":\"mention\",\"id\":\"m18\"}"))])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(target: [0, 0], delta: [.retain(18), .retain(1, attributes: ["bold": "true"])])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: []),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(
                        target: [0, 0],
                        delta: [.retain(13), .insert(.embed(json: "{\"type\":\"mention\",\"id\":\"m21\"}"))])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(
                        target: [0, 0],
                        delta: [.retain(9), .insert(.embed(json: "{\"type\":\"mention\",\"id\":\"m22\"}"))])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(
                        target: [0, 0],
                        delta: [
                            .retain(2), .delete(3), .retain(7, attributes: ["italic": .null]),
                            .retain(1, attributes: ["italic": "true"]),
                        ])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(target: [0, 0], delta: [.retain(17), .insert("Z", attributes: ["italic": "true"])])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(target: [0, 0], delta: [.retain(16), .retain(1, attributes: ["bold": "true"])])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(target: [0, 0], delta: [.retain(13), .insert("Z", attributes: ["italic": "true"])])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(target: [0, 0], delta: [.retain(3), .retain(3, attributes: ["bold": "true"])])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(target: [0, 0], delta: [.retain(18), .insert("Z", attributes: ["italic": "true"])])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(target: [0, 0], delta: [.retain(8), .insert("Z", attributes: ["italic": "true"])])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(
                        target: [0, 0],
                        delta: [.retain(8), .insert(.embed(json: "{\"type\":\"mention\",\"id\":\"m30\"}"))])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(target: [0, 0], delta: [.retain(15), .insert("Z", attributes: ["italic": "true"])])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(
                        target: [0, 0],
                        delta: [.retain(5), .insert(.embed(json: "{\"type\":\"mention\",\"id\":\"m32\"}"))])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: []),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(target: [0, 0], delta: [.retain(7), .delete(2)])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(target: [0, 0], delta: [.retain(23), .delete(1)])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(target: [0, 0], delta: [.retain(4), .insert(" ", attributes: ["bold": "true"])])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(target: [0, 0], delta: [.retain(10), .delete(2)])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(
                        target: [0, 0],
                        delta: [
                            .retain(7), .delete(3), .retain(1, attributes: ["bold": "true", "italic": .null]),
                            .retain(2, attributes: ["italic": .null]), .retain(2, attributes: ["italic": "true"]),
                        ])
                ]),
            YChangeRecord(
                origin: .remote,
                local: false,
                events: [
                    YEventRecord(target: [0, 0], delta: [.retain(11), .retain(3, attributes: ["bold": "true"])])
                ]),
        ]
    }

    func testRandomTwoPeerEditsMatchYjs() throws {
        continueAfterFailure = false
        let doc = YDoc(clientID: 9, gc: false)
        defer { doc.destroy() }
        let base =
            "0103010007010e646f63756d656e742d73746f726503097061726167726170680700010006040001011354686520717569636b2062726f776e20666f7800"
        try doc.applyUpdate(try YUpdateDecoder.decode(Data(hex: base)), origin: .remote)

        // The oracle attaches its recorder after the base update, so the base is
        // not a record.
        let recorder = YChangeRecorder()
        recorder.attach(to: doc)

        let updates = [
            "0000",
            "000101010d03",
            "000101020d031302",
            "01010200c40108010901200101020d031302",
            "01010115c40108020006c3a9f09f98800101020d031302",
            "000101020d031302",
            "01030201c601160117066974616c69630474727565c402010117015ac602020117066974616c6963046e756c6c0101020d031302",
            "01010204c4010f011001580101020d031302",
            "000101030d0313021601",
            "01020205c60200010904626f6c640474727565c60109010a04626f6c64046e756c6c0101030d0313021601",
            "00020201040101030c0513021601",
            "000202010401010406010c0513021601",
            "01030207c602000205066974616c69630474727565c402070205015ac602080205066974616c6963046e756c6c0202010401010406010c0513021601",
            "01010118c5010201031d7b2274797065223a226d656e74696f6e222c226964223a226d3133227d0202010401010406010c0513021601",
            "000202010401010406010c0513021601",
            "000202010104010406010c0513021602",
            "01010119c40109020606c3a9f09f98800202010104010406010c0513021602",
            "0103020ac601030104066974616c69630474727565c4020a0104015ac6020b0104066974616c6963046e756c6c0202010104010406010c0513021602",
            "0101011cc5011801031d7b2274797065223a226d656e74696f6e222c226964223a226d3138227d0202010104010406010c0513021602",
            "0102011dc60110011104626f6c640474727565c60111011204626f6c64046e756c6c0202010104010406010c0513021602",
            "000202010104010406010c0513021602",
            "0103020dc60109011904626f6c64046e756c6cc5020d01191d7b2274797065223a226d656e74696f6e222c226964223a226d3231227dc6020e011904626f6c6404747275650202010104010406010c0513021602",
            "0101011fc5010801151d7b2274797065223a226d656e74696f6e222c226964223a226d3232227d0202010104010406010c0513021602",
            "0002020201040a030106030106010c05130216021c01",
            "01030210c60110011d066974616c69630474727565c40210011d015ac60211011d066974616c6963046e756c6c02020201040a030106030106010c05130216021c01",
            "01020213c6010a010b04626f6c640474727565c60210021104626f6c64046e756c6c02020201040a030106030106010c05130216021c01",
            "01050215c60119011a066974616c69630474727565c60215011a04626f6c64046e756c6cc40216011a015ac60217011a066974616c6963046e756c6cc60218011a04626f6c64047472756502020201040a030106030106010c05130216021c01",
            "0102021ac60104010504626f6c640474727565c60108011f04626f6c64046e756c6c02020201040a030106030106010c05130216021c01",
            "0101021cc402140211015a02020201040a030106030106010c05130216021c01",
            "0103021dc601170200066974616c69630474727565c4021d0200015ac6021e0200066974616c6963046e756c6c02020201040a030106030106010c05130216021c01",
            "01010220c50117021d1d7b2274797065223a226d656e74696f6e222c226964223a226d3330227d02020201040a030106030106010c05130216021c01",
            "01010221c402160217015a02020201040a030106030106010c05130216021c01",
            "01030120c60107010804626f6c64046e756c6cc5012001081d7b2274797065223a226d656e74696f6e222c226964223a226d3332227dc60121010804626f6c64047472756502020201040a030106030106010c05130216021c01",
            "0002020201040a030106030106010c05130216021c01",
            "0002020201040a030106030106010c0513051c011f01",
            "0002020201040a030106030106010c0512061c011f01",
            "01010123c401060107012002020201040a030106030106010c0512061c011f01",
            "00020204000507020a031f010106030106010c0512061c011f01",
            "00020204000507061b011d0401080301060108010c0512061c011f012201",
            "01010222c60221021704626f6c6404747275650202050005070619011b011d0401080301060108010c0512061c011f012201",
        ]
        for hex in updates {
            try doc.applyUpdate(try YUpdateDecoder.decode(Data(hex: hex)), origin: .remote)
        }

        assertChangeRecords(recorder.records, Self.expected)

        let fragment = doc.get("document-store")
        let paragraph = try XCTUnwrap(fragment.start)
        guard case .type(let paragraphType) = paragraph.content else {
            return XCTFail("expected the paragraph element")
        }
        let textItem = try XCTUnwrap(paragraphType.start)
        guard case .type(let textType) = textItem.content else {
            return XCTFail("expected the nested XmlText")
        }
        XCTAssertEqual(visibleText(of: textType), "Te  ucéZZ😀k ZZ ")
        XCTAssertEqual(visibleEmbedCount(of: textType), 3)
    }
}
