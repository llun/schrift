import XCTest

@testable import Schrift

/// Unit tests for the live store's mutable content model (`YContent.swift`) — the
/// per-kind `length`/`isCountable`/`ref` table and the two operations the store
/// performs on content, `splice` and `mergeWith`.
///
/// The table is not incidental: `isCountable` decides an item's countable info bit
/// at construction, which decides whether it contributes to its parent's `_length`;
/// `ref` stands in for yjs's `content.constructor ===` identity test in
/// `YItem.mergeWith`.
final class YContentTests: XCTestCase {

    // MARK: - The per-kind table

    func testOnlyDeletedAndFormatAreNotCountable() {
        // yjs: ContentDeleted @8644 and ContentFormat @8970 return false; every other
        // content kind returns true. Getting this wrong silently corrupts parent
        // lengths rather than failing loudly.
        XCTAssertFalse(YContent.deleted(len: 3).isCountable)
        XCTAssertFalse(YContent.format(key: "bold", valueJSON: "true").isCountable)

        XCTAssertTrue(YContent.json(["1"]).isCountable)
        XCTAssertTrue(YContent.binary(Data([1, 2])).isCountable)
        XCTAssertTrue(YContent.string(Array("hi".utf16)).isCountable)
        XCTAssertTrue(YContent.embed(json: "{}").isCountable)
        XCTAssertTrue(YContent.type(YType()).isCountable)
        XCTAssertTrue(YContent.any([.null]).isCountable)
        XCTAssertTrue(YContent.doc(guid: "g", options: .null).isCountable)
    }

    func testContentRefsMatchTheYjsTable() {
        // contentRefs @10230: 1 deleted, 2 json, 3 binary, 4 string, 5 embed,
        // 6 format, 7 type, 8 any, 9 doc.
        XCTAssertEqual(YContent.deleted(len: 1).ref, 1)
        XCTAssertEqual(YContent.json(["1"]).ref, 2)
        XCTAssertEqual(YContent.binary(Data()).ref, 3)
        XCTAssertEqual(YContent.string([]).ref, 4)
        XCTAssertEqual(YContent.embed(json: "{}").ref, 5)
        XCTAssertEqual(YContent.format(key: "b", valueJSON: "true").ref, 6)
        XCTAssertEqual(YContent.type(YType()).ref, 7)
        XCTAssertEqual(YContent.any([]).ref, 8)
        XCTAssertEqual(YContent.doc(guid: "g", options: .null).ref, 9)
    }

    func testStringLengthCountsUTF16CodeUnitsNotCharacters() {
        // A Yjs clock advances by JS `String.length`, i.e. UTF-16 code units — an
        // astral character is two, not one.
        XCTAssertEqual(YContent.string(Array("😀".utf16)).length, 2)
        XCTAssertEqual(YContent.string(Array("héllo".utf16)).length, 5)
        XCTAssertEqual(YContent.deleted(len: 7).length, 7)
        XCTAssertEqual(YContent.any([.null, .bool(true)]).length, 2)
        // Single-unit kinds, whatever they hold.
        XCTAssertEqual(YContent.binary(Data([1, 2, 3, 4])).length, 1)
        XCTAssertEqual(YContent.embed(json: #"{"a":1}"#).length, 1)
    }

    // MARK: - splice

    func testSpliceStringSplitsOnUTF16Offsets() throws {
        var content = YContent.string(Array("hello".utf16))
        let right = try content.splice(2)
        XCTAssertEqual(content, .string(Array("he".utf16)))
        XCTAssertEqual(right, .string(Array("llo".utf16)))
    }

    func testSpliceBetweenSurrogatePairsReplacesBothHalvesWithReplacementChar() {
        // yjs ContentString.splice @9335 / yjs#248: splitting a surrogate pair would
        // leave a lone surrogate on each side — an unencodable string — so yjs
        // replaces each orphan with U+FFFD. This is the one case a Swift `String`
        // could not represent mid-operation, which is why the live model stores
        // UTF-16 code units.
        let units = Array("😀".utf16)  // [0xD83D, 0xDE00]
        XCTAssertEqual(units.count, 2)

        let (left, right) = YContent.spliceString(units, at: 1)
        XCTAssertEqual(left, [0xFFFD])
        XCTAssertEqual(right, [0xFFFD])
    }

    func testSpliceOnASurrogateBoundaryKeepsThePairIntact() {
        // Splitting *between* two pairs is a clean cut — no repair.
        let units = Array("😀👍".utf16)
        let (left, right) = YContent.spliceString(units, at: 2)
        XCTAssertEqual(left, Array("😀".utf16))
        XCTAssertEqual(right, Array("👍".utf16))
    }

    func testSpliceRepairPreservesLengthOnBothSides() {
        // The store depends on this: an item's clock range must not move when it
        // splits, so a repair must swap one orphan for exactly one U+FFFD.
        let units = Array("a😀b".utf16)  // 4 units
        for offset in 0...units.count {
            let (left, right) = YContent.spliceString(units, at: offset)
            XCTAssertEqual(left.count, offset, "left length changed at offset \(offset)")
            XCTAssertEqual(
                right.count, units.count - offset, "right length changed at offset \(offset)")
        }
    }

    func testSpliceAtZeroNeverRepairs() throws {
        // yjs reads `charCodeAt(offset - 1)`, which is NaN at offset 0 and fails every
        // surrogate comparison — so no repair, and an empty left half.
        var content = YContent.string(Array("😀".utf16))
        let right = try content.splice(0)
        XCTAssertEqual(content, .string([]))
        XCTAssertEqual(right, .string(Array("😀".utf16)))
    }

    func testSpliceDeletedAndListContents() throws {
        var deleted = YContent.deleted(len: 5)
        XCTAssertEqual(try deleted.splice(2), .deleted(len: 3))
        XCTAssertEqual(deleted, .deleted(len: 2))

        var any = YContent.any([.int(1), .int(2), .int(3)])
        XCTAssertEqual(try any.splice(1), .any([.int(2), .int(3)]))
        XCTAssertEqual(any, .any([.int(1)]))

        var json = YContent.json(["1", "2", "3"])
        XCTAssertEqual(try json.splice(2), .json(["3"]))
        XCTAssertEqual(json, .json(["1", "2"]))
    }

    func testSplicingUnsplittableContentThrowsMethodUnimplemented() {
        // yjs throws `methodUnimplemented()` for every single-unit content kind.
        // Reaching this means an update claimed a split inside content that has no
        // interior — malformed input, not a bug to paper over.
        for var content: YContent in [
            .binary(Data([1])), .embed(json: "{}"), .format(key: "b", valueJSON: "true"),
            .type(YType()), .doc(guid: "g", options: .null),
        ] {
            do {
                _ = try content.splice(1)
                XCTFail("expected splice to throw for content ref \(content.ref)")
            } catch let error as YIntegrationError {
                XCTAssertEqual(error, .methodUnimplemented)
            } catch {
                XCTFail("unexpected error \(error) for content ref \(content.ref)")
            }
        }
    }

    func testSpliceRejectsAnOutOfRangeOffset() {
        // A malformed update can claim any offset; JS would quietly produce empty
        // slices where Swift would trap, so this is `unexpectedCase`.
        var content = YContent.string(Array("hi".utf16))
        XCTAssertThrowsErrorOfType(YIntegrationError.unexpectedCase) { _ = try content.splice(99) }

        var deleted = YContent.deleted(len: 2)
        XCTAssertThrowsErrorOfType(YIntegrationError.unexpectedCase) { _ = try deleted.splice(99) }
    }

    // MARK: - mergeWith

    func testMergeConcatenatesTheFourSplittableKinds() {
        var string = YContent.string(Array("he".utf16))
        XCTAssertTrue(string.mergeWith(.string(Array("llo".utf16))))
        XCTAssertEqual(string, .string(Array("hello".utf16)))

        var deleted = YContent.deleted(len: 2)
        XCTAssertTrue(deleted.mergeWith(.deleted(len: 3)))
        XCTAssertEqual(deleted, .deleted(len: 5))

        var any = YContent.any([.int(1)])
        XCTAssertTrue(any.mergeWith(.any([.int(2)])))
        XCTAssertEqual(any, .any([.int(1), .int(2)]))

        var json = YContent.json(["1"])
        XCTAssertTrue(json.mergeWith(.json(["2"])))
        XCTAssertEqual(json, .json(["1", "2"]))
    }

    func testSingleUnitContentNeverMerges() {
        // yjs: ContentBinary/Embed/Format/Type/Doc all `return false`.
        var binary = YContent.binary(Data([1]))
        XCTAssertFalse(binary.mergeWith(.binary(Data([2]))))
        XCTAssertEqual(binary, .binary(Data([1])), "a refused merge must not mutate")

        var embed = YContent.embed(json: "{}")
        XCTAssertFalse(embed.mergeWith(.embed(json: "{}")))

        var format = YContent.format(key: "b", valueJSON: "true")
        XCTAssertFalse(format.mergeWith(.format(key: "b", valueJSON: "true")))
    }

    func testMismatchedKindsNeverMerge() {
        var string = YContent.string(Array("a".utf16))
        XCTAssertFalse(string.mergeWith(.any([.int(1)])))
        XCTAssertEqual(string, .string(Array("a".utf16)), "a refused merge must not mutate")
    }
}

// MARK: - Helpers

extension YContent: @retroactive Equatable {
    /// Structural equality for tests only. `YContent` is deliberately not `Equatable`
    /// in the app: `.type` wraps a reference whose identity — not its contents — is
    /// what the store compares.
    public static func == (lhs: YContent, rhs: YContent) -> Bool {
        switch (lhs, rhs) {
        case (.deleted(let a), .deleted(let b)): return a == b
        case (.json(let a), .json(let b)): return a == b
        case (.binary(let a), .binary(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.embed(let a), .embed(let b)): return a == b
        case (.format(let ak, let av), .format(let bk, let bv)): return ak == bk && av == bv
        case (.type(let a), .type(let b)): return a === b
        case (.any(let a), .any(let b)): return a == b
        case (.doc(let ag, let ao), .doc(let bg, let bo)): return ag == bg && ao == bo
        default: return false
        }
    }
}

extension XCTestCase {
    /// Typed `do`/`catch` assertion in the repo's style (never `XCTAssertThrowsError`),
    /// wrapped because these cases repeat across the store's tests.
    func XCTAssertThrowsErrorOfType(
        _ expected: YIntegrationError, file: StaticString = #filePath, line: UInt = #line,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            XCTFail("expected \(expected) to be thrown", file: file, line: line)
        } catch let error as YIntegrationError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }
}
