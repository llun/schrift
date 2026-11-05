import XCTest

@testable import Schrift

// MARK: - Oracle record model

/// One `afterTransaction` record, in the shape the yjs oracle stores it: the
/// origin, whether the transaction was local, and the events in the order they
/// were raised.
///
/// The oracle also stores `changedParentTypes` per record. That is derivable from
/// the events — `callTypeObservers` records each event at its target and at every
/// ancestor — so the literals below list only the events, and the assertion
/// derives the expected map from them. The actual map is read from the
/// transaction, so a missing ancestor still fails.
struct YChangeRecord {
    var origin: YTransactionOrigin?
    var local: Bool
    var events: [YEventRecord]
    var changed: [YChangedTypeRecord] = []
}

/// One `changedParentTypes` entry: the type's path from the root and the events
/// recorded there.
struct YChangedTypeRecord {
    var path: [YPathComponent]
    var events: [YEventRecord]
}

/// One event: the target's path from the root and, for a text target, its delta.
struct YEventRecord {
    var target: [YPathComponent]
    var delta: [YDeltaOp]?
}

extension YChangeRecord {
    /// Snapshot a transaction from inside `afterTransaction` — the only moment a
    /// delta is valid.
    init(_ transaction: YTransaction) {
        origin = transaction.origin
        local = transaction.local
        changed = transaction.changedParentTypes.map { entry in
            // The event's own `path` is its *target's* path — the same event is
            // shared by every ancestor. The entry's path is the ancestor type's,
            // so read it from an event whose target is the entry type.
            YChangedTypeRecord(
                path: YEvent(target: entry.type, transaction: transaction).path,
                events: entry.events.map(YEventRecord.init))
        }
        events = changed.first { $0.path.isEmpty }?.events ?? []
    }

    /// The `changedParentTypes` map the oracle would record for `events`: every
    /// event appears at its target and at every ancestor, in the order raised.
    static func changed(from events: [YEventRecord]) -> [[YPathComponent]: [YEventRecord]] {
        var paths: Set<[YPathComponent]> = []
        for event in events {
            for length in 0...event.target.count {
                paths.insert(Array(event.target.prefix(length)))
            }
        }
        var result: [[YPathComponent]: [YEventRecord]] = [:]
        for path in paths {
            result[path] = events.filter { Array($0.target.prefix(path.count)) == path }
        }
        return result
    }
}

extension YEventRecord {
    init(_ event: YEvent) {
        target = event.path
        delta = event.delta
    }
}

/// Captures every `afterTransaction` record, snapshotting deltas while they are
/// still valid.
///
/// A record with a nil origin and no changed types is dropped, matching the
/// oracle: yjs's delta getter opens an empty transaction when read inside the
/// hook, and a formatting-cleanup transaction that deletes nothing changes no
/// type. Neither is a change signal, and the oracle's `note` records the same
/// filter.
final class YChangeRecorder {
    private(set) var records: [YChangeRecord] = []

    func attach(to doc: YDoc) {
        doc.afterTransaction = { [weak self] transaction in
            let record = YChangeRecord(transaction)
            guard record.origin != nil || !record.changed.isEmpty else { return }
            self?.records.append(record)
        }
    }
}

/// Visible text of a type's child list — the concatenated `ContentString` units
/// of its undeleted children.
/// The number of `ContentEmbed` items in `type` — the delta's object inserts.
func visibleEmbedCount(of type: YType) -> Int {
    var count = 0
    var item = type.start
    while let current = item {
        if !current.deleted, case .embed = current.content { count += 1 }
        item = current.right
    }
    return count
}

func visibleText(of type: YType) -> String {
    var units: [UInt16] = []
    var item = type.start
    while let current = item {
        if !current.deleted, case .string(let text) = current.content { units += text }
        item = current.right
    }
    return String(decoding: units, as: UTF16.self)
}

// MARK: - Assertions

/// Compare a captured run against the oracle's records: same origins, same
/// `changedParentTypes` (paths and the events recorded at each), same deltas.
func assertChangeRecords(
    _ actual: [YChangeRecord], _ expected: [YChangeRecord],
    _ context: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    let label = context()
    XCTAssertEqual(actual.count, expected.count, "\(label): record count", file: file, line: line)
    for (index, pair) in zip(actual, expected).enumerated() {
        let (actualRecord, expectedRecord) = pair
        let recordLabel = "\(label) record \(index)"
        XCTAssertEqual(
            actualRecord.origin, expectedRecord.origin, "\(recordLabel): origin", file: file, line: line)
        XCTAssertEqual(
            actualRecord.local, expectedRecord.local, "\(recordLabel): local", file: file, line: line)

        var actualChanged: [[YPathComponent]: [YEventRecord]] = [:]
        for entry in actualRecord.changed {
            XCTAssertNil(
                actualChanged[entry.path],
                "\(recordLabel): duplicate changed path \(describePath(entry.path))",
                file: file, line: line)
            actualChanged[entry.path] = entry.events
        }
        let expectedChanged = YChangeRecord.changed(from: expectedRecord.events)
        XCTAssertEqual(
            Set(actualChanged.keys), Set(expectedChanged.keys),
            "\(recordLabel): changedParentTypes paths", file: file, line: line)
        for (path, expectedEvents) in expectedChanged {
            guard let actualEvents = actualChanged[path] else { continue }
            assertEventsEqual(
                actualEvents, expectedEvents,
                "\(recordLabel) changed \(describePath(path))", file: file, line: line)
        }
        assertEventsEqual(
            actualRecord.events, expectedRecord.events, "\(recordLabel): events", file: file, line: line)
    }
}

func assertEventsEqual(
    _ actual: [YEventRecord], _ expected: [YEventRecord], _ context: @autoclosure () -> String,
    file: StaticString = #filePath, line: UInt = #line
) {
    let label = context()
    XCTAssertEqual(actual.count, expected.count, "\(label): event count", file: file, line: line)
    for (index, pair) in zip(actual, expected).enumerated() {
        let (actualEvent, expectedEvent) = pair
        XCTAssertEqual(
            actualEvent.target, expectedEvent.target, "\(label) event \(index): target",
            file: file, line: line)
        assertDeltaEqual(
            actualEvent.delta, expectedEvent.delta, "\(label) event \(index): delta",
            file: file, line: line)
    }
}

func assertDeltaEqual(
    _ actual: [YDeltaOp]?, _ expected: [YDeltaOp]?, _ context: @autoclosure () -> String,
    file: StaticString = #filePath, line: UInt = #line
) {
    let label = context()
    guard let actual, let expected else {
        XCTAssertEqual(actual == nil, expected == nil, "\(label): nil-ness", file: file, line: line)
        return
    }
    XCTAssertEqual(actual.count, expected.count, "\(label): op count", file: file, line: line)
    for (index, pair) in zip(actual, expected).enumerated() {
        let (actualOp, expectedOp) = pair
        assertKindEqual(
            actualOp.kind, expectedOp.kind, "\(label) op \(index): kind", file: file, line: line)
        let actualAttributes = actualOp.attributes ?? [:]
        let expectedAttributes = expectedOp.attributes ?? [:]
        XCTAssertEqual(
            actualAttributes.keys.sorted(), expectedAttributes.keys.sorted(),
            "\(label) op \(index): attribute keys", file: file, line: line)
        for (key, expectedValue) in expectedAttributes {
            guard let actualValue = actualAttributes[key] else { continue }
            XCTAssertTrue(
                YJSONValue.equalAttrs(actualValue.jsonText, expectedValue.jsonText),
                "\(label) op \(index): attribute \(key) — \(actualValue) vs \(expectedValue)",
                file: file, line: line)
        }
    }
}

func assertKindEqual(
    _ actual: YDeltaOp.Kind, _ expected: YDeltaOp.Kind, _ context: @autoclosure () -> String,
    file: StaticString = #filePath, line: UInt = #line
) {
    let label = context()
    switch (actual, expected) {
    case (.insert(let actualValue), .insert(let expectedValue)):
        switch (actualValue, expectedValue) {
        case (.text(let a), .text(let b)):
            XCTAssertEqual(a, b, "\(label): inserted text", file: file, line: line)
        case (.embed(let a), .embed(let b)):
            XCTAssertTrue(YJSONValue.equalAttrs(a, b), "\(label): embedded value", file: file, line: line)
        case (.type(let a), .type(let b)):
            XCTAssertTrue(a === b, "\(label): embedded type", file: file, line: line)
        default:
            XCTFail(
                "\(label): insert kind mismatch — \(actualValue) vs \(expectedValue)",
                file: file, line: line)
        }
    case (.retain(let a), .retain(let b)):
        XCTAssertEqual(a, b, "\(label): retain length", file: file, line: line)
    case (.delete(let a), .delete(let b)):
        XCTAssertEqual(a, b, "\(label): delete length", file: file, line: line)
    default:
        XCTFail("\(label): op kind mismatch — \(actual) vs \(expected)", file: file, line: line)
    }
}

func describePath(_ path: [YPathComponent]) -> String {
    "["
        + path.map { component in
            switch component {
            case .index(let index): return String(index)
            case .key(let key): return "\"\(key)\""
            }
        }.joined(separator: ", ") + "]"
}

// MARK: - Tests

/// The change signal (`YDoc.afterTransaction`) against the yjs 13.6.33 oracle in
/// `.review/oracle.json` (session-local, never committed).
///
/// Every record is compared as the oracle stores it: the origin, whether the
/// transaction was local, the `changedParentTypes` paths with the events recorded
/// at each, and each text event's delta. The expected literals list the events in
/// the order they were raised; `assertChangeRecords` derives the expected
/// `changedParentTypes` from them and compares it against the transaction's own.
final class YAfterTransactionTests: XCTestCase {

    private struct Scenario {
        let name: String
        let checkpoints: [(label: String, updateBase64: String, xml: String)]
        let expected: [YChangeRecord]
    }

    // MARK: - BlockNote 0.56 scenarios (remote)

    /// The eight committed BlockNote 0.56 fixtures, replayed as remote updates.
    /// The seed is applied before the recorder attaches, exactly as the oracle
    /// records it; each step then produces one record.
    private static var scenarios: [Scenario] {
        [
            Scenario(
                name: "a-typing-marks-link-color",
                checkpoints: BlockNote056TypingMarksLinkColorTests.checkpoints,
                expected: [
                    YChangeRecord(
                        origin: .remote,
                        local: false,
                        events: [
                            YEventRecord(target: [0, 0, 0], delta: nil)
                        ]),
                    YChangeRecord(
                        origin: .remote,
                        local: false,
                        events: [
                            YEventRecord(
                                target: [0, 0, 0, 0], delta: [.retain(3), .insert("there", attributes: ["bold": "{}"])])
                        ]),
                    YChangeRecord(
                        origin: .remote,
                        local: false,
                        events: [
                            YEventRecord(
                                target: [0, 0, 0, 0],
                                delta: [
                                    .retain(8), .insert(" "),
                                    .insert("link", attributes: ["link": "{\"href\":\"https://example.com/\"}"]),
                                ])
                        ]),
                    YChangeRecord(
                        origin: .remote,
                        local: false,
                        events: [
                            YEventRecord(
                                target: [0, 0, 0, 0],
                                delta: [
                                    .retain(13),
                                    .insert(" red", attributes: ["textColor": "{\"stringValue\":\"red\"}"]),
                                ])
                        ]),
                ]),
            Scenario(
                name: "b-toggle-bold-on-off",
                checkpoints: BlockNote056ToggleBoldOnOffTests.checkpoints,
                expected: [
                    YChangeRecord(
                        origin: .remote,
                        local: false,
                        events: [
                            YEventRecord(
                                target: [0, 0, 0, 0], delta: [.retain(2), .retain(4, attributes: ["bold": "{}"])])
                        ]),
                    YChangeRecord(
                        origin: .remote,
                        local: false,
                        events: [
                            YEventRecord(
                                target: [0, 0, 0, 0], delta: [.retain(2), .retain(7, attributes: ["bold": .null])])
                        ]),
                ]),
            Scenario(
                name: "c-split-paragraph",
                checkpoints: BlockNote056SplitParagraphTests.checkpoints,
                expected: [
                    YChangeRecord(
                        origin: .remote,
                        local: false,
                        events: [
                            YEventRecord(target: [0], delta: nil),
                            YEventRecord(target: [0, 0, 0, 0], delta: [.retain(5), .delete(5)]),
                        ])
                ]),
            Scenario(
                name: "d-merge-paragraphs",
                checkpoints: BlockNote056MergeParagraphsTests.checkpoints,
                expected: [
                    YChangeRecord(
                        origin: .remote,
                        local: false,
                        events: [
                            YEventRecord(target: [0, 0, 0, 0], delta: [.retain(5), .insert("World")]),
                            YEventRecord(target: [0], delta: nil),
                        ])
                ]),
            Scenario(
                name: "e-change-block-types",
                checkpoints: BlockNote056ChangeBlockTypesTests.checkpoints,
                expected: [
                    YChangeRecord(
                        origin: .remote,
                        local: false,
                        events: [
                            YEventRecord(target: [0, 0], delta: nil)
                        ]),
                    YChangeRecord(
                        origin: .remote,
                        local: false,
                        events: [
                            YEventRecord(target: [0, 1], delta: nil)
                        ]),
                ]),
            Scenario(
                name: "f-sink-bullet",
                checkpoints: BlockNote056SinkBulletTests.checkpoints,
                expected: [
                    YChangeRecord(
                        origin: .remote,
                        local: false,
                        events: [
                            YEventRecord(target: [0, 0], delta: nil),
                            YEventRecord(target: [0], delta: nil),
                        ])
                ]),
            Scenario(
                name: "g-mixed-inline-edit",
                checkpoints: BlockNote056MixedInlineEditTests.checkpoints,
                expected: [
                    YChangeRecord(
                        origin: .remote,
                        local: false,
                        events: [
                            YEventRecord(target: [0, 0, 0, 2], delta: [.retain(4), .insert("!")])
                        ])
                ]),
            Scenario(
                name: "h-table-operations",
                checkpoints: BlockNote056TableOperationsTests.checkpoints,
                expected: [
                    YChangeRecord(
                        origin: .remote,
                        local: false,
                        events: [
                            YEventRecord(target: [0], delta: nil)
                        ]),
                    YChangeRecord(
                        origin: .remote,
                        local: false,
                        events: [
                            YEventRecord(target: [0, 1, 0, 0, 0, 0], delta: nil)
                        ]),
                    YChangeRecord(
                        origin: .remote,
                        local: false,
                        events: [
                            YEventRecord(target: [0, 1, 0], delta: nil)
                        ]),
                    YChangeRecord(
                        origin: .remote,
                        local: false,
                        events: [
                            YEventRecord(target: [0, 1, 0, 0], delta: nil),
                            YEventRecord(target: [0, 1, 0, 2], delta: nil),
                            YEventRecord(target: [0, 1, 0, 1], delta: nil),
                        ]),
                    YChangeRecord(
                        origin: .remote,
                        local: false,
                        events: [
                            YEventRecord(target: [0, 1, 0, 0], delta: nil)
                        ]),
                ]),
        ]
    }

    func testBlockNoteScenariosMatchYjs() throws {
        continueAfterFailure = false
        for scenario in Self.scenarios {
            let doc = YDoc(clientID: 9, gc: false)
            defer { doc.destroy() }
            let seed = try XCTUnwrap(Data(base64Encoded: scenario.checkpoints[0].updateBase64))
            try doc.applyUpdate(try YUpdateDecoder.decode(seed), origin: .remote)
            let recorder = YChangeRecorder()
            recorder.attach(to: doc)
            for checkpoint in scenario.checkpoints.dropFirst() {
                let update = try XCTUnwrap(Data(base64Encoded: checkpoint.updateBase64))
                try doc.applyUpdate(try YUpdateDecoder.decode(update), origin: .remote)
            }
            assertChangeRecords(recorder.records, scenario.expected, scenario.name)
        }
    }

    // MARK: - Concurrent bold cleanup (remote)

    /// The concurrent-bold sequence from `YDocUpdateEventTests`: three peer
    /// updates, then the formatting-cleanup transaction the observer phase opens
    /// with origin nil. The cleanup transaction raises its own event (an empty
    /// delta) — yjs emits `afterTransaction` for it too.
    func testConcurrentBoldCleanupMatchesYjs() throws {
        let doc = YDoc(clientID: 9, gc: false)
        defer { doc.destroy() }
        doc.getText("t")
        let recorder = YChangeRecorder()
        recorder.attach(to: doc)

        let updates = [
            "01010100040101740b68656c6c6f20776f726c6400",  // t = "hello world"
            "0102020046010004626f6c640474727565c60104010504626f6c64046e756c6c00",  // client 2 bold [0,5)
            "0102010b46010004626f6c640474727565c60104010504626f6c64046e756c6c00",  // client 1 bold [0,5)
        ]
        for hex in updates {
            try doc.applyUpdate(try YUpdateDecoder.decode(Data(hex: hex)), origin: .remote)
        }

        assertChangeRecords(
            recorder.records,
            [
                YChangeRecord(
                    origin: .remote,
                    local: false,
                    events: [
                        YEventRecord(target: [], delta: [.insert("hello world")])
                    ]),
                YChangeRecord(
                    origin: .remote,
                    local: false,
                    events: [
                        YEventRecord(target: [], delta: [.retain(5, attributes: ["bold": "true"])])
                    ]),
                YChangeRecord(
                    origin: .remote,
                    local: false,
                    events: [
                        YEventRecord(
                            target: [],
                            delta: [.retain(5, attributes: ["bold": "true"]), .retain(6, attributes: ["bold": .null])])
                    ]),
                // The oracle records `[]` here: its delta reads (which this PR
                // deliberately does not reproduce) deleted the redundant `2:0`
                // bold first, so the cleanup had nothing left to delete. A pure
                // read leaves `2:0` for the cleanup, which deletes `1:11` and
                // reports the attribute transition — the same delta yjs produces
                // when its remote deltas are not read first.
                YChangeRecord(
                    origin: nil,
                    local: true,
                    events: [
                        YEventRecord(target: [], delta: [.retain(5, attributes: ["bold": "true"])])
                    ]),
            ])
    }

    // MARK: - Local typing coalescing

    /// Three separate local inserts, then one transaction with three inserts. The
    /// deltas are the oracle's: each transaction reports only its own change, and
    /// the last one reports `retain 1, insert X, retain 2, insert de` even though
    /// the merge will coalesce the run.
    func testLocalTypingCoalescingMatchesYjs() throws {
        let doc = YDoc(clientID: 5, gc: false)
        defer { doc.destroy() }
        let text = doc.getText("t")
        let recorder = YChangeRecorder()
        recorder.attach(to: doc)

        try doc.transact { tx in
            try YWrite.insert(tx, into: text, at: 0, [.string(Array("a".utf16))])
        }
        try doc.transact { tx in
            try YWrite.insert(tx, into: text, at: 1, [.string(Array("b".utf16))])
        }
        try doc.transact { tx in
            try YWrite.insert(tx, into: text, at: 2, [.string(Array("c".utf16))])
        }
        try doc.transact(origin: .localUser) { tx in
            try YWrite.insert(tx, into: text, at: 3, [.string(Array("d".utf16))])
            try YWrite.insert(tx, into: text, at: 4, [.string(Array("e".utf16))])
            try YWrite.insert(tx, into: text, at: 1, [.string(Array("X".utf16))])
        }

        assertChangeRecords(
            recorder.records,
            [
                YChangeRecord(
                    origin: nil,
                    local: true,
                    events: [
                        YEventRecord(target: [], delta: [.insert("a")])
                    ]),
                YChangeRecord(
                    origin: nil,
                    local: true,
                    events: [
                        YEventRecord(target: [], delta: [.retain(1), .insert("b")])
                    ]),
                YChangeRecord(
                    origin: nil,
                    local: true,
                    events: [
                        YEventRecord(target: [], delta: [.retain(2), .insert("c")])
                    ]),
                YChangeRecord(
                    origin: .localUser,
                    local: true,
                    events: [
                        YEventRecord(target: [], delta: [.retain(1), .insert("X"), .retain(2), .insert("de")])
                    ]),
            ])
        XCTAssertEqual(visibleText(of: text), "aXbcde")
    }

    // MARK: - Remote typing before merge

    /// Four remote updates of consecutive typing by one client. The merge coalesces
    /// them into three structs, but each update's delta is computed in the observer
    /// phase — before the merge — so it still reads as its own insert. This is the
    /// test that fails if the hook moves after gc/merge.
    func testRemoteTypingDeltasAreComputedBeforeMerge() throws {
        let doc = YDoc(clientID: 9, gc: false)
        defer { doc.destroy() }
        doc.getText("t")
        let recorder = YChangeRecorder()
        recorder.attach(to: doc)

        let updates = [
            "0101050004010174016100",  // a
            "01010501840500016200",  // b
            "01010502840501016300",  // c
            "01020503840502026465c405000501015800",  // de, then X at 1
        ]
        for hex in updates {
            try doc.applyUpdate(try YUpdateDecoder.decode(Data(hex: hex)), origin: .remote)
        }

        assertChangeRecords(
            recorder.records,
            [
                YChangeRecord(
                    origin: .remote,
                    local: false,
                    events: [
                        YEventRecord(target: [], delta: [.insert("a")])
                    ]),
                YChangeRecord(
                    origin: .remote,
                    local: false,
                    events: [
                        YEventRecord(target: [], delta: [.retain(1), .insert("b")])
                    ]),
                YChangeRecord(
                    origin: .remote,
                    local: false,
                    events: [
                        YEventRecord(target: [], delta: [.retain(2), .insert("c")])
                    ]),
                YChangeRecord(
                    origin: .remote,
                    local: false,
                    events: [
                        YEventRecord(target: [], delta: [.retain(1), .insert("X"), .retain(2), .insert("de")])
                    ]),
            ])
        XCTAssertEqual(doc.store.clients[5]?.structs.count, 3, "the four updates merge into three structs")
        XCTAssertEqual(visibleText(of: doc.getText("t")), "aXbcde")
    }

    // MARK: - Re-entrancy

    /// A `transact` opened from inside `afterTransaction` is queued, never run
    /// mid-cleanup: its own `afterTransaction` fires only after the current
    /// transaction's gc/merge. yjs behaves the same way, and the consequence is
    /// visible in the nested delta — by the time the queued transaction's observer
    /// phase runs, the outer cleanup has already merged `a` and `b` into one item,
    /// so the nested event reports no change (`[]`), not `retain 1, insert b`.
    func testTransactionOpenedInsideHookIsQueuedNotRunMidCleanup() throws {
        let doc = YDoc(clientID: 5, gc: false)
        defer { doc.destroy() }
        let text = doc.getText("t")
        var records: [YChangeRecord] = []
        var outer: YTransaction?
        var nested: YTransaction?

        doc.afterTransaction = { transaction in
            records.append(YChangeRecord(transaction))
            guard records.count == 1 else { return }
            try? doc.transact { tx in
                nested = tx
                try? YWrite.insert(tx, into: text, at: 1, [.string(Array("b".utf16))])
            }
            XCTAssertEqual(
                records.count, 1, "the nested transaction's cleanup must not run mid-cleanup")
        }

        try doc.transact { tx in
            outer = tx
            try YWrite.insert(tx, into: text, at: 0, [.string(Array("a".utf16))])
        }

        XCTAssertEqual(records.count, 2)
        XCTAssertNotNil(outer)
        XCTAssertNotNil(nested)
        XCTAssertFalse(outer === nested, "the nested transaction is a distinct transaction")
        XCTAssertEqual(nested?.beforeState[5], 1)
        XCTAssertEqual(nested?.afterState[5], 2)
        assertEventsEqual(
            records[0].events, [YEventRecord(target: [], delta: [.insert("a")])], "outer")
        assertEventsEqual(records[1].events, [YEventRecord(target: [], delta: [])], "nested")
        XCTAssertEqual(visibleText(of: text), "ab")
        XCTAssertEqual(doc.store.clients[5]?.structs.count, 1, "the outer cleanup merged a and b")
    }
}
