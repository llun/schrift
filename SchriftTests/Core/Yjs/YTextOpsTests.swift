import XCTest

@testable import Schrift

/// Golden fixtures captured from **yjs@13.6.33** for the format-aware text
/// operations (`YTextOps`, B4): `insert`/`insertEmbed`/`delete`/`format` on a root
/// `YText` and on a nested `XmlText`, replayed op for op.
///
/// Each scenario is a `seedOps` list (applied through the same API), the state hex
/// it must encode to, then `steps` — one op each, with the v1 update the op must
/// produce, the transaction's own `'update'` bytes, and the text's `toDelta()`
/// afterwards — and the final state hex. The doc is client 1 with `gc: false`,
/// matching the capture.
///
/// Two update forms are asserted per step. `update` is the oracle's
/// `Y.encodeStateAsUpdate(d, sv)` with the state vector taken before the op;
/// `txUpdate` is the bytes yjs emits on the doc's `'update'` event, i.e. what
/// `YTransactionEncoder.encodeUpdate` produces and what the editor broadcasts.
/// They agree for an insert or a format, but a delete's diff update carries the
/// store's *whole* delete set (a second delete's update repeats the first range,
/// merged), where the transaction encoder carries only that transaction's own
/// deletes.
final class YTextOpsTests: XCTestCase {

    // MARK: - Fixtures

    private struct Op {
        let op: String
        let index: UInt
        var text: String? = nil
        var embed: String? = nil
        var length: UInt? = nil
        var attrs: [(String, String)]? = nil
    }

    private struct Step {
        let op: Op
        let update: String
        let txUpdate: String
        let delta: String
    }

    private struct Scenario {
        let name: String
        let nested: Bool
        let seedOps: [Op]
        let seed: String
        let steps: [Step]
        let finalState: String
    }

    private let scenarios: [Scenario] = [
        Scenario(
            name: "insert-plain",
            nested: false,
            seedOps: [
                Op(op: "insert", index: 0, text: "abcdefgh")
            ],
            seed: "010101000401017408616263646566676800",
            steps: [
                Step(
                    op: Op(op: "insert", index: 0, text: "hello"),
                    update: "010101084401000568656c6c6f00",
                    txUpdate: "010101084401000568656c6c6f00",
                    delta: #"[{"insert":"helloabcdefgh"}]"#),
                Step(
                    op: Op(op: "insert", index: 5, text: " world"),
                    update: "0101010dc4010c01000620776f726c6400",
                    txUpdate: "0101010dc4010c01000620776f726c6400",
                    delta: #"[{"insert":"hello worldabcdefgh"}]"#),
                Step(
                    op: Op(op: "insert", index: 5, text: ","),
                    update: "01010113c4010c010d012c00",
                    txUpdate: "01010113c4010c010d012c00",
                    delta: #"[{"insert":"hello, worldabcdefgh"}]"#),
                Step(
                    op: Op(op: "insert", index: 0, text: ">"),
                    update: "01010114440108013e00",
                    txUpdate: "01010114440108013e00",
                    delta: #"[{"insert":">hello, worldabcdefgh"}]"#),
            ],
            finalState:
                "01050100040101740861626364656667684401000568656c6c6fc4010c01000620776f726c64c4010c010d012c440108013e00"
        ),
        Scenario(
            name: "insert-inherits-bold (C2 typing in a bold run)",
            nested: false,
            seedOps: [
                Op(op: "insert", index: 0, text: "abcdefgh")
            ],
            seed: "010101000401017408616263646566676800",
            steps: [
                Step(
                    op: Op(op: "format", index: 2, length: 3, attrs: [("bold", "true")]),
                    update: "01020108c60101010204626f6c640474727565c60104010504626f6c64046e756c6c00",
                    txUpdate: "01020108c60101010204626f6c640474727565c60104010504626f6c64046e756c6c00",
                    delta: #"[{"insert":"ab"},{"insert":"cde","attributes":{"bold":true}},{"insert":"fgh"}]"#),
                Step(
                    op: Op(op: "insert", index: 3, text: "XY"),
                    update: "0101010ac40102010302585900",
                    txUpdate: "0101010ac40102010302585900",
                    delta: #"[{"insert":"ab"},{"insert":"cXYde","attributes":{"bold":true}},{"insert":"fgh"}]"#),
                Step(
                    op: Op(op: "insert", index: 2, text: "<"),
                    update: "0101010cc401010108013c00",
                    txUpdate: "0101010cc401010108013c00",
                    delta: #"[{"insert":"ab<"},{"insert":"cXYde","attributes":{"bold":true}},{"insert":"fgh"}]"#),
                Step(
                    op: Op(op: "insert", index: 7, text: ">"),
                    update: "0101010dc401030104013e00",
                    txUpdate: "0101010dc401030104013e00",
                    delta: #"[{"insert":"ab<"},{"insert":"cXYd>e","attributes":{"bold":true}},{"insert":"fgh"}]"#),
            ],
            finalState:
                "010a01000401017402616284010101638401020164840103016584010403666768c60101010204626f6c640474727565c60104010504626f6c64046e756c6cc401020103025859c401010108013cc401030104013e00"
        ),
        Scenario(
            name: "insert-explicit-attributes",
            nested: false,
            seedOps: [
                Op(op: "insert", index: 0, text: "abcdefgh")
            ],
            seed: "010101000401017408616263646566676800",
            steps: [
                Step(
                    op: Op(op: "format", index: 2, length: 3, attrs: [("bold", "true")]),
                    update: "01020108c60101010204626f6c640474727565c60104010504626f6c64046e756c6c00",
                    txUpdate: "01020108c60101010204626f6c640474727565c60104010504626f6c64046e756c6c00",
                    delta: #"[{"insert":"ab"},{"insert":"cde","attributes":{"bold":true}},{"insert":"fgh"}]"#),
                Step(
                    op: Op(op: "insert", index: 3, text: "n", attrs: [("bold", "null")]),
                    update: "0103010ac60102010304626f6c64046e756c6cc4010a0103016ec6010b010304626f6c64047472756500",
                    txUpdate: "0103010ac60102010304626f6c64046e756c6cc4010a0103016ec6010b010304626f6c64047472756500",
                    delta:
                        #"[{"insert":"ab"},{"insert":"c","attributes":{"bold":true}},{"insert":"n"},{"insert":"de","attributes":{"bold":true}},{"insert":"fgh"}]"#
                ),
                Step(
                    op: Op(op: "insert", index: 0, text: "i", attrs: [("italic", "true")]),
                    update: "0103010d460100066974616c69630474727565c4010d01000169c6010e0100066974616c6963046e756c6c00",
                    txUpdate:
                        "0103010d460100066974616c69630474727565c4010d01000169c6010e0100066974616c6963046e756c6c00",
                    delta:
                        #"[{"insert":"i","attributes":{"italic":true}},{"insert":"ab"},{"insert":"c","attributes":{"bold":true}},{"insert":"n"},{"insert":"de","attributes":{"bold":true}},{"insert":"fgh"}]"#
                ),
                Step(
                    op: Op(op: "insert", index: 4, text: "b", attrs: [("bold", "true"), ("italic", "true")]),
                    update:
                        "01030110c60102010a066974616c69630474727565c40110010a0162c60111010a066974616c6963046e756c6c00",
                    txUpdate:
                        "01030110c60102010a066974616c69630474727565c40110010a0162c60111010a066974616c6963046e756c6c00",
                    delta:
                        #"[{"insert":"i","attributes":{"italic":true}},{"insert":"ab"},{"insert":"c","attributes":{"bold":true}},{"insert":"b","attributes":{"bold":true,"italic":true}},{"insert":"n"},{"insert":"de","attributes":{"bold":true}},{"insert":"fgh"}]"#
                ),
                Step(
                    op: Op(op: "insert", index: 2, text: "e", attrs: []),
                    update: "01010113c401000101016500",
                    txUpdate: "01010113c401000101016500",
                    delta:
                        #"[{"insert":"i","attributes":{"italic":true}},{"insert":"aeb"},{"insert":"c","attributes":{"bold":true}},{"insert":"b","attributes":{"bold":true,"italic":true}},{"insert":"n"},{"insert":"de","attributes":{"bold":true}},{"insert":"fgh"}]"#
                ),
            ],
            finalState:
                "011101000401017401618401000162840101016384010202646584010403666768c60101010204626f6c640474727565c60104010504626f6c64046e756c6cc60102010304626f6c64046e756c6cc4010a0103016ec6010b010304626f6c640474727565460100066974616c69630474727565c4010d01000169c6010e0100066974616c6963046e756c6cc60102010a066974616c69630474727565c40110010a0162c60111010a066974616c6963046e756c6cc401000101016500"
        ),
        Scenario(
            name: "format-add-remove-overlap",
            nested: false,
            seedOps: [
                Op(op: "insert", index: 0, text: "abcdefgh")
            ],
            seed: "010101000401017408616263646566676800",
            steps: [
                Step(
                    op: Op(op: "format", index: 1, length: 4, attrs: [("bold", "true")]),
                    update: "01020108c60100010104626f6c640474727565c60104010504626f6c64046e756c6c00",
                    txUpdate: "01020108c60100010104626f6c640474727565c60104010504626f6c64046e756c6c00",
                    delta: #"[{"insert":"a"},{"insert":"bcde","attributes":{"bold":true}},{"insert":"fgh"}]"#),
                Step(
                    op: Op(op: "format", index: 3, length: 4, attrs: [("italic", "true")]),
                    update: "0102010ac601020103066974616c69630474727565c601060107066974616c6963046e756c6c00",
                    txUpdate: "0102010ac601020103066974616c69630474727565c601060107066974616c6963046e756c6c00",
                    delta:
                        #"[{"insert":"a"},{"insert":"bc","attributes":{"bold":true}},{"insert":"de","attributes":{"bold":true,"italic":true}},{"insert":"fg","attributes":{"italic":true}},{"insert":"h"}]"#
                ),
                Step(
                    op: Op(op: "format", index: 2, length: 2, attrs: [("bold", "null")]),
                    update: "0102010cc60101010204626f6c64046e756c6cc60103010404626f6c64047472756500",
                    txUpdate: "0102010cc60101010204626f6c64046e756c6cc60103010404626f6c64047472756500",
                    delta:
                        #"[{"insert":"a"},{"insert":"b","attributes":{"bold":true}},{"insert":"c"},{"insert":"d","attributes":{"italic":true}},{"insert":"e","attributes":{"italic":true,"bold":true}},{"insert":"fg","attributes":{"italic":true}},{"insert":"h"}]"#
                ),
                Step(
                    op: Op(op: "format", index: 0, length: 8, attrs: [("bold", "true")]),
                    update: "0102010e46010004626f6c64047472756586010704626f6c64046e756c6c01010208020c02",
                    txUpdate: "0102010e46010004626f6c64047472756586010704626f6c64046e756c6c01010208020c02",
                    delta:
                        #"[{"insert":"abc","attributes":{"bold":true}},{"insert":"defg","attributes":{"bold":true,"italic":true}},{"insert":"h","attributes":{"bold":true}}]"#
                ),
                Step(
                    op: Op(op: "format", index: 0, length: 8, attrs: [("bold", "null"), ("italic", "null")]),
                    update: "000101010808",
                    txUpdate: "000101020a020e02",
                    delta: #"[{"insert":"abcdefgh"}]"#),
            ],
            finalState:
                "010f010004010174016184010001628401010163840102016484010301658401040266678401060168c60100010104626f6c640474727565c60104010504626f6c64046e756c6cc601020103066974616c69630474727565c601060107066974616c6963046e756c6cc60101010204626f6c64046e756c6cc60103010404626f6c64047472756546010004626f6c64047472756586010704626f6c64046e756c6c0101010808"
        ),
        Scenario(
            name: "format-object-values",
            nested: false,
            seedOps: [
                Op(op: "insert", index: 0, text: "abcdefgh")
            ],
            seed: "010101000401017408616263646566676800",
            steps: [
                Step(
                    op: Op(op: "format", index: 0, length: 3, attrs: [("link", "{\"href\":\"https://a.example\"}")]),
                    update:
                        "01020108460100046c696e6b1c7b2268726566223a2268747470733a2f2f612e6578616d706c65227dc601020103046c696e6b046e756c6c00",
                    txUpdate:
                        "01020108460100046c696e6b1c7b2268726566223a2268747470733a2f2f612e6578616d706c65227dc601020103046c696e6b046e756c6c00",
                    delta: #"[{"insert":"abc","attributes":{"link":{"href":"https://a.example"}}},{"insert":"defgh"}]"#),
                Step(
                    op: Op(op: "format", index: 1, length: 3, attrs: [("link", "{\"href\":\"https://b.example\"}")]),
                    update:
                        "0102010ac601000101046c696e6b1c7b2268726566223a2268747470733a2f2f622e6578616d706c65227dc601030104046c696e6b046e756c6c0101010901",
                    txUpdate:
                        "0102010ac601000101046c696e6b1c7b2268726566223a2268747470733a2f2f622e6578616d706c65227dc601030104046c696e6b046e756c6c0101010901",
                    delta:
                        #"[{"insert":"a","attributes":{"link":{"href":"https://a.example"}}},{"insert":"bcd","attributes":{"link":{"href":"https://b.example"}}},{"insert":"efgh"}]"#
                ),
                Step(
                    op: Op(op: "format", index: 0, length: 5, attrs: [("textColor", "\"red\"")]),
                    update:
                        "0102010c4601080974657874436f6c6f72052272656422c6010401050974657874436f6c6f72046e756c6c0101010901",
                    txUpdate:
                        "0102010c4601080974657874436f6c6f72052272656422c6010401050974657874436f6c6f72046e756c6c00",
                    delta:
                        #"[{"insert":"a","attributes":{"textColor":"red","link":{"href":"https://a.example"}}},{"insert":"bcd","attributes":{"textColor":"red","link":{"href":"https://b.example"}}},{"insert":"e","attributes":{"textColor":"red"}},{"insert":"fgh"}]"#
                ),
            ],
            finalState:
                "010b01000401017401618401000262638401020164840103016584010403666768460100046c696e6b1c7b2268726566223a2268747470733a2f2f612e6578616d706c65227dc601020103046c696e6b046e756c6cc601000101046c696e6b1c7b2268726566223a2268747470733a2f2f622e6578616d706c65227dc601030104046c696e6b046e756c6c4601080974657874436f6c6f72052272656422c6010401050974657874436f6c6f72046e756c6c0101010901"
        ),
        Scenario(
            name: "delete-across-format-boundary (C2)",
            nested: false,
            seedOps: [
                Op(op: "insert", index: 0, text: "abcdefgh")
            ],
            seed: "010101000401017408616263646566676800",
            steps: [
                Step(
                    op: Op(op: "format", index: 2, length: 3, attrs: [("bold", "true")]),
                    update: "01020108c60101010204626f6c640474727565c60104010504626f6c64046e756c6c00",
                    txUpdate: "01020108c60101010204626f6c640474727565c60104010504626f6c64046e756c6c00",
                    delta: #"[{"insert":"ab"},{"insert":"cde","attributes":{"bold":true}},{"insert":"fgh"}]"#),
                Step(
                    op: Op(op: "delete", index: 3, length: 4),
                    update: "000101010304",
                    txUpdate: "000101010304",
                    delta: #"[{"insert":"ab"},{"insert":"c","attributes":{"bold":true}},{"insert":"h"}]"#),
                Step(
                    op: Op(op: "delete", index: 0, length: 3),
                    update: "0001010200070802",
                    txUpdate: "0001010200030802",
                    delta: #"[{"insert":"h"}]"#),
                Step(
                    op: Op(op: "delete", index: 0, length: 10),
                    update: "00010101000a",
                    txUpdate: "000101010701",
                    delta: #"[]"#),
            ],
            finalState:
                "01050100040101740261628401010363646584010403666768c60101010204626f6c640474727565c60104010504626f6c64046e756c6c010101000a"
        ),
        Scenario(
            name: "delete-whole-formatted-run",
            nested: false,
            seedOps: [
                Op(op: "insert", index: 0, text: "abcdefgh")
            ],
            seed: "010101000401017408616263646566676800",
            steps: [
                Step(
                    op: Op(op: "format", index: 2, length: 3, attrs: [("bold", "true")]),
                    update: "01020108c60101010204626f6c640474727565c60104010504626f6c64046e756c6c00",
                    txUpdate: "01020108c60101010204626f6c640474727565c60104010504626f6c64046e756c6c00",
                    delta: #"[{"insert":"ab"},{"insert":"cde","attributes":{"bold":true}},{"insert":"fgh"}]"#),
                Step(
                    op: Op(op: "format", index: 5, length: 2, attrs: [("italic", "true")]),
                    update: "0102010ac601090105066974616c69630474727565c601060107066974616c6963046e756c6c00",
                    txUpdate: "0102010ac601090105066974616c69630474727565c601060107066974616c6963046e756c6c00",
                    delta:
                        #"[{"insert":"ab"},{"insert":"cde","attributes":{"bold":true}},{"insert":"fg","attributes":{"italic":true}},{"insert":"h"}]"#
                ),
                Step(
                    op: Op(op: "delete", index: 2, length: 3),
                    update: "0001010202030802",
                    txUpdate: "0001010202030802",
                    delta: #"[{"insert":"ab"},{"insert":"fg","attributes":{"italic":true}},{"insert":"h"}]"#),
                Step(
                    op: Op(op: "insert", index: 2, text: "Z"),
                    update: "0101010cc40109010a015a01010202030802",
                    txUpdate: "0101010cc40109010a015a00",
                    delta: #"[{"insert":"abZ"},{"insert":"fg","attributes":{"italic":true}},{"insert":"h"}]"#),
            ],
            finalState:
                "0109010004010174026162840101036364658401040266678401060168c60101010204626f6c640474727565c60104010504626f6c64046e756c6cc601090105066974616c69630474727565c601060107066974616c6963046e756c6cc40109010a015a01010202030802"
        ),
        Scenario(
            name: "embeds",
            nested: false,
            seedOps: [
                Op(op: "insert", index: 0, text: "abcd")
            ],
            seed: "0101010004010174046162636400",
            steps: [
                Step(
                    op: Op(op: "embed", index: 2, embed: "{\"type\":\"mention\",\"id\":\"u1\"}"),
                    update: "01010104c5010101021c7b2274797065223a226d656e74696f6e222c226964223a227531227d00",
                    txUpdate: "01010104c5010101021c7b2274797065223a226d656e74696f6e222c226964223a227531227d00",
                    delta: #"[{"insert":"ab"},{"insert":{"type":"mention","id":"u1"}},{"insert":"cd"}]"#),
                Step(
                    op: Op(op: "embed", index: 0, embed: "{\"image\":\"x\"}", attrs: [("bold", "true")]),
                    update:
                        "0103010546010004626f6c640474727565c5010501000d7b22696d616765223a2278227dc60106010004626f6c64046e756c6c00",
                    txUpdate:
                        "0103010546010004626f6c640474727565c5010501000d7b22696d616765223a2278227dc60106010004626f6c64046e756c6c00",
                    delta:
                        #"[{"insert":{"image":"x"},"attributes":{"bold":true}},{"insert":"ab"},{"insert":{"type":"mention","id":"u1"}},{"insert":"cd"}]"#
                ),
                Step(
                    op: Op(op: "insert", index: 1, text: "q"),
                    update: "01010108c401060107017100",
                    txUpdate: "01010108c401060107017100",
                    delta:
                        #"[{"insert":{"image":"x"},"attributes":{"bold":true}},{"insert":"q","attributes":{"bold":true}},{"insert":"ab"},{"insert":{"type":"mention","id":"u1"}},{"insert":"cd"}]"#
                ),
                Step(
                    op: Op(op: "delete", index: 3, length: 2),
                    update: "0001010201010401",
                    txUpdate: "0001010201010401",
                    delta:
                        #"[{"insert":{"image":"x"},"attributes":{"bold":true}},{"insert":"q","attributes":{"bold":true}},{"insert":"acd"}]"#
                ),
                Step(
                    op: Op(op: "format", index: 0, length: 4, attrs: [("italic", "true")]),
                    update: "01020109460105066974616c69630474727565c601020103066974616c6963046e756c6c01010201010401",
                    txUpdate: "01020109460105066974616c69630474727565c601020103066974616c6963046e756c6c00",
                    delta:
                        #"[{"insert":{"image":"x"},"attributes":{"italic":true,"bold":true}},{"insert":"q","attributes":{"italic":true,"bold":true}},{"insert":"ac","attributes":{"italic":true}},{"insert":"d"}]"#
                ),
            ],
            finalState:
                "010b0100040101740161840100016284010101638401020164c5010101021c7b2274797065223a226d656e74696f6e222c226964223a227531227d46010004626f6c640474727565c5010501000d7b22696d616765223a2278227dc60106010004626f6c64046e756c6cc4010601070171460105066974616c69630474727565c601020103066974616c6963046e756c6c01010201010401"
        ),
        Scenario(
            name: "surrogate-pairs",
            nested: false,
            seedOps: [
                Op(op: "insert", index: 0, text: "abcd")
            ],
            seed: "0101010004010174046162636400",
            steps: [
                Step(
                    op: Op(op: "insert", index: 2, text: "😀"),
                    update: "01010104c40101010204f09f988000",
                    txUpdate: "01010104c40101010204f09f988000",
                    delta: #"[{"insert":"ab😀cd"}]"#),
                Step(
                    op: Op(op: "format", index: 1, length: 3, attrs: [("bold", "true")]),
                    update: "01020106c60100010104626f6c640474727565c60105010204626f6c64046e756c6c00",
                    txUpdate: "01020106c60100010104626f6c640474727565c60105010204626f6c64046e756c6c00",
                    delta: #"[{"insert":"a"},{"insert":"b😀","attributes":{"bold":true}},{"insert":"cd"}]"#),
                Step(
                    op: Op(op: "insert", index: 5, text: "é😁"),
                    update: "01010108c40102010306c3a9f09f988100",
                    txUpdate: "01010108c40102010306c3a9f09f988100",
                    delta: #"[{"insert":"a"},{"insert":"b😀","attributes":{"bold":true}},{"insert":"cé😁d"}]"#),
                Step(
                    op: Op(op: "delete", index: 2, length: 2),
                    update: "000101010402",
                    txUpdate: "000101010402",
                    delta: #"[{"insert":"a"},{"insert":"b","attributes":{"bold":true}},{"insert":"cé😁d"}]"#),
                Step(
                    op: Op(op: "insert", index: 3, text: "|"),
                    update: "0101010bc401020108017c0101010402",
                    txUpdate: "0101010bc401020108017c00",
                    delta: #"[{"insert":"a"},{"insert":"b","attributes":{"bold":true}},{"insert":"c|é😁d"}]"#),
            ],
            finalState:
                "01090100040101740161840100016284010101638401020164c40101010204f09f9880c60100010104626f6c640474727565c60105010204626f6c64046e756c6cc40102010306c3a9f09f9881c401020108017c0101010402"
        ),
        Scenario(
            name: "split-inside-surrogate-pair",
            nested: false,
            seedOps: [
                Op(op: "insert", index: 0, text: "a😀b😁c")
            ],
            seed: "01010100040101740b61f09f988062f09f98816300",
            steps: [
                Step(
                    op: Op(op: "insert", index: 1, text: "X"),
                    update: "01010107c401000101015800",
                    txUpdate: "01010107c401000101015800",
                    delta: #"[{"insert":"aX😀b😁c"}]"#),
                Step(
                    op: Op(op: "delete", index: 4, length: 1),
                    update: "000101010301",
                    txUpdate: "000101010301",
                    delta: #"[{"insert":"aX😀😁c"}]"#),
                Step(
                    op: Op(op: "format", index: 3, length: 1, attrs: [("bold", "true")]),
                    update: "01020108c60101010204626f6c640474727565c60103010404626f6c64046e756c6c0101010301",
                    txUpdate: "01020108c60101010204626f6c640474727565c60103010404626f6c64046e756c6c00",
                    delta: #"[{"insert":"aX�"},{"insert":"�","attributes":{"bold":true}},{"insert":"😁c"}]"#),
            ],
            finalState:
                "0108010004010174016184010003efbfbd84010103efbfbd840102016284010305f09f988163c4010001010158c60101010204626f6c640474727565c60103010404626f6c64046e756c6c0101010301"
        ),
        Scenario(
            name: "out-of-range",
            nested: false,
            seedOps: [
                Op(op: "insert", index: 0, text: "abcdef")
            ],
            seed: "01010100040101740661626364656600",
            steps: [
                Step(
                    op: Op(op: "insert", index: 99, text: "Z"),
                    update: "01010106840105015a00",
                    txUpdate: "01010106840105015a00",
                    delta: #"[{"insert":"abcdefZ"}]"#),
                Step(
                    op: Op(op: "delete", index: 2, length: 99),
                    update: "000101010205",
                    txUpdate: "000101010205",
                    delta: #"[{"insert":"ab"}]"#),
                Step(
                    op: Op(op: "format", index: 1, length: 99, attrs: [("bold", "true")]),
                    update:
                        "01030107c60100010104626f6c640474727565840106620a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a86016904626f6c64046e756c6c0101010205",
                    txUpdate:
                        "01030107c60100010104626f6c640474727565840106620a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a86016904626f6c64046e756c6c00",
                    delta:
                        #"[{"insert":"a"},{"insert":"b\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n","attributes":{"bold":true}}]"#
                ),
                Step(
                    op: Op(op: "format", index: 50, length: 2, attrs: [("italic", "true")]),
                    update: "0102016bc601370138066974616c69630474727565c60139013a066974616c6963046e756c6c0101010205",
                    txUpdate: "0102016bc601370138066974616c69630474727565c60139013a066974616c6963046e756c6c00",
                    delta:
                        #"[{"insert":"a"},{"insert":"b\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n","attributes":{"bold":true}},{"insert":"\n\n","attributes":{"bold":true,"italic":true}},{"insert":"\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n","attributes":{"bold":true}}]"#
                ),
                Step(
                    op: Op(op: "delete", index: 50, length: 2),
                    update: "00010103020538026b02",
                    txUpdate: "0001010238026b02",
                    delta:
                        #"[{"insert":"a"},{"insert":"b\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n","attributes":{"bold":true}}]"#
                ),
            ],
            finalState:
                "010a0100040101740161840100016284010105636465665ac60100010104626f6c640474727565840106300a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a840137020a0a840139300a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a86016904626f6c64046e756c6cc601370138066974616c69630474727565c60139013a066974616c6963046e756c6c010103020538026b02"
        ),
        Scenario(
            name: "nested-xmltext",
            nested: true,
            seedOps: [],
            seed: "0102010007010e646f63756d656e742d73746f72650309706172616772617068070001000600",
            steps: [
                Step(
                    op: Op(op: "insert", index: 0, text: "Hello world"),
                    update: "01010102040001010b48656c6c6f20776f726c6400",
                    txUpdate: "01010102040001010b48656c6c6f20776f726c6400",
                    delta: #"[{"insert":"Hello world"}]"#),
                Step(
                    op: Op(op: "format", index: 0, length: 5, attrs: [("bold", "true")]),
                    update: "0102010d46010204626f6c640474727565c60106010704626f6c64046e756c6c00",
                    txUpdate: "0102010d46010204626f6c640474727565c60106010704626f6c64046e756c6c00",
                    delta: #"[{"insert":"Hello","attributes":{"bold":true}},{"insert":" world"}]"#),
                Step(
                    op: Op(op: "insert", index: 5, text: "!"),
                    update: "0101010fc40106010e012100",
                    txUpdate: "0101010fc40106010e012100",
                    delta: #"[{"insert":"Hello!","attributes":{"bold":true}},{"insert":" world"}]"#),
                Step(
                    op: Op(op: "delete", index: 4, length: 3),
                    update: "0001010206020f01",
                    txUpdate: "0001010206020f01",
                    delta: #"[{"insert":"Hell","attributes":{"bold":true}},{"insert":"world"}]"#),
                Step(
                    op: Op(op: "embed", index: 2, embed: "{\"m\":1}"),
                    update:
                        "01030110c60103010404626f6c64046e756c6cc501100104077b226d223a317dc60111010404626f6c64047472756501010206020f01",
                    txUpdate:
                        "01030110c60103010404626f6c64046e756c6cc501100104077b226d223a317dc60111010404626f6c64047472756500",
                    delta:
                        #"[{"insert":"He","attributes":{"bold":true}},{"insert":{"m":1}},{"insert":"ll","attributes":{"bold":true}},{"insert":"world"}]"#
                ),
            ],
            finalState:
                "010d010007010e646f63756d656e742d73746f72650309706172616772617068070001000604000101024865840103026c6c840105016f840106012084010705776f726c6446010204626f6c640474727565c60106010704626f6c64046e756c6cc40106010e0121c60103010404626f6c64046e756c6cc501100104077b226d223a317dc60111010404626f6c64047472756501010206020f01"
        ),
    ]

    // MARK: - Replay

    func testEveryScenarioReplaysOpForOp() throws {
        for scenario in scenarios {
            try replay(scenario)
        }
    }

    /// The C2 case, named on its own: a delete that spans a format boundary.
    ///
    /// yjs deletes the `ContentFormat` items the deletion made redundant, so the
    /// surviving text keeps only the attributes still in force — here the bold run
    /// `cde` loses `de` and the leftover `c` keeps its bold, while `h` stays plain.
    func testDeleteAcrossFormatBoundaryC2() throws {
        let scenario = try XCTUnwrap(
            scenarios.first { $0.name.hasPrefix("delete-across-format-boundary") })
        let doc = makeDoc()
        defer { doc.destroy() }
        let text = try text(of: scenario, in: doc)
        for op in scenario.seedOps { try apply(op, to: text) }
        try apply(scenario.steps[0].op, to: text)  // bold [2, 5)
        XCTAssertEqual(visibleText(text), "abcdefgh")
        try apply(scenario.steps[1].op, to: text)  // delete [3, 7), across the boundary
        XCTAssertEqual(visibleText(text), "abch")
        XCTAssertEqual(
            toDelta(text), try XCTUnwrap(YJSONValue.parse(scenario.steps[1].delta)))
        try replay(scenario)
    }

    /// A format past the end pads the text with `'\n'` (yjs @6584) — Quill's
    /// trailing-newline convention, not a clamp.
    func testFormatPastTheEndPadsWithNewlines() throws {
        let doc = makeDoc()
        defer { doc.destroy() }
        let text = doc.getText("t")
        try text.insert(0, "ab")
        try text.format(1, 4, ["bold": "true"])
        XCTAssertEqual(visibleText(text), "ab\n\n\n")
        XCTAssertEqual(
            toDelta(text),
            .array([
                .object(["insert": .string("a")]),
                .object(["insert": .string("b\n\n\n"), "attributes": .object(["bold": .bool(true)])]),
            ]))
    }

    /// An insert past the end appends, and a delete past the end stops at the end
    /// (yjs does not clamp; the caller does).
    func testOutOfRangeInsertAppendsAndDeleteStopsAtTheEnd() throws {
        let doc = makeDoc()
        defer { doc.destroy() }
        let text = doc.getText("t")
        try text.insert(0, "abc")
        try text.insert(99, "Z")
        XCTAssertEqual(visibleText(text), "abcZ")
        try text.delete(2, 99)
        XCTAssertEqual(visibleText(text), "ab")
    }

    /// Object-valued attributes are compared by **identity**, not structure.
    ///
    /// yjs's `cleanupFormattingGap` tests `startAttrValue === value` (@6627), which
    /// for an object value is reference identity: two `ContentFormat` items whose
    /// `link` values are structurally equal but distinct objects are not
    /// interchangeable. Schrift models this with
    /// `YFormatAttrValue.object(ObjectIdentifier(value.identity))` — independently
    /// supplied values have separate tokens, while restored values retain theirs.
    /// A wire round-trip also creates separate tokens, since the decoder parses
    /// each value independently. The ops
    /// path keeps the other rule (`equalAttrs`, structural) for the same map.
    func testObjectAttributeValuesCompareByIdentity() throws {
        let doc = makeDoc()
        defer { doc.destroy() }
        let text = doc.getText("t")
        try text.insert(0, "ab")
        try text.format(0, 1, YTextAttributes([("link", #"{"href":"h"}"#)]))
        try text.insert(2, "x", YTextAttributes([("link", #"{"href":"h"}"#)]))

        var linkItems: [YItem] = []
        var item = text.start
        while let current = item {
            if !current.deleted, case .format(let key, _) = current.content, key == "link",
                YFormatAttrValue.of(current) != nil
            {
                linkItems.append(current)
            }
            item = current.right
        }
        XCTAssertEqual(linkItems.count, 2, "two link formats, one per insert")
        let first = try XCTUnwrap(YFormatAttrValue.of(linkItems[0]))
        let second = try XCTUnwrap(YFormatAttrValue.of(linkItems[1]))
        XCTAssertNotEqual(first, second, "structurally equal object values are distinct identities")
        guard case .object = first, case .object = second else {
            return XCTFail("object values must use the identity case")
        }
    }

    /// Transaction bytes, delta and full state captured from yjs 13.6.33.
    func testRestoredObjectAttributeKeepsItsIdentity() throws {
        let doc = makeDoc()
        defer { doc.destroy() }
        let text = doc.getText("t")
        let ops: [Op] = [
            Op(op: "insert", index: 0, text: "abc", attrs: [("link", #"{"href":"h"}"#)]),
            Op(op: "insert", index: 1, text: "X", attrs: []),
            Op(op: "delete", index: 1, length: 1),
        ]
        let updates = [
            "0103010006010174046c696e6b0c7b2268726566223a2268227d84010003616263860103046c696e6b046e756c6c00",
            "01030105c601010102046c696e6b046e756c6cc4010501020158c601060102046c696e6b0c7b2268726566223a2268227d00",
            "000101010503",
        ]
        for (index, op) in ops.enumerated() {
            var captured: YTransaction?
            try doc.transact { transaction in
                captured = transaction
                try apply(op, to: text)
            }
            XCTAssertEqual(
                try YTransactionEncoder.encodeUpdate(XCTUnwrap(captured))?.hexString,
                updates[index], "op \(index): transaction update")
        }
        XCTAssertEqual(
            toDelta(text), try XCTUnwrap(YJSONValue.parse(#"[{"insert":"abc","attributes":{"link":{"href":"h"}}}]"#)))
        XCTAssertEqual(
            try YStateEncoder.encodeStateAsUpdate(doc).hexString,
            "0107010006010174046c696e6b0c7b2268726566223a2268227d8401000161840101026263860103046c696e6b046e756c6cc601010102046c696e6b046e756c6cc4010501020158c601060102046c696e6b0c7b2268726566223a2268227d0101010503"
        )
    }

    /// Transaction bytes, delta and full state captured from yjs 13.6.33.
    func testUnicodeEquivalentAttributeValuesAreDistinct() throws {
        let doc = makeDoc()
        defer { doc.destroy() }
        let text = doc.getText("t")
        let ops: [Op] = [
            Op(op: "insert", index: 0, text: "a", attrs: [("link", "\"https://example.com/\u{00E9}\"")]),
            Op(op: "format", index: 0, length: 1, attrs: [("link", "\"https://example.com/e\u{0301}\"")]),
        ]
        let updates = [
            "0103010006010174046c696e6b182268747470733a2f2f6578616d706c652e636f6d2fc3a9228401000161860101046c696e6b046e756c6c00",
            "01020103460100046c696e6b192268747470733a2f2f6578616d706c652e636f6d2f65cc8122c601010102046c696e6b182268747470733a2f2f6578616d706c652e636f6d2fc3a9220101010001",
        ]
        for (index, op) in ops.enumerated() {
            var captured: YTransaction?
            try doc.transact { transaction in
                captured = transaction
                try apply(op, to: text)
            }
            XCTAssertEqual(
                try YTransactionEncoder.encodeUpdate(XCTUnwrap(captured))?.hexString,
                updates[index], "op \(index): transaction update")
        }
        XCTAssertEqual(
            toDelta(text),
            try XCTUnwrap(YJSONValue.parse(#"[{"insert":"a","attributes":{"link":"https://example.com/é"}}]"#)))
        XCTAssertEqual(
            try YStateEncoder.encodeStateAsUpdate(doc).hexString,
            "0105010006010174046c696e6b182268747470733a2f2f6578616d706c652e636f6d2fc3a9228401000161860101046c696e6b046e756c6c460100046c696e6b192268747470733a2f2f6578616d706c652e636f6d2f65cc8122c601010102046c696e6b182268747470733a2f2f6578616d706c652e636f6d2fc3a9220101010001"
        )
    }

    // MARK: - Helpers

    private func makeDoc() -> YDoc { YDoc(clientID: 1, gc: false) }

    /// The text a scenario operates on: the root `t`, or the `XmlText` inside
    /// `document-store > paragraph` — the BlockNote shape the oracle builds.
    private func text(of scenario: Scenario, in doc: YDoc) throws -> YType {
        guard scenario.nested else { return doc.getText("t") }
        let fragment = doc.get("document-store")
        let paragraph = YType(typeRef: .xmlElement(nodeName: "paragraph"))
        let text = YType(typeRef: .xmlText)
        try doc.transact { tx in
            try YWrite.insertAfter(tx, into: fragment, after: nil, [.type(paragraph)])
            try YWrite.insertAfter(tx, into: paragraph, after: nil, [.type(text)])
        }
        return text
    }

    private func apply(_ op: Op, to text: YType) throws {
        switch op.op {
        case "insert":
            if let attrs = op.attrs {
                try text.insert(op.index, op.text!, YTextAttributes(attrs))
            } else {
                try text.insert(op.index, op.text!)
            }
        case "embed":
            if let attrs = op.attrs {
                try text.insertEmbed(op.index, op.embed!, YTextAttributes(attrs))
            } else {
                try text.insertEmbed(op.index, op.embed!)
            }
        case "delete":
            try text.delete(op.index, op.length!)
        case "format":
            try text.format(op.index, op.length!, YTextAttributes(op.attrs!))
        default:
            XCTFail("unknown op \(op.op)")
        }
    }

    private func replay(_ scenario: Scenario) throws {
        let doc = makeDoc()
        defer { doc.destroy() }
        let text = try text(of: scenario, in: doc)
        for op in scenario.seedOps { try apply(op, to: text) }
        XCTAssertEqual(
            try YStateEncoder.encodeStateAsUpdate(doc).hexString, scenario.seed,
            "\(scenario.name): seed state")
        for (index, step) in scenario.steps.enumerated() {
            let before = doc.store.getStateVector()
            var captured: YTransaction?
            try doc.transact { transaction in
                captured = transaction
                try apply(step.op, to: text)
            }
            let transaction = try XCTUnwrap(captured)
            XCTAssertEqual(
                try YStateEncoder.encodeStateAsUpdate(doc, since: before).hexString, step.update,
                "\(scenario.name) step \(index): update bytes")
            // What the editor actually broadcasts: yjs's per-transaction `'update'`
            // event bytes, which carry only this transaction's own deletes rather
            // than the store's whole delete set.
            XCTAssertEqual(
                try YTransactionEncoder.encodeUpdate(transaction)?.hexString, step.txUpdate,
                "\(scenario.name) step \(index): transaction update bytes")
            XCTAssertEqual(
                toDelta(text), try XCTUnwrap(YJSONValue.parse(step.delta)),
                "\(scenario.name) step \(index): delta")
        }
        XCTAssertEqual(
            try YStateEncoder.encodeStateAsUpdate(doc).hexString, scenario.finalState,
            "\(scenario.name): final state")
    }

    /// The visible text — undeleted `ContentString` units, concatenated.
    private func visibleText(_ type: YType) -> String {
        var units: [UInt16] = []
        var item = type.start
        while let current = item {
            if !current.deleted, case .string(let run) = current.content { units += run }
            item = current.right
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// yjs `YText.toDelta()` (@7247) as the JSON value the oracle records: visible
    /// items only, `ContentString` runs packed with the attributes in force, and
    /// `ContentEmbed`/`ContentType` as their own op.
    private func toDelta(_ type: YType) -> YJSONValue {
        var ops: [YJSONValue] = []
        var current: [String: String] = [:]
        var run: [UInt16] = []

        func attributes() -> [YJSONKey: YJSONValue] {
            var result: [YJSONKey: YJSONValue] = [:]
            for (key, json) in current { result[YJSONKey(key)] = YJSONValue.parse(json) ?? .null }
            return result
        }
        func packRun() {
            guard !run.isEmpty else { return }
            var op: [YJSONKey: YJSONValue] = [
                "insert": .string(String(decoding: run, as: UTF16.self))
            ]
            if !current.isEmpty { op["attributes"] = .object(attributes()) }
            ops.append(.object(op))
            run = []
        }

        var node = type.start
        while let item = node {
            if !item.deleted {
                switch item.content {
                case .string(let units):
                    run += units
                case .embed(let json):
                    packRun()
                    var op: [YJSONKey: YJSONValue] = ["insert": YJSONValue.parse(json) ?? .null]
                    if !current.isEmpty { op["attributes"] = .object(attributes()) }
                    ops.append(.object(op))
                case .type:
                    // No fixture embeds a shared type; the branch keeps the switch total.
                    packRun()
                    ops.append(.object(["insert": .string("<type>")]))
                case .format(let key, let valueJSON):
                    packRun()
                    if valueJSON == "null" {
                        current.removeValue(forKey: key)
                    } else {
                        current[key] = valueJSON
                    }
                case .deleted, .json, .binary, .any, .doc:
                    break
                }
            }
            node = item.right
        }
        packRun()
        return .array(ops)
    }
}
