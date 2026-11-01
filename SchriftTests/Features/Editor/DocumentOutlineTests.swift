import XCTest

@testable import Schrift

/// The pure rules behind the "In this document" sheet: what an outline lists, what find matches,
/// which section a match counts toward, and how previous/next wrap.
final class DocumentOutlineTests: XCTestCase {
    private func heading(_ level: Int, _ text: String) -> EditorBlock {
        EditorBlock(kind: .heading(level: level), text: text)
    }

    private func paragraph(_ text: String) -> EditorBlock {
        EditorBlock(kind: .paragraph, text: text)
    }

    // MARK: - Plain text

    func testPlainTextStripsInlineMarkdownAndLinkTargets() {
        let block = paragraph("A **bold** move, see [the *plan*](https://example.org/x) and `code`.")

        XCTAssertEqual(outlinePlainText(of: block), "A bold move, see the plan and code.")
    }

    func testPlainTextUnescapesBackslashEscapes() {
        XCTAssertEqual(outlinePlainText(of: paragraph("2 \\* 3")), "2 * 3")
    }

    func testCodeAndUnknownBlocksAreTakenVerbatim() {
        let code = EditorBlock(kind: .codeBlock(language: "swift"), text: "let **x** = 1")
        let unknown = EditorBlock(kind: .unknown, text: "| a | **b** |")

        XCTAssertEqual(outlinePlainText(of: code), "let **x** = 1")
        XCTAssertEqual(outlinePlainText(of: unknown), "| a | **b** |")
    }

    func testAttachmentShowsItsNameAndPhotoAndDividerShowNothing() {
        let attachment = EditorBlock(
            kind: .attachment(name: "Budget.pdf", url: "https://docs.example.org/media/1/budget.pdf"))
        let image = EditorBlock(kind: .image(alt: "chart", url: "https://docs.example.org/media/1/chart.png"))
        let divider = EditorBlock(kind: .divider)

        XCTAssertEqual(outlinePlainText(of: attachment), "Budget.pdf")
        XCTAssertEqual(outlinePlainText(of: image), "")
        XCTAssertEqual(outlinePlainText(of: divider), "")
    }

    // MARK: - Find

    func testFindReturnsMatchingBlocksInDocumentOrder() {
        let a = paragraph("The budget is tight")
        let b = paragraph("Nothing here")
        let c = heading(2, "Budget")
        let d = EditorBlock(kind: .bulletItem, text: "Trim the BUDGET")

        XCTAssertEqual(findMatchingBlockIDs(in: [a, b, c, d], query: "budget"), [a.id, c.id, d.id])
    }

    func testFindOverReadingRowsSkipsBlocksHiddenByHideCompleted() {
        let blocks = parseEditorBlocks("- [x] Budget done\n  - [ ] Budget child\n- [ ] Budget open")
        let visible = ChecklistReadingPresentation(blocks: blocks, hidingCompleted: true).rows.map(\.block)

        XCTAssertEqual(findMatchingBlockIDs(in: blocks, query: "budget").count, 3)
        XCTAssertEqual(findMatchingBlockIDs(in: visible, query: "budget"), [blocks[2].id])
    }

    func testFindIgnoresCaseAndDiacritics() {
        let cafe = paragraph("Meet at the Café")
        let school = paragraph("ÉCOLE du soir")

        XCTAssertEqual(findMatchingBlockIDs(in: [cafe, school], query: "cafe"), [cafe.id])
        XCTAssertEqual(findMatchingBlockIDs(in: [cafe, school], query: "écOLE"), [school.id])
        XCTAssertEqual(findMatchingBlockIDs(in: [cafe, school], query: "CAFÉ"), [cafe.id])
    }

    func testFindMatchesWhatTheReaderSeesNotTheMarkdown() {
        let marked = paragraph("a **bud**get line")
        let link = paragraph("[Roadmap](https://example.org/budget)")

        // The markers are not text anyone reads (`bud**get` reads "budget"), and a link's URL is not shown.
        XCTAssertEqual(findMatchingBlockIDs(in: [marked, link], query: "budget"), [marked.id])
        XCTAssertEqual(findMatchingBlockIDs(in: [marked, link], query: "roadmap"), [link.id])
        XCTAssertEqual(findMatchingBlockIDs(in: [marked, link], query: "**"), [])
    }

    func testBlankQueryFindsNothing() {
        let blocks = [paragraph("anything"), paragraph("")]

        XCTAssertEqual(findMatchingBlockIDs(in: blocks, query: ""), [])
        XCTAssertEqual(findMatchingBlockIDs(in: blocks, query: "   "), [])
    }

    func testQueryIsTrimmed() {
        let block = paragraph("flights and hotels")

        XCTAssertEqual(findMatchingBlockIDs(in: [block], query: "  hotels \n"), [block.id])
    }

    // MARK: - Outline

    func testOutlineListsHeadingsOneToThreeWithTheirLevels() {
        let h1 = heading(1, "Trip")
        let h2 = heading(2, "Budget")
        let h3 = heading(3, "Hotels")
        let outline = buildOutline(blocks: [
            h1, paragraph("intro"), h2, h3, heading(4, "Too deep"), heading(6, "Deeper"),
        ])

        XCTAssertEqual(
            outline,
            [
                OutlineItem(level: 1, title: "Trip", blockID: h1.id, matchCount: 0),
                OutlineItem(level: 2, title: "Budget", blockID: h2.id, matchCount: 0),
                OutlineItem(level: 3, title: "Hotels", blockID: h3.id, matchCount: 0),
            ])
    }

    func testOutlineTitleIsThePlainTextOfTheHeading() {
        let block = heading(2, "  The **big** [plan](https://example.org)  ")

        XCTAssertEqual(buildOutline(blocks: [block]).map(\.title), ["The big plan"])
    }

    func testAHeadingWithNoTextIsNotListed() {
        let blank = heading(2, "   ")
        let real = heading(2, "Real")

        XCTAssertEqual(buildOutline(blocks: [blank, real]).map(\.title), ["Real"])
    }

    func testADocumentWithoutHeadingsHasAnEmptyOutline() {
        XCTAssertEqual(buildOutline(blocks: [paragraph("a"), paragraph("b")]), [])
        XCTAssertEqual(buildOutline(blocks: []), [])
    }

    // MARK: - Section counts

    func testMatchesCountTowardTheirSectionAndItsParents() {
        let trip = heading(1, "Trip")
        let budget = heading(2, "Budget")
        let budgetNote = paragraph("Set a budget")
        let flights = heading(3, "Flights")
        let hotels = heading(3, "Hotels")
        let hotelNote = paragraph("hotel budget")
        let days = heading(2, "Day by day")
        let dayNote = paragraph("temples")
        let blocks = [trip, budget, budgetNote, flights, hotels, hotelNote, days, dayNote]
        let matches = findMatchingBlockIDs(in: blocks, query: "budget")

        // The "Budget" heading itself, the note under it, and the note under "Hotels".
        XCTAssertEqual(matches, [budget.id, budgetNote.id, hotelNote.id])

        let counts = Dictionary(
            uniqueKeysWithValues: buildOutline(blocks: blocks, matchingBlockIDs: matches).map {
                ($0.title, $0.matchCount)
            })
        XCTAssertEqual(
            counts, ["Trip": 3, "Budget": 3, "Flights": 0, "Hotels": 1, "Day by day": 0])
    }

    func testASiblingHeadingEndsTheSectionAbove() {
        let first = heading(2, "First")
        let firstNote = paragraph("needle")
        let second = heading(2, "Second")
        let secondNote = paragraph("needle needle")
        let blocks = [first, firstNote, second, secondNote]
        let matches = findMatchingBlockIDs(in: blocks, query: "needle")

        // Counted per block, not per occurrence, so it agrees with stepping through the matches.
        XCTAssertEqual(buildOutline(blocks: blocks, matchingBlockIDs: matches).map(\.matchCount), [1, 1])
    }

    func testMatchesBeforeTheFirstHeadingBelongToNoSection() {
        let intro = paragraph("needle up front")
        let section = heading(1, "Section")
        let blocks = [intro, section, paragraph("nothing")]
        let matches = findMatchingBlockIDs(in: blocks, query: "needle")

        XCTAssertEqual(matches, [intro.id])
        XCTAssertEqual(buildOutline(blocks: blocks, matchingBlockIDs: matches).map(\.matchCount), [0])
    }

    func testAnUnlistedBlankHeadingStillEndsTheSectionAbove() {
        let section = heading(2, "Section")
        let gap = heading(2, "")
        let below = paragraph("needle")
        let blocks = [section, gap, below]
        let matches = findMatchingBlockIDs(in: blocks, query: "needle")

        XCTAssertEqual(buildOutline(blocks: blocks, matchingBlockIDs: matches).map(\.matchCount), [0])
    }

    func testAHeadingBelowLevelThreeIsBodyTextInsideItsSection() {
        let section = heading(2, "Section")
        let deep = heading(4, "needle deep")
        let blocks = [section, deep]
        let matches = findMatchingBlockIDs(in: blocks, query: "needle")

        XCTAssertEqual(matches, [deep.id])
        XCTAssertEqual(buildOutline(blocks: blocks, matchingBlockIDs: matches).map(\.matchCount), [1])
    }

    func testNoQueryMeansNoCounts() {
        let blocks = [heading(1, "A"), paragraph("text")]

        XCTAssertEqual(buildOutline(blocks: blocks).map(\.matchCount), [0])
    }

    // MARK: - Stepping

    func testNextAndPreviousWrapAround() {
        XCTAssertEqual(steppedMatchIndex(from: 0, by: 1, count: 3), 1)
        XCTAssertEqual(steppedMatchIndex(from: 2, by: 1, count: 3), 0)
        XCTAssertEqual(steppedMatchIndex(from: 0, by: -1, count: 3), 2)
        XCTAssertEqual(steppedMatchIndex(from: 2, by: -1, count: 3), 1)
    }

    func testSteppingFromNothingLandsOnTheNearEnd() {
        XCTAssertEqual(steppedMatchIndex(from: nil, by: 1, count: 4), 0)
        XCTAssertEqual(steppedMatchIndex(from: nil, by: -1, count: 4), 3)
    }

    func testSteppingFromAStaleIndexRestartsRatherThanTrapping() {
        // The document shrank under the position.
        XCTAssertEqual(steppedMatchIndex(from: 7, by: 1, count: 3), 0)
        XCTAssertEqual(steppedMatchIndex(from: 7, by: -1, count: 3), 2)
    }

    func testSteppingThroughNoMatchesGoesNowhere() {
        XCTAssertNil(steppedMatchIndex(from: nil, by: 1, count: 0))
        XCTAssertNil(steppedMatchIndex(from: 0, by: -1, count: 0))
    }

    func testASingleMatchStepsOntoItself() {
        XCTAssertEqual(steppedMatchIndex(from: 0, by: 1, count: 1), 0)
        XCTAssertEqual(steppedMatchIndex(from: 0, by: -1, count: 1), 0)
    }

    // MARK: - Scroll request

    func testEachScrollRequestIsDistinctEvenForTheSameTarget() {
        let id = UUID()
        let first = DocumentScrollRequest.following(nil, target: .block(id))
        let second = DocumentScrollRequest.following(first, target: .block(id))

        XCTAssertEqual(first.target, second.target)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second.token, first.token + 1)
    }
}
