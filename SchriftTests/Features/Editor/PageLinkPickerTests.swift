import XCTest

@testable import Schrift

/// The `[[` page picker's pure pieces: trigger detection, ranking, the link it inserts.
final class PageLinkPickerTests: XCTestCase {
    private let currentID = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!
    private let serverHost = "docs.example.org"

    private func document(
        _ title: String?, id: UUID = UUID(), updatedAt: TimeInterval = 0
    ) -> Document {
        Document(
            id: id, title: title, excerpt: nil, abilities: DocumentAbilities(), linkReach: .restricted,
            linkRole: .reader, isFavorite: false, depth: 1, numchild: 0, path: "0001",
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: updatedAt),
            userRole: .owner, creator: nil)
    }

    private func utf16Length(_ text: String) -> Int {
        (text as NSString).length
    }

    // MARK: - Trigger detection

    func testTwoOpeningBracketsStartAnEmptySearch() {
        XCTAssertEqual(
            pageLinkTrigger(in: "[[", caret: 2), PageLinkTrigger(range: NSRange(location: 0, length: 2), query: ""))
    }

    func testTheQueryIsWhatFollowsTheBracketsUpToTheCaret() {
        let text = "Details are in [[rel"
        let trigger = pageLinkTrigger(in: text, caret: utf16Length(text))
        XCTAssertEqual(trigger?.query, "rel")
        XCTAssertEqual(trigger?.range, NSRange(location: 15, length: 5))
        XCTAssertEqual(trigger?.anchor, 15)
    }

    func testOnlyTheTextBeforeTheCaretIsTheQuery() {
        let text = "See [[release notes later"
        XCTAssertEqual(pageLinkTrigger(in: text, caret: 13)?.query, "release")
    }

    func testAQueryMayContainSpacesButNotStartWithOne() {
        let text = "[[project plan"
        XCTAssertEqual(pageLinkTrigger(in: text, caret: utf16Length(text))?.query, "project plan")
        XCTAssertNil(pageLinkTrigger(in: "[[ project", caret: 10))
        XCTAssertNil(pageLinkTrigger(in: "[[ ", caret: 3))
    }

    func testASingleBracketIsNotATrigger() {
        XCTAssertNil(pageLinkTrigger(in: "[rel", caret: 4))
        XCTAssertNil(pageLinkTrigger(in: "[a[rel", caret: 6))
    }

    func testAClosingBracketEndsTheSearch() {
        XCTAssertNil(pageLinkTrigger(in: "[[rel]", caret: 6))
        XCTAssertNil(pageLinkTrigger(in: "[[rel]]", caret: 7))
    }

    func testBackspacingPastTheBracketsEndsTheSearch() {
        XCTAssertNotNil(pageLinkTrigger(in: "a [[", caret: 4))
        XCTAssertNil(pageLinkTrigger(in: "a [", caret: 3))
    }

    func testACaretBeforeTheBracketsIsNotInTheSearch() {
        XCTAssertNil(pageLinkTrigger(in: "a [[rel", caret: 1))
        XCTAssertNil(pageLinkTrigger(in: "a [[rel", caret: 3), "between the two brackets")
    }

    func testEscapedTripledAndCodeSpanBracketsAreLiteral() {
        XCTAssertNil(pageLinkTrigger(in: "\\[[rel", caret: 6))
        XCTAssertNil(pageLinkTrigger(in: "[[[rel", caret: 6))
        XCTAssertNil(pageLinkTrigger(in: "`[[rel", caret: 6))
        XCTAssertEqual(pageLinkTrigger(in: "`a` [[rel", caret: 9)?.query, "rel", "a closed code span is behind it")
    }

    func testAnExistingLinkBeforeTheBracketsDoesNotInterfere() {
        let text = "[Roadmap](https://docs.example.org/docs/x/) and [[rel"
        XCTAssertEqual(pageLinkTrigger(in: text, caret: utf16Length(text))?.query, "rel")
    }

    func testAnOverlongQueryIsNoLongerASearch() {
        let long = "[[" + String(repeating: "a", count: pageLinkMaxQueryLength)
        XCTAssertNotNil(pageLinkTrigger(in: long, caret: utf16Length(long)))
        let tooLong = long + "a"
        XCTAssertNil(pageLinkTrigger(in: tooLong, caret: utf16Length(tooLong)))
    }

    func testOutOfRangeCaretsAreRefused() {
        XCTAssertNil(pageLinkTrigger(in: "[[", caret: 1))
        XCTAssertNil(pageLinkTrigger(in: "[[", caret: 3))
        XCTAssertNil(pageLinkTrigger(in: "", caret: 0))
    }

    /// Ranges are UTF-16, the coordinates the caret and `NSRange` use.
    func testRangesAreUTF16Offsets() {
        let text = "😀 [[ré"
        let trigger = pageLinkTrigger(in: text, caret: utf16Length(text))
        XCTAssertEqual(trigger?.range, NSRange(location: 3, length: 4))
        XCTAssertEqual(trigger?.query, "ré")
    }

    // MARK: - Ranking

    func testTitlePrefixRanksAboveWordPrefixAboveContains() {
        let contains = document("Prerelease plan", updatedAt: 300)
        let wordPrefix = document("Schrift release checklist", updatedAt: 200)
        let prefix = document("Release notes 1.4", updatedAt: 100)
        let ranked = rankedPageLinkCandidates(
            query: "rel", documents: [contains, wordPrefix, prefix], excluding: currentID)
        XCTAssertEqual(ranked.map(\.id), [prefix.id, wordPrefix.id, contains.id])
    }

    func testMatchingIgnoresCaseAndDiacritics() {
        let resume = document("Résumé draft")
        XCTAssertEqual(
            rankedPageLinkCandidates(query: "RESUME", documents: [resume], excluding: currentID).map(\.id),
            [resume.id])
        XCTAssertEqual(
            rankedPageLinkCandidates(query: "résumé", documents: [document("resume")], excluding: currentID).count,
            1)
    }

    func testNonMatchingTitlesAreDropped() {
        XCTAssertTrue(
            rankedPageLinkCandidates(query: "zzz", documents: [document("Release notes")], excluding: currentID)
                .isEmpty)
    }

    func testEveryWordOfTheQueryMustAppear() {
        let plan = document("Project plan 2026")
        let other = document("Project notes")
        XCTAssertEqual(
            rankedPageLinkCandidates(query: "proj 2026", documents: [plan, other], excluding: currentID).map(\.id),
            [plan.id])
    }

    func testAnEmptyQueryOffersTheMostRecentlyUpdatedFirst() {
        let old = document("Old", updatedAt: 1)
        let new = document("New", updatedAt: 3)
        let middle = document("Middle", updatedAt: 2)
        XCTAssertEqual(
            rankedPageLinkCandidates(query: "", documents: [old, new, middle], excluding: currentID).map(\.id),
            [new.id, middle.id, old.id])
    }

    func testTheCurrentDocumentUntitledDocumentsAndRepeatsAreExcluded() {
        let current = document("Release notes", id: currentID)
        let untitled = document(nil)
        let blank = document("   ")
        let shared = document("Release plan")
        let ranked = rankedPageLinkCandidates(
            query: "", documents: [current, untitled, blank, shared, shared], excluding: currentID)
        XCTAssertEqual(ranked.map(\.id), [shared.id])
    }

    func testTheFirstCopyOfARepeatedDocumentWins() {
        let id = UUID()
        let fresh = document("Renamed", id: id)
        let stale = document("Old name", id: id)
        XCTAssertEqual(
            rankedPageLinkCandidates(query: "", documents: [fresh, stale], excluding: currentID).map(\.title),
            ["Renamed"])
    }

    func testResultsAreCappedAtTheLimit() {
        let documents = (0..<10).map { document("Page \($0)", updatedAt: TimeInterval($0)) }
        XCTAssertEqual(rankedPageLinkCandidates(query: "page", documents: documents, excluding: currentID).count, 6)
        XCTAssertEqual(
            rankedPageLinkCandidates(query: "page", documents: documents, excluding: currentID, limit: 2).count, 2)
    }

    func testTheMatchRangeIsTheFirstFoldedOccurrence() throws {
        let title = "Schrift Release"
        let range = try XCTUnwrap(pageLinkMatchRange(in: title, query: "rel"))
        XCTAssertEqual(String(title[range]), "Rel")
        XCTAssertNil(pageLinkMatchRange(in: title, query: ""))
        XCTAssertNil(pageLinkMatchRange(in: title, query: "zzz"))
    }

    // MARK: - The inserted link

    func testPickingReplacesTheQueryWithACanonicalDocumentLink() throws {
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let text = "Details are in [[rel today"
        let trigger = try XCTUnwrap(pageLinkTrigger(in: text, caret: 20))
        let edit = try XCTUnwrap(
            pageLinkInsertion(
                in: text, trigger: trigger, document: document("Release notes", id: id), serverHost: serverHost))
        let link = "[Release notes](https://docs.example.org/docs/11111111-1111-4111-8111-111111111111/)"
        XCTAssertEqual(edit.text, "Details are in " + link + " today")
        XCTAssertEqual(edit.selection, NSRange(location: 15 + utf16Length(link), length: 0))
    }

    /// The whole point: what the picker writes is exactly what the chip and the in-app
    /// opener recognise.
    func testTheInsertedLinkIsADocumentLinkThatOpensTheDocument() throws {
        let id = UUID()
        let trigger = try XCTUnwrap(pageLinkTrigger(in: "[[r", caret: 3))
        let edit = try XCTUnwrap(
            pageLinkInsertion(
                in: "[[r", trigger: trigger, document: document("Roadmap", id: id), serverHost: serverHost))
        let span = try XCTUnwrap(InlineMarkdown.layout(of: edit.text).links.first)
        XCTAssertEqual(span.label, "Roadmap")
        XCTAssertTrue(isDocumentLink(href: span.url, serverHost: serverHost))
        let url = try XCTUnwrap(URL(string: span.url))
        XCTAssertEqual(
            documentLinkAction(for: url, serverHost: serverHost, currentDocumentID: currentID), .openInApp(id))
    }

    func testBracketsInATitleAreEscapedSoTheLinkSurvives() throws {
        let trigger = try XCTUnwrap(pageLinkTrigger(in: "[[n", caret: 3))
        let edit = try XCTUnwrap(
            pageLinkInsertion(in: "[[n", trigger: trigger, document: document("Notes [draft]"), serverHost: serverHost))
        let span = try XCTUnwrap(InlineMarkdown.layout(of: edit.text).links.first)
        XCTAssertEqual(span.label, "Notes [draft]")
        XCTAssertTrue(edit.text.hasPrefix("[Notes \\[draft\\]]("))
    }

    func testNoLinkWithoutAHostOrATitle() throws {
        let trigger = try XCTUnwrap(pageLinkTrigger(in: "[[", caret: 2))
        XCTAssertNil(pageLinkInsertion(in: "[[", trigger: trigger, document: document("Roadmap"), serverHost: ""))
        XCTAssertNil(pageLinkInsertion(in: "[[", trigger: trigger, document: document(nil), serverHost: serverHost))
    }

    func testAStaleTriggerPastTheEndOfTheTextInsertsNothing() {
        let trigger = PageLinkTrigger(range: NSRange(location: 4, length: 5), query: "rel")
        XCTAssertNil(
            pageLinkInsertion(in: "[[r", trigger: trigger, document: document("Roadmap"), serverHost: serverHost))
    }

    // MARK: - Keys and dismissal

    func testArrowKeysWrapAroundTheRows() {
        XCTAssertEqual(movedPageLinkHighlight(0, by: .down, count: 3), 1)
        XCTAssertEqual(movedPageLinkHighlight(2, by: .down, count: 3), 0)
        XCTAssertEqual(movedPageLinkHighlight(0, by: .up, count: 3), 2)
        XCTAssertEqual(movedPageLinkHighlight(1, by: .escape, count: 3), 1)
        XCTAssertEqual(movedPageLinkHighlight(5, by: .down, count: 0), 0)
    }

    /// The empty "No matching pages" state has no row to move to, so the arrows keep moving
    /// the caret; Escape still closes the card.
    func testArrowsAreClaimedOnlyWithRowsAndEscapeAlways() {
        XCTAssertTrue(pageLinkPickerClaims(.up, matchCount: 2))
        XCTAssertTrue(pageLinkPickerClaims(.down, matchCount: 1))
        XCTAssertTrue(pageLinkPickerClaims(.escape, matchCount: 1))
        XCTAssertFalse(pageLinkPickerClaims(.up, matchCount: 0))
        XCTAssertFalse(pageLinkPickerClaims(.down, matchCount: 0))
        XCTAssertTrue(pageLinkPickerClaims(.escape, matchCount: 0))
    }

    func testTheOpenerCheckSeesOnlyBracketsAtTheAnchor() {
        XCTAssertTrue(hasPageLinkOpener(in: "a [[rel", at: 2))
        XCTAssertFalse(hasPageLinkOpener(in: "a [rel", at: 2))
        XCTAssertFalse(hasPageLinkOpener(in: "a [[", at: 3))
        XCTAssertFalse(hasPageLinkOpener(in: "a", at: -1))
    }

    func testThePickerStateNamesItsHighlightedRow() {
        let first = document("A")
        let second = document("B")
        XCTAssertEqual(
            PageLinkPickerState(query: "", matches: [first, second], highlightedIndex: 1).highlighted?.id, second.id)
        XCTAssertNil(PageLinkPickerState(query: "z", matches: [], highlightedIndex: 0).highlighted)
    }
}
