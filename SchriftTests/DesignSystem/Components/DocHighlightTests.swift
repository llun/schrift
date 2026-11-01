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

    func testShortExcerptIsUnchanged() {
        XCTAssertEqual(
            searchExcerptWindow("Need hotel near Nimman", query: "hotel", locale: en), "Need hotel near Nimman")
    }

    func testVisibleMatchLeavesLongExcerptUnchanged() {
        XCTAssertEqual(searchExcerptWindow(longExcerpt, query: "notes", locale: en), longExcerpt)
    }

    func testNoMatchLeavesExcerptUnchanged() {
        XCTAssertEqual(searchExcerptWindow(longExcerpt, query: "zebra", locale: en), longExcerpt)
    }

    func testHiddenMatchStartsOnAWordNearItWithLeadingEllipsis() {
        let window = searchExcerptWindow(longExcerpt, query: "hotel", locale: en, visibleLimit: 40, leadingContext: 12)
        XCTAssertEqual(window, "…agreed the hotel near Nimman is the pick")
    }

    func testWindowHandlesCJKWithoutSpaces() {
        let excerpt = String(repeating: "あ", count: 60) + "東京" + "いう"
        let window = searchExcerptWindow(excerpt, query: "東京", locale: en, visibleLimit: 40, leadingContext: 5)
        XCTAssertEqual(window, "…" + String(repeating: "あ", count: 5) + "東京いう")
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
        let marked = attributed.runs.filter { $0.backgroundColor != nil }
        XCTAssertEqual(marked.count, 1)
        XCTAssertEqual(String(attributed[marked[0].range].characters), "Hotel")
        XCTAssertEqual(marked[0].backgroundColor, .yellow)
        XCTAssertNotNil(marked[0].font)
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

    func testAccessibilityLabelIsPlainText() {
        // The label is composed from plain strings only; the highlight is purely visual.
        let label = docRowAccessibilityLabel(
            title: "Hotel shortlist", excerpt: "need hotel near Nimman", reach: .restricted, date: "Sep",
            pinned: false, pinnedLabel: "Pinned", sharedWithOrganizationLabel: "Shared",
            publicLabel: "Public")
        XCTAssertEqual(label, "Hotel shortlist, Sep, need hotel near Nimman")
    }
}
