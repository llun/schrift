import UIKit
import XCTest

@testable import Schrift

/// The page chip is drawn by two frameworks, so what keeps them identical is
/// the shared geometry: the slot width both surfaces reserve, the icon band both
/// place the glyph in, and the rule both turn glyph rects into backgrounds by.
final class DocumentLinkChipTests: XCTestCase {

    // MARK: - Metrics

    /// Whole points, because the reading surface reserves the slot with an image
    /// (its pixel size) and the editing surface with a control glyph's box — a
    /// fraction would round differently and move a wrap point on one surface.
    func testTheSlotIsAWholePointWidthAtEveryTextSize() {
        for size in stride(from: CGFloat(11), through: 60, by: 0.5) {
            let metrics = DocumentLinkChipMetrics(fontSize: size)
            XCTAssertEqual(metrics.slotWidth, metrics.slotWidth.rounded(), "size \(size)")
            XCTAssertEqual(metrics.slotWidth, metrics.leadingPadding + metrics.iconSize + metrics.iconGap)
            XCTAssertGreaterThan(metrics.iconSize, 0)
        }
    }

    /// The chip scales with Dynamic Type: a larger block font gets a larger icon.
    func testTheIconGrowsWithTheText() {
        XCTAssertGreaterThan(
            DocumentLinkChipMetrics(fontSize: 34).iconSize, DocumentLinkChipMetrics(fontSize: 17).iconSize)
        XCTAssertGreaterThan(
            DocumentLinkChipMetrics(fontSize: 34).slotWidth, DocumentLinkChipMetrics(fontSize: 17).slotWidth)
    }

    /// The icon image sits strictly inside the font's ascender/descender, so it
    /// can never make a reading line taller than the editing line it swaps with.
    func testTheIconBandStaysInsideTheFontsLineBox() {
        for style in [UIFont.TextStyle.body, .title1, .headline, .caption1] {
            let font = UIFont.preferredFont(forTextStyle: style)
            let band = DocumentLinkChipIconBand(font: font)
            XCTAssertGreaterThanOrEqual(band.baselineOffset, font.descender, "\(style)")
            XCTAssertLessThanOrEqual(band.baselineOffset + band.height, font.ascender, "\(style)")
            XCTAssertEqual(band.height, band.height.rounded(), "\(style)")
        }
    }

    func testTheIconImageIsExactlyTheSlot() {
        let font = UIFont.preferredFont(forTextStyle: .body)
        let metrics = DocumentLinkChipMetrics(fontSize: font.pointSize)
        let band = DocumentLinkChipIconBand(font: font)
        let image = documentLinkChipIconImage(metrics: metrics, band: band)
        XCTAssertEqual(image.size, CGSize(width: metrics.slotWidth, height: band.height))
        XCTAssertEqual(image.renderingMode, .alwaysTemplate)
    }

    // MARK: - Backgrounds

    func testPiecesOfOneChipOnOneLineAreUnited() {
        let backgrounds = documentLinkChipBackgrounds(
            [
                DocumentLinkChipPiece(chip: 0, line: 0, rect: CGRect(x: 10, y: 0, width: 20, height: 20)),
                DocumentLinkChipPiece(chip: 0, line: 0, rect: CGRect(x: 30, y: 2, width: 15, height: 16)),
            ], trailingPadding: 3)
        XCTAssertEqual(backgrounds, [CGRect(x: 10, y: 0, width: 38, height: 20)])
    }

    /// Two chips on a line stay two backgrounds, and a chip that wraps gets one
    /// per line with only its last line padded — its first line ends mid-title.
    func testChipsStaySeparateAndOnlyAChipsLastLineIsPadded() {
        let backgrounds = documentLinkChipBackgrounds(
            [
                DocumentLinkChipPiece(chip: 0, line: 0, rect: CGRect(x: 0, y: 0, width: 10, height: 20)),
                DocumentLinkChipPiece(chip: 1, line: 0, rect: CGRect(x: 50, y: 0, width: 40, height: 20)),
                DocumentLinkChipPiece(chip: 1, line: 1, rect: CGRect(x: 0, y: 24, width: 30, height: 20)),
            ], trailingPadding: 3)
        XCTAssertEqual(
            backgrounds,
            [
                CGRect(x: 0, y: 0, width: 13, height: 20),
                CGRect(x: 50, y: 0, width: 40, height: 20),
                CGRect(x: 0, y: 24, width: 33, height: 20),
            ])
    }

    func testNoPiecesNoBackgrounds() {
        XCTAssertEqual(documentLinkChipBackgrounds([], trailingPadding: 3), [])
    }

    // MARK: - Which links the editing surface chips

    private let host = "docs.example.org"
    private let page = "https://docs.example.org/docs/11111111-1111-4111-8111-111111111111/"

    func testOnlyDocumentLinksBecomeChipsAndTheSlotIsTheHiddenBracket() {
        let source = "[Roadmap](\(page)) and [site](https://example.com/)"
        let spans = documentLinkChipSpans(in: InlineMarkdown.layout(of: source), serverHost: host)
        XCTAssertEqual(spans, [DocumentLinkChipSpan(slotIndex: 0, labelRange: NSRange(location: 1, length: 7))])
    }

    func testAnEmptyServerHostChipsNothing() {
        let source = "[Roadmap](\(page))"
        XCTAssertEqual(documentLinkChipSpans(in: InlineMarkdown.layout(of: source), serverHost: ""), [])
    }

    func testANestedMarkStillFindsTheBracketInsideItsHiddenRun() {
        // `**[` is one hidden run; the slot is still the `[` within it.
        let source = "**[Roadmap](\(page))**"
        let spans = documentLinkChipSpans(in: InlineMarkdown.layout(of: source), serverHost: host)
        XCTAssertEqual(spans.map(\.slotIndex), [2])
    }
}
