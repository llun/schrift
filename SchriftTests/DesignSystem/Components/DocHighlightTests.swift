import SwiftUI
import XCTest

@testable import Schrift

final class DocHighlightTests: XCTestCase {
    private let en = Locale(identifier: "en_US")

    private func matches(_ text: String, _ query: String) -> [String] {
        searchHighlightRanges(in: text, query: query, locale: en).map { String(text[$0]) }
    }

    // MARK: - Ranges

    func testMatchIsCaseInsensitiveAndKeepsOriginalCasing() {
        XCTAssertEqual(matches("Hotel shortlist near the hotel", "HOTEL"), ["Hotel", "hotel"])
    }

    func testMatchIsDiacriticInsensitiveBothWays() {
        XCTAssertEqual(matches("Café menu", "cafe"), ["Café"])
        XCTAssertEqual(matches("Cafe menu", "café"), ["Cafe"])
    }

    func testEachWhitespaceSeparatedTermIsMatched() {
        XCTAssertEqual(matches("Flights booked, need hotel near Nimman", "hotel  flights"), ["Flights", "hotel"])
    }

    func testOverlappingTermsMergeIntoOneRange() {
        XCTAssertEqual(matches("Hotel nights", "hot hotel"), ["Hotel"])
        XCTAssertEqual(matches("Hotel nights", "hote otel"), ["Hotel"])
    }

    func testTouchingMatchesMerge() {
        XCTAssertEqual(matches("foobar", "foo bar"), ["foobar"])
    }

    func testRepeatedTermsAreFoundOnce() {
        XCTAssertEqual(matches("a hotel, a Hotel", "hotel Hotel"), ["hotel", "Hotel"])
    }

    func testNoMatchGivesNoRanges() {
        XCTAssertTrue(matches("Trip to Chiang Mai", "budget").isEmpty)
    }

    func testQueryTermsAreDistinctTrimmedAndCapped() {
        XCTAssertEqual(searchQueryTerms("  Hotel  hotel\nNimman "), ["Hotel", "Nimman"])
        XCTAssertTrue(searchQueryTerms("   ").isEmpty)
        let many = (1...20).map { "term\($0)" }.joined(separator: " ")
        XCTAssertEqual(searchQueryTerms(many).count, searchHighlightMaxTerms)
    }

    func testTextContainsUsesTheHighlightRule() {
        XCTAssertTrue(searchTextContains("Café menu", term: "CAFE", locale: en))
        XCTAssertTrue(searchTextContains("Cafe menu", term: "café", locale: en))
        XCTAssertFalse(searchTextContains("Trip", term: "budget", locale: en))
        XCTAssertFalse(searchTextContains("", term: "trip", locale: en))
        XCTAssertFalse(searchTextContains("Trip", term: "", locale: en))
    }

    func testBlankQueryOrTextGivesNoRanges() {
        XCTAssertTrue(matches("Trip", "").isEmpty)
        XCTAssertTrue(matches("Trip", "   \n").isEmpty)
        XCTAssertTrue(matches("", "trip").isEmpty)
    }

    func testCJKTermsMatchAsSubstrings() {
        XCTAssertEqual(matches("我去东京旅行,东京很好", "东京"), ["东京", "东京"])
        XCTAssertEqual(matches("京都旅行", "旅行 京都"), ["京都旅行"])
    }

    func testRangesAreSortedAndNonOverlapping() {
        let text = "alpha beta alpha gamma beta"
        let ranges = searchHighlightRanges(in: text, query: "beta alpha", locale: en)
        XCTAssertEqual(ranges.count, 4)
        for (previous, next) in zip(ranges, ranges.dropFirst()) {
            XCTAssertLessThan(previous.upperBound, next.lowerBound)
        }
    }

    func testTermCountIsCapped() {
        let words = (0..<20).map { "t\($0)x" }
        let ranges = searchHighlightRanges(
            in: words.joined(separator: " "), query: words.joined(separator: " "), locale: en)
        XCTAssertEqual(ranges.count, searchHighlightMaxTerms)
    }

    // MARK: - Excerpt window

    private let longExcerpt =
        "Notes from the planning call with the whole team, where we agreed the hotel near Nimman is the pick"

    func testMatchWithinLeadingContextIsUnchanged() {
        XCTAssertEqual(
            searchExcerptWindow("Need hotel near Nimman", query: "hotel", locale: en), "Need hotel near Nimman")
        XCTAssertEqual(searchExcerptWindow(longExcerpt, query: "notes", locale: en), longExcerpt)
    }

    func testNoMatchLeavesExcerptUnchanged() {
        XCTAssertEqual(searchExcerptWindow(longExcerpt, query: "zebra", locale: en), longExcerpt)
    }

    func testHiddenMatchStartsOnAWordNearItWithLeadingEllipsis() {
        let window = searchExcerptWindow(longExcerpt, query: "hotel", locale: en, leadingContext: 12)
        XCTAssertEqual(window, "…agreed the hotel near Nimman is the pick")
    }

    func testShortExcerptWindowAtOneLineBudget() {
        let excerpt = "Notes from the call: hotel near Nimman is the pick"
        XCTAssertEqual(
            searchExcerptWindow(excerpt, query: "hotel", locale: en, leadingContext: docRowExcerptLeadingCharacters),
            "…the call: hotel near Nimman is the pick")
    }

    func testAccessibilitySizeTwoLineBudgetWindowsMatchBeyondOffset24() {
        // The match starts at offset 34, past the two-line budget of 24, so it is windowed.
        let excerpt = "Notes from the planning call: the hotel near Nimman is the pick"
        XCTAssertEqual(
            searchExcerptWindow(
                excerpt, query: "hotel", locale: en, leadingContext: docRowExcerptLeadingCharacters * 2),
            "…the planning call: the hotel near Nimman is the pick")
    }

    func testSingleLongWordBeforeMatchIsLeftUnchanged() {
        XCTAssertEqual(
            searchExcerptWindow("Supercalifragilistic hotel", query: "hotel", locale: en), "Supercalifragilistic hotel")
        XCTAssertEqual(
            searchExcerptWindow("abcdefghijklmnopqrstuvwxyz hotel", query: "hotel", locale: en),
            "abcdefghijklmnopqrstuvwxyz hotel")
    }

    func testLongWordNotAtStartKeepsMidWordCut() {
        XCTAssertEqual(
            searchExcerptWindow("xx Supercalifragilisticexpialidocious hotel", query: "hotel", locale: en),
            "…ialidocious hotel")
    }

    func testWindowHandlesCJKWithoutSpaces() {
        let excerpt = String(repeating: "あ", count: 60) + "東京" + "いう"
        let window = searchExcerptWindow(excerpt, query: "東京", locale: en, leadingContext: 5)
        XCTAssertEqual(window, "…" + String(repeating: "あ", count: 5) + "東京いう")
    }

    func testWideCJKMatchAroundCharacter25IsWindowed() {
        // 25 wide characters can already overflow one line, so the match must not stay put.
        let excerpt = String(repeating: "あ", count: 25) + "東京" + String(repeating: "い", count: 20)
        let window = searchExcerptWindow(excerpt, query: "東京", locale: en)
        XCTAssertEqual(window, "…" + String(repeating: "あ", count: 12) + "東京" + String(repeating: "い", count: 20))
    }

    func testWindowedExcerptStillHighlights() {
        let window = searchExcerptWindow(longExcerpt, query: "hotel", locale: en)
        XCTAssertEqual(matches(window, "hotel"), ["hotel"])
    }

    // MARK: - Attributed string

    func testAttributedStringMarksOnlyMatches() {
        let attributed = searchHighlightedString(
            "Hotel shortlist", query: "hotel", locale: en, font: .body, background: .yellow, foreground: .black)
        XCTAssertEqual(String(attributed.characters), "Hotel shortlist")
        let background = AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self
        let font = AttributeScopes.SwiftUIAttributes.FontAttribute.self
        let marked = attributed.runs.filter { $0[background] != nil }
        XCTAssertEqual(marked.count, 1)
        XCTAssertEqual(String(attributed[marked[0].range].characters), "Hotel")
        XCTAssertEqual(marked[0][background], .yellow)
        XCTAssertNotNil(marked[0][font])
    }

    func testAttributedStringWithoutMatchIsPlain() {
        let attributed = searchHighlightedString(
            "Trip", query: "hotel", locale: en, font: .body, background: .yellow, foreground: .black)
        XCTAssertEqual(attributed, AttributedString("Trip"))
    }

    // MARK: - DocRow

    @MainActor
    func testDocRowHighlightQueryDefaultsToNil() {
        XCTAssertNil(DocRow().highlightQuery)
    }

    func testPendingDeleteRowsAreNotHighlighted() {
        XCTAssertNil(docRowHighlightQuery("hotel", pendingDelete: true))
        XCTAssertEqual(docRowHighlightQuery(" hotel ", pendingDelete: false), "hotel")
        XCTAssertNil(docRowHighlightQuery("  ", pendingDelete: false))
        XCTAssertNil(docRowHighlightQuery(nil, pendingDelete: false))
    }

    func testAccessibilityLabelIsPlainText() {
        // The label is composed from plain strings only; the highlight is purely visual.
        let label = docRowAccessibilityLabel(
            title: "Hotel shortlist", excerpt: "need hotel near Nimman", reach: .restricted, date: "Sep",
            pinned: false, pinnedLabel: "Pinned", sharedWithOrganizationLabel: "Shared",
            publicLabel: "Public")
        XCTAssertEqual(label, "Hotel shortlist, Sep, need hotel near Nimman")
    }
}
