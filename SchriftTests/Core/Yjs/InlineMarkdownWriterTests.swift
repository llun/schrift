import XCTest

@testable import Schrift

/// `InlineMarkdownWriter` is the inverse of `InlineMarkdown`'s scanner:
/// `[InlineRun]` → markdown source. `InlineMarkdown.parse` is the oracle —
/// every round-trip assertion below calls the *real* scanner, never a
/// hand-rolled parse, so a regression in either half shows up here.
final class InlineMarkdownWriterTests: XCTestCase {

    // MARK: 1. Each single mark

    func testWritesEachSingleMark() throws {
        let cases: [(marks: [(key: String, valueJSON: String)], expected: String)] = [
            ([("bold", "{}")], "**x**"),
            ([("italic", "{}")], "_x_"),
            ([("strike", "{}")], "~~x~~"),
            ([("code", "{}")], "`x`"),
            ([("link", "{\"href\":\"https://a.example/\"}")], "[x](https://a.example/)"),
        ]
        for (marks, expected) in cases {
            let runs = [InlineRun("x", marks: marks)]
            let output = try XCTUnwrap(InlineMarkdownWriter.write(runs, escapeAll: false), "marks: \(marks)")
            XCTAssertEqual(output, expected)
            let parsed = InlineMarkdown.parse(output)
            XCTAssertTrue(
                InlineMarkdownWriter.runsEquivalent(parsed, InlineMarkdownWriter.normalized(runs)),
                "\(output) must round-trip for \(marks)"
            )
        }
    }

    // MARK: 2. Nested persistence

    /// A mark that persists into the next run must not be closed and
    /// reopened — `**bold _bi_**`, not `**bold** **_bi_**`.
    func testNestedPersistence() throws {
        let runs = [
            InlineRun("bold ", marks: [("bold", "{}")]),
            InlineRun("bi", marks: [("bold", "{}"), ("italic", "{}")]),
        ]
        let output = try XCTUnwrap(InlineMarkdownWriter.write(runs, escapeAll: false))
        XCTAssertEqual(output, "**bold _bi_**")
        XCTAssertTrue(
            InlineMarkdownWriter.runsEquivalent(InlineMarkdown.parse(output), InlineMarkdownWriter.normalized(runs)))
    }

    // MARK: 3. Link groups runs sharing an href into one link

    func testLinkGroupsRuns() throws {
        let href = "{\"href\":\"https://example.com/x\"}"
        let runs = [
            InlineRun("a", marks: [("link", href)]),
            InlineRun("b", marks: [("link", href), ("bold", "{}")]),
        ]
        let output = try XCTUnwrap(InlineMarkdownWriter.write(runs, escapeAll: false))
        XCTAssertEqual(output, "[a**b**](https://example.com/x)")
        XCTAssertTrue(
            InlineMarkdownWriter.runsEquivalent(InlineMarkdown.parse(output), InlineMarkdownWriter.normalized(runs)))
    }

    // MARK: 4. Whitespace expulsion

    func testWhitespaceExpulsion() throws {
        let runs = [InlineRun("word ", marks: [("bold", "{}")])]
        let output = try XCTUnwrap(InlineMarkdownWriter.write(runs, escapeAll: false))
        XCTAssertEqual(output, "**word** ")
        let parsed = InlineMarkdown.parse(output)
        XCTAssertTrue(InlineMarkdownWriter.runsEquivalent(InlineMarkdownWriter.normalized(runs), parsed))
    }

    // MARK: 5. escapeAll round-trips literal syntax

    func testEscapeAllRoundTripsLiteralSyntax() throws {
        let text = "*not* _lit_ [x](y) `t` ~~s~~ \\"
        let runs = [InlineRun(text)]
        let output = try XCTUnwrap(InlineMarkdownWriter.write(runs, escapeAll: true))
        let parsed = InlineMarkdown.parse(output)
        XCTAssertEqual(parsed, [InlineRun(text)])
    }

    // MARK: 6. Minimal keeps snake_case verbatim

    func testMinimalKeepsSnakeCaseVerbatim() throws {
        let runs = [InlineRun("snake_case a*b")]
        let output = try XCTUnwrap(InlineMarkdownWriter.write(runs, escapeAll: false))
        XCTAssertEqual(output, "snake_case a*b")
        XCTAssertTrue(
            InlineMarkdownWriter.runsEquivalent(InlineMarkdown.parse(output), InlineMarkdownWriter.normalized(runs)))
    }

    // MARK: 7. Structurally-impossible cases return nil

    func testCodeWithBacktickReturnsNil() {
        let runs = [InlineRun("a`b", marks: [("code", "{}")])]
        XCTAssertNil(InlineMarkdownWriter.write(runs, escapeAll: false))
        XCTAssertNil(InlineMarkdownWriter.write(runs, escapeAll: true))
    }

    func testEmptyCodeRunReturnsNil() {
        let runs = [InlineRun("", marks: [("code", "{}")])]
        XCTAssertNil(InlineMarkdownWriter.write(runs, escapeAll: false))
        XCTAssertNil(InlineMarkdownWriter.write(runs, escapeAll: true))
    }

    func testLinkWithParenHrefReturnsNil() {
        let runs = [InlineRun("x", marks: [("link", "{\"href\":\"https://example.com/a)b\"}")])]
        XCTAssertNil(InlineMarkdownWriter.write(runs, escapeAll: false))
        XCTAssertNil(InlineMarkdownWriter.write(runs, escapeAll: true))
    }

    func testLinkWithWhitespaceOrBackslashHrefReturnsNil() throws {
        for href in ["https://example.com/a b", "https://example.com/a\\b"] {
            // Build the mark value via JSONSerialization (not string
            // interpolation) so a raw backslash in `href` round-trips as one
            // JSON-escaped backslash rather than an unrelated JSON escape
            // sequence (e.g. "\b" is JSON's backspace control character, not
            // a literal backslash+b) — the same rule `linkValueJSON` follows.
            let data = try JSONSerialization.data(withJSONObject: ["href": href])
            let valueJSON = try XCTUnwrap(String(data: data, encoding: .utf8))
            let runs = [InlineRun("x", marks: [("link", valueJSON)])]
            XCTAssertNil(InlineMarkdownWriter.write(runs, escapeAll: false), href)
            XCTAssertNil(InlineMarkdownWriter.write(runs, escapeAll: true), href)
        }
    }

    // MARK: 8. Seeded fuzz round trip

    /// Deterministic LCG per the task brief — same constants, same seed —
    /// so a failure is reproducible from the printed inputs alone.
    private struct SeededLCG {
        var state: UInt64 = 0x5EED
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
    }

    func testSeededFuzzRoundTrip() {
        var lcg = SeededLCG()
        let alphabet: [Character] = ["a", "b", " ", "*", "_", "`", "[", "]", "(", ")", "\\", "~", "é", "😀"]
        let markKeys = ["bold", "italic", "code", "strike", "link"]
        let linkValueJSON = "{\"href\":\"https://x.example/p\"}"

        var nonNilCount = 0
        for iteration in 0..<400 {
            let runCount = Int(lcg.next() % 5) + 1
            var runs: [InlineRun] = []
            for _ in 0..<runCount {
                let length = Int(lcg.next() % 7)
                var text = ""
                for _ in 0..<length {
                    let index = Int(lcg.next() % UInt64(alphabet.count))
                    text.append(alphabet[index])
                }
                var marks: [(key: String, valueJSON: String)] = []
                for key in markKeys {
                    guard lcg.next() % 2 == 0 else { continue }
                    marks.append((key: key, valueJSON: key == "link" ? linkValueJSON : "{}"))
                }
                runs.append(InlineRun(text, marks: marks))
            }

            guard let output = InlineMarkdownWriter.write(runs, escapeAll: true) else { continue }
            nonNilCount += 1

            let parsed = InlineMarkdown.parse(output)
            let expected = InlineMarkdownWriter.normalized(runs)
            XCTAssertTrue(
                InlineMarkdownWriter.runsEquivalent(parsed, expected),
                "iteration \(iteration): runs=\(runs) output=\(output.debugDescription)"
            )
        }

        XCTAssertGreaterThanOrEqual(
            nonNilCount, 200, "fuzz degenerated: only \(nonNilCount)/400 iterations were non-nil")
    }

    // MARK: - isEscapable sync lock
    //
    // `InlineMarkdown.swift`'s `isEscapable(_:)` is private, so the writer
    // transcribes its exact character list rather than sharing it. This test
    // is the tripwire: it asserts every character the writer thinks is
    // escapable actually round-trips through the real scanner when
    // backslash-escaped. If the scanner's set ever changes, this fails.

    func testEscapableCharactersMirrorTheScanner() {
        for character in InlineMarkdownWriter.escapableCharacters.sorted() {
            let escaped = "\\" + String(character)
            let runs = InlineMarkdown.parse(escaped)
            XCTAssertEqual(runs, [InlineRun(String(character))], "escaped \(character) must parse back as literal")
        }
    }

    // MARK: - Italic flanking sync lock
    //
    // `InlineMarkdown.swift`'s flanking predicates (isLeftFlanking /
    // isRightFlanking / isLoneUnderscore / canOpenUnderscore /
    // canCloseUnderscore) are private free functions, so the writer
    // transcribes them rather than sharing them (see the "Italic flanking"
    // section of InlineMarkdownWriter.swift). Each case here is a string
    // with a known open/close underscore position and a known outcome
    // (italicizes or stays literal) — several lifted directly from
    // InlineMarkdownTests's own flanking coverage — checked two ways: the
    // *real* scanner's actual parse result, and the writer's transcribed
    // predicates evaluated at the same positions. A divergence here means
    // the transcription has drifted from the scanner.

    func testItalicFlankingMirrorsTheScanner() {
        struct Case {
            let text: String
            let openIndex: Int
            let closeIndex: Int
            let italicizes: Bool
            let line: UInt
        }
        let cases: [Case] = [
            // "a _it_ b" -> italic "it" (InlineMarkdownTests.testLoneUnderscoresAreEmphasis).
            Case(text: "a _it_ b", openIndex: 2, closeIndex: 5, italicizes: true, line: #line),
            // "_ word _" -> opener followed by whitespace never flanks left.
            Case(text: "_ word _", openIndex: 0, closeIndex: 7, italicizes: false, line: #line),
            // "(_x_)" -> punctuation on both sides still flanks (CommonMark).
            Case(text: "(_x_)", openIndex: 1, closeIndex: 3, italicizes: true, line: #line),
            // emoji is not "markdown punctuation" (Character.isPunctuation,
            // not isSymbol), so it does not enable flanking either side.
            Case(text: "\u{1F600}_x_\u{1F600}", openIndex: 1, closeIndex: 3, italicizes: false, line: #line),
            // "+_+x+_+" -> each delimiter has ASCII punctuation as *both*
            // its outer neighbor and its inner (content-adjacent) neighbor,
            // so isLeftFlanking and isRightFlanking are simultaneously true
            // at both the open and the close position — unlike every case
            // above, which resolves via the single-sided short-circuit
            // (`guard isRightFlanking else { return true }` /
            // `guard isLeftFlanking else { return true }`) before ever
            // reaching the punctuation-neighbor tiebreak. This one lands on
            // that tiebreak (InlineMarkdown.swift:505/512, mirrored at
            // `canOpenUnderscore`/`canCloseUnderscore` above): both `+`s are
            // punctuation, so the tiebreak resolves to `true` at both ends,
            // and the real scanner does italicize "+x+" (confirmed against
            // `InlineMarkdown.parse` directly, not just asserted here).
            Case(text: "+_+x+_+", openIndex: 1, closeIndex: 5, italicizes: true, line: #line),
        ]

        for testCase in cases {
            let chars = Array(testCase.text)
            let parsedItalicizes = InlineMarkdown.parse(testCase.text).contains {
                $0.marks.contains { $0.key == "italic" }
            }
            XCTAssertEqual(parsedItalicizes, testCase.italicizes, testCase.text, line: testCase.line)

            let predictedOpens =
                InlineMarkdownWriter.isLoneUnderscore(chars, at: testCase.openIndex)
                && InlineMarkdownWriter.canOpenUnderscore(chars, at: testCase.openIndex)
            let predictedCloses =
                InlineMarkdownWriter.isLoneUnderscore(chars, at: testCase.closeIndex)
                && InlineMarkdownWriter.canCloseUnderscore(chars, at: testCase.closeIndex)
            XCTAssertEqual(
                predictedOpens && predictedCloses, testCase.italicizes,
                "\(testCase.text): writer's flanking prediction disagreed with the scanner", line: testCase.line)
        }
    }
}
