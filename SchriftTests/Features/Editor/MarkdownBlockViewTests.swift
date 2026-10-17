import SwiftUI
import UIKit
import XCTest

@testable import Schrift

final class MarkdownBlockViewTests: XCTestCase {

    private func assertLinkInk(
        _ color: Color?, message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let color else {
            XCTFail("Missing link ink. \(message)", file: file, line: line)
            return
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            XCTAssertEqual(
                UIColor(color).resolvedColor(with: traits), UIColor(DocsColor.textBrand).resolvedColor(with: traits),
                message, file: file, line: line)
        }
    }

    // MARK: - Bare-URL autolinking

    func testAutolinksBareURL() {
        let result = markdownInlineText("Visit https://example.com now")
        let links = result.runs.compactMap { $0.link }
        XCTAssertEqual(links, [URL(string: "https://example.com")!])
    }

    func testPreservesMarkdownLinkWithoutDoubleLinking() {
        let result = markdownInlineText("See [the site](https://example.com/x)")
        let links = result.runs.compactMap { $0.link }
        XCTAssertEqual(links, [URL(string: "https://example.com/x")!])
        // The raw markdown syntax is consumed, not shown.
        XCTAssertFalse(String(result.characters).contains("]("))
    }

    func testPlainTextHasNoLinks() {
        let result = markdownInlineText("just some words")
        XCTAssertTrue(result.runs.allSatisfy { $0.link == nil })
    }

    func testAutolinkExcludesTrailingComma() {
        let result = markdownInlineText("(https://api.example.com/v1/mcp, more)")
        XCTAssertEqual(result.runs.compactMap { $0.link }, [URL(string: "https://api.example.com/v1/mcp")!])
    }

    func testBareURLAndMarkdownLinkCoexist() {
        let result = markdownInlineText("[site](https://a.dev/x) and https://b.dev")
        XCTAssertEqual(
            result.runs.compactMap { $0.link },
            [URL(string: "https://a.dev/x")!, URL(string: "https://b.dev")!])
        XCTAssertFalse(String(result.characters).contains("]("))
    }

    // MARK: - Link styling (parity with the editing surface)

    /// The reading surface paints a link the way `InlineTextStyleResolver` paints
    /// one while editing — `textBrand`, single-underlined — instead of letting it
    /// fall through to SwiftUI's default link styling, which is the environment
    /// tint and carries no underline. Without it a document's links changed
    /// colour *and* gained an underline the instant the user tapped in.
    func testEveryLinkRunIsPaintedLikeTheEditingSurfacePaintsIt() {
        let result = markdownInlineText("See [the site](https://example.com/x) now")
        let linkRuns = result.runs.filter { $0.link != nil }

        XCTAssertEqual(linkRuns.count, 1)
        for run in linkRuns {
            assertLinkInk(run.foregroundColor)
            XCTAssertEqual(run.underlineStyle, .single)
        }
        // Negative control: the text either side is left alone, so the assertion
        // above is reading the link rule and not a blanket restyle.
        XCTAssertTrue(result.runs.filter { $0.link == nil }.allSatisfy { $0.underlineStyle == nil })
    }

    /// Several links in one block: the styling pass collects its ranges before it
    /// writes any, because setting an attribute splits and merges runs — walking
    /// `attributed.runs` while mutating would be rewriting the collection being
    /// iterated, and two links is all it takes to reach that.
    func testStylesEveryLinkWhenABlockHasSeveral() {
        let result = markdownInlineText(
            "[one](https://a.dev/) then [two](https://b.dev/) then bare https://c.dev and [three](https://d.dev/)")
        let linkRuns = result.runs.filter { $0.link != nil }

        XCTAssertEqual(linkRuns.count, 4, "expected three markdown links and one autolinked bare URL")
        for run in linkRuns {
            assertLinkInk(run.foregroundColor, message: "\(String(describing: run.link)) unstyled")
            XCTAssertEqual(run.underlineStyle, .single, "\(String(describing: run.link)) not underlined")
        }
    }

    // MARK: - Page chips (links to other documents on this server)

    private let host = "docs.example.org"
    private let page = "https://docs.example.org/docs/11111111-1111-4111-8111-111111111111/"

    private func isChip(_ run: AttributedString.Runs.Run) -> Bool {
        run.attributes[DocumentLinkChipAttribute.self] == true
    }

    /// A document link is a page chip — marked for the renderer, brand ink, and
    /// **no underline** — while an external link in the same block keeps the
    /// ordinary underlined link styling.
    func testADocumentLinkIsAChipAndAnExternalLinkStaysUnderlined() {
        let result = markdownInlineText(
            "See [Roadmap](\(page)) and [the site](https://example.com/x).", serverHost: host)
        let pageRuns = result.runs.filter { $0.link == URL(string: page)! }
        let externalRuns = result.runs.filter { $0.link == URL(string: "https://example.com/x")! }

        XCTAssertFalse(pageRuns.isEmpty)
        for run in pageRuns {
            XCTAssertTrue(isChip(run))
            XCTAssertNil(run.underlineStyle)
            assertLinkInk(run.foregroundColor)
        }
        XCTAssertFalse(externalRuns.isEmpty)
        for run in externalRuns {
            XCTAssertFalse(isChip(run))
            XCTAssertEqual(run.underlineStyle, .single)
        }
        // Display only: the visible characters are the titles, nothing added.
        XCTAssertEqual(String(result.characters), "See Roadmap and the site.")
    }

    /// The editing surface has no bare-URL autolinker, so only an explicit
    /// `[Title](url)` may become a chip — a chipped bare URL would add width the
    /// editing surface lacks and re-wrap the line on the swap.
    func testABareDocumentURLIsAnOrdinaryLinkNotAChip() {
        let result = markdownInlineText("Open \(page) now", serverHost: host)
        let linkRuns = result.runs.filter { $0.link != nil }
        XCTAssertEqual(linkRuns.count, 1)
        XCTAssertFalse(linkRuns.contains(where: isChip))
        XCTAssertEqual(linkRuns.first?.underlineStyle, .single)
    }

    /// With no server named nothing is a chip, so every existing caller keeps
    /// its exact behaviour.
    func testWithoutAServerHostADocumentLinkIsAnOrdinaryLink() {
        let result = markdownInlineText("[Roadmap](\(page))")
        XCTAssertFalse(result.runs.contains(where: isChip))
        XCTAssertEqual(result.runs.first { $0.link != nil }?.underlineStyle, .single)
    }

    func testLookalikeHostsAreNotChips() {
        let result = markdownInlineText(
            "[a](https://docs.example.org.evil.com/docs/11111111-1111-4111-8111-111111111111/) "
                + "[b](https://docs.example.org@evil.com/docs/11111111-1111-4111-8111-111111111111/)",
            serverHost: host)
        XCTAssertEqual(result.runs.filter { $0.link != nil }.count, 2)
        XCTAssertFalse(result.runs.contains(where: isChip))
    }

    /// The reading surface composes its `Text` from these segments: ordinary text
    /// as it is, and each document link's title — with its marks — as one chip.
    func testSegmentsSplitAtDocumentLinksAndKeepATitlesMarksTogether() {
        let result = markdownInlineText(
            "See [Road **map**](\(page)), then [site](https://example.com/).", serverHost: host)
        let segments = inlineTextSegments(result)

        XCTAssertEqual(segments.map(\.isDocumentLink), [false, true, false])
        let texts = segments.map { segment -> String in
            switch segment {
            case .text(let content), .documentLink(let content): return String(content.characters)
            }
        }
        XCTAssertEqual(texts, ["See ", "Road map", ", then site."])
        // Every character survives the split, in order.
        XCTAssertEqual(texts.joined(), String(result.characters))
        // The marker never reaches `Text`.
        for segment in segments {
            if case .documentLink(let content) = segment {
                XCTAssertFalse(content.runs.contains(where: isChip))
                XCTAssertTrue(content.runs.allSatisfy { $0.link == URL(string: page)! })
            }
        }
    }

    func testTwoDifferentDocumentLinksAreTwoChips() {
        let other = "https://docs.example.org/docs/33333333-3333-4333-8333-333333333333/"
        let result = markdownInlineText("[One](\(page))[Two](\(other))", serverHost: host)
        XCTAssertEqual(inlineTextSegments(result).map(\.isDocumentLink), [true, true])
    }

    func testABlockWithoutDocumentLinksIsOneOrdinarySegment() {
        let result = markdownInlineText("Plain **bold** and [site](https://example.com/)", serverHost: host)
        XCTAssertEqual(inlineTextSegments(result).map(\.isDocumentLink), [false])
    }

    func testPreservesLineBreaks() {
        // The `.inlineOnlyPreservingWhitespace` option keeps hard line breaks so
        // multi-line `.unknown` prose still renders across lines.
        XCTAssertTrue(String(markdownInlineText("Line one\nLine two").characters).contains("\n"))
    }

    // Standalone-image classification now lives in the parser
    // (`parseImageLine` → `.image` blocks); see MarkdownParserTests.
    // Off-origin image gating (which images auto-load vs tap-to-load) lives in
    // `imageLoadPolicy`; see ImageLoadPolicyTests.

    // MARK: - Unknown-block prose detection

    func testMultiLineProseIsProse() {
        XCTAssertTrue(unknownRendersAsProse("Line one\nLine two with https://x.dev link"))
    }

    func testTableIsNotProse() {
        XCTAssertFalse(unknownRendersAsProse("| a | b |\n| - | - |"))
    }

    func testStructuralMarkerOnLaterLineIsNotProse() {
        // Every line is scanned, not just the first: a prose opener followed by
        // a table row must still bail out to verbatim rendering.
        XCTAssertFalse(unknownRendersAsProse("Intro text\n| a | b |"))
    }

    func testHTMLIsNotProse() {
        XCTAssertFalse(unknownRendersAsProse("<div>hi</div>"))
    }

    func testIndentedContentIsNotProse() {
        XCTAssertFalse(unknownRendersAsProse("    indented code"))
    }

    func testStandaloneImageIsNotProse() {
        XCTAssertFalse(unknownRendersAsProse("![x](https://a.dev/b.png)"))
    }

    func testEmptyIsNotProse() {
        XCTAssertFalse(unknownRendersAsProse(""))
    }
}
