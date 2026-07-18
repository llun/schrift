import XCTest

@testable import Schrift

final class TextSpanDiffTests: XCTestCase {
    func testNoChangeReturnsNil() {
        XCTAssertNil(TextSpanDiff.diff(old: [InlineRun("abc")], new: [InlineRun("abc")]))
    }

    func testInsertPlainCharMidParagraph() {
        // "hello world" -> "hello Xworld": delete nothing at 6, insert "X".
        let d = TextSpanDiff.diff(old: [InlineRun("hello world")], new: [InlineRun("hello Xworld")])
        XCTAssertEqual(d?.deleteRange, 6..<6)
        XCTAssertEqual(d?.insertPieces, [.string("X")])
    }

    func testDeletePlainChar() {
        let d = TextSpanDiff.diff(old: [InlineRun("abc")], new: [InlineRun("ac")])
        XCTAssertEqual(d?.deleteRange, 1..<2)
        XCTAssertEqual(d?.insertPieces, [])
    }

    func testInsertInsideBoldRegionInheritsBold() {
        // "wo|rld" all bold, insert "X" at 2 -> the inserted span is bold too, and
        // because the kept prefix already has bold open, no format piece is needed.
        let old = [InlineRun("world", marks: [("bold", "{}")])]
        let new = [InlineRun("woXrld", marks: [("bold", "{}")])]
        let d = TextSpanDiff.diff(old: old, new: new)
        XCTAssertEqual(d?.deleteRange, 2..<2)
        XCTAssertEqual(d?.insertPieces, [.string("X")])
    }

    func testBoldingAWordWithNoTextChangeIsAFormatOnlyEdit() {
        // "cat" -> "cat" but now bold: text identical, marks differ ⇒ whole word is
        // the changed (char,marks) span; rebuilt as bold and re-closed at the end.
        let d = TextSpanDiff.diff(
            old: [InlineRun("cat")],
            new: [InlineRun("cat", marks: [("bold", "{}")])])
        XCTAssertEqual(d?.deleteRange, 0..<3)
        XCTAssertEqual(
            d?.insertPieces,
            [
                .format(key: "bold", valueJSON: "{}"), .string("cat"),
                .format(key: "bold", valueJSON: "null"),
            ])
    }

    func testEmojiInsertUsesUTF16Indices() {
        // "a😀b" (😀 is 2 UTF-16 units) -> "a😀Xb": insert at index 3.
        let d = TextSpanDiff.diff(old: [InlineRun("a😀b")], new: [InlineRun("a😀Xb")])
        XCTAssertEqual(d?.deleteRange, 3..<3)
        XCTAssertEqual(d?.insertPieces, [.string("X")])
    }

    func testInsertBeforeDifferentlyFormattedSuffixClosesMark() {
        // "abcd" (ab bold, cd plain) -> "abXcd" (ab bold, X bold, cd plain):
        // insert bold X before the plain kept suffix; the trailing close is REQUIRED.
        let old = [InlineRun("ab", marks: [("bold", "{}")]), InlineRun("cd")]
        let new = [
            InlineRun("ab", marks: [("bold", "{}")]), InlineRun("X", marks: [("bold", "{}")]), InlineRun("cd"),
        ]
        let d = TextSpanDiff.diff(old: old, new: new)
        XCTAssertEqual(d?.deleteRange, 2..<2)
        XCTAssertEqual(d?.insertPieces, [.string("X"), .format(key: "bold", valueJSON: "null")])
    }

    func testPureDeleteAcrossMarkBoundaryRestoresMark() {
        // "ab" (a plain, b bold) -> "b" (bold): a pure delete whose span is empty but
        // must still emit the format transition so "b" stays bold.
        let old = [InlineRun("a"), InlineRun("b", marks: [("bold", "{}")])]
        let new = [InlineRun("b", marks: [("bold", "{}")])]
        let d = TextSpanDiff.diff(old: old, new: new)
        XCTAssertEqual(d?.deleteRange, 0..<1)
        XCTAssertEqual(d?.insertPieces, [.format(key: "bold", valueJSON: "{}")])
    }

    // MARK: - Property test

    /// A deterministic PRNG (xorshift64*) so the property test below is fully
    /// reproducible — never `Date`/`SystemRandomNumberGenerator`. A given seed
    /// always produces the same `old`/`new` pair, so a failure is reproducible
    /// from the printed seed alone.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
        mutating func next() -> UInt64 {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return state &* 2_685_821_657_736_338_717
        }
    }

    /// A small alphabet mixing plain ASCII with a 2-UTF-16-unit emoji, and a
    /// handful of mark sets (booleans plus two distinct link hrefs, so the
    /// "same key, different valueJSON" transition gets exercised) — enough to
    /// stress multi-run, multi-mark, surrogate-pair inputs without an
    /// unbounded state space.
    private static let alphabet = ["a", "b", "c", " ", "😀", "x"]
    private static let markSets: [[(key: String, valueJSON: String)]] = [
        [],
        [("bold", "{}")],
        [("italic", "{}")],
        [("bold", "{}"), ("italic", "{}")],
        [("link", "{\"href\":\"a\"}")],
        [("link", "{\"href\":\"b\"}")],
    ]

    private func randomRuns(_ rng: inout SeededGenerator) -> [InlineRun] {
        let runCount = Int.random(in: 1...3, using: &rng)
        var runs: [InlineRun] = []
        for _ in 0..<runCount {
            let length = Int.random(in: 0...5, using: &rng)
            var text = ""
            for _ in 0..<length { text += Self.alphabet.randomElement(using: &rng)! }
            runs.append(InlineRun(text, marks: Self.markSets.randomElement(using: &rng)!))
        }
        return runs
    }

    /// Pure reference applier: delete `deleteRange` from `old`, then splice in
    /// the units `insertPieces` describes (each `.string` run tagged with
    /// whatever marks are currently open per the preceding `.format` pieces).
    /// Mirrors what the eventual `YWrite.delete` + `YWrite.insert` store call
    /// should produce, without touching the store. Pieces are self-describing
    /// only relative to what the *document* already has open at the insertion
    /// point — `testInsertInsideBoldRegionInheritsBold` pins exactly this: no
    /// format piece at all when the inserted text matches the kept prefix's
    /// still-open mark — so `open` must seed from the kept prefix's trailing
    /// marks (the last surviving unit's marks just before the insertion point,
    /// or none at the start of the document), not from empty.
    private func apply(
        _ diff: (deleteRange: Range<Int>, insertPieces: [InlinePiece]), to old: MarkedText
    ) -> MarkedText {
        var units = old.units
        var marks = old.marks
        units.removeSubrange(diff.deleteRange)
        marks.removeSubrange(diff.deleteRange)

        var insertedUnits: [UInt16] = []
        var insertedMarks: [[String: String]] = []
        var open: [String: String] = diff.deleteRange.lowerBound > 0 ? old.marks[diff.deleteRange.lowerBound - 1] : [:]
        for piece in diff.insertPieces {
            switch piece {
            case .format(let key, let valueJSON):
                if valueJSON == "null" {
                    open[key] = nil
                } else {
                    open[key] = valueJSON
                }
            case .string(let text):
                for u in Array(text.utf16) {
                    insertedUnits.append(u)
                    insertedMarks.append(open)
                }
            }
        }
        // After every piece is processed, `open` must equal what the kept suffix
        // expects: `old.marks[deleteRange.upperBound]` (the boundary is the common
        // suffix, so `old.marks[deleteRange.upperBound] == new.marks` there), or — at
        // the end of the text — no marks at all. Without this, a dropped or wrong
        // TRAILING `.format` piece (the transition `buildSpanPieces` emits after its
        // last `.string`, with no following `.string` to reveal it) is invisible to
        // this applier: the kept suffix is spliced in verbatim regardless of `open`'s
        // final state.
        let expectedSuffixMarks =
            diff.deleteRange.upperBound < old.units.count ? old.marks[diff.deleteRange.upperBound] : [:]
        XCTAssertEqual(
            open, expectedSuffixMarks,
            "final open marks after all insertPieces must match the kept suffix's marks")
        units.insert(contentsOf: insertedUnits, at: diff.deleteRange.lowerBound)
        marks.insert(contentsOf: insertedMarks, at: diff.deleteRange.lowerBound)
        return MarkedText(units: units, marks: marks)
    }

    /// Over many randomized (old, new) run-list pairs, `diff`'s output —
    /// applied to `old` by the pure reference applier above — must reproduce
    /// `new`'s `MarkedText` exactly. This pins the algorithm's correctness at
    /// the document level before it drives the live store (Task 8).
    func testDiffAppliedToOldReproducesNewAcrossRandomizedRuns() {
        for seed: UInt64 in 1...500 {
            var rng = SeededGenerator(seed: seed)
            let old = randomRuns(&rng)
            let new = randomRuns(&rng)
            let oldMarked = TextSpanDiff.marked(old)
            let newMarked = TextSpanDiff.marked(new)

            guard let d = TextSpanDiff.diff(old: old, new: new) else {
                XCTAssertEqual(oldMarked, newMarked, "diff returned nil but old != new (seed \(seed))")
                continue
            }
            let applied = apply(d, to: oldMarked)
            XCTAssertEqual(applied, newMarked, "seed \(seed): diff did not reproduce `new`")
        }
    }
}
