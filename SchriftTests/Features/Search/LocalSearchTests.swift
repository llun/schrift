import XCTest

@testable import Schrift

final class LocalSearchTests: XCTestCase {
    private let en = Locale(identifier: "en_US")

    private func document(
        _ id: Int, title: String?, excerpt: String? = nil, updatedAt: TimeInterval = 1_000
    ) -> Document {
        Document(
            id: UUID(uuidString: "00000000-0000-4000-8000-\(String(format: "%012d", id))")!, title: title,
            excerpt: excerpt, abilities: DocumentAbilities(), linkReach: .restricted, linkRole: .reader,
            isFavorite: false, depth: 1, numchild: 0, path: String(format: "%04d", id),
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: updatedAt),
            userRole: nil, creator: nil)
    }

    private func entries(_ documents: [Document], bodies: [Int: String] = [:]) -> [LocalSearchEntry] {
        documents.enumerated().map { index, document in
            LocalSearchEntry(document: document, body: bodies[index])
        }
    }

    private func titles(_ documents: [Document]) -> [String] {
        documents.map { $0.title ?? "" }
    }

    // MARK: - Matching

    func testMatchingIsCaseAndDiacriticInsensitive() {
        let docs = [document(1, title: "Café menu"), document(2, title: "Budget")]
        XCTAssertEqual(
            titles(localSearchResults(query: "CAFE", entries: entries(docs), locale: en)), ["Café menu"])
        XCTAssertEqual(
            titles(localSearchResults(query: "café", entries: entries([document(3, title: "Cafe")]), locale: en)),
            ["Cafe"])
    }

    func testEveryTermMustMatchSomewhere() {
        let docs = [
            document(1, title: "Trip to Chiang Mai", excerpt: "Flights booked"),
            document(2, title: "Trip budget"),
        ]
        XCTAssertEqual(
            titles(localSearchResults(query: "trip flights", entries: entries(docs), locale: en)),
            ["Trip to Chiang Mai"])
        XCTAssertTrue(localSearchResults(query: "trip zebra", entries: entries(docs), locale: en).isEmpty)
    }

    func testBodyAndExcerptAreSearched() {
        let docs = [document(1, title: "Notes"), document(2, title: "Other", excerpt: "fastlane tips")]
        let found = localSearchResults(
            query: "fastlane", entries: entries(docs, bodies: [0: "Run fastlane match first"]), locale: en)
        XCTAssertEqual(Set(titles(found)), ["Notes", "Other"])
    }

    func testDocumentsWithoutAnyMatchOrWithBlankQueryAreNotReturned() {
        let docs = [document(1, title: "Roadmap")]
        XCTAssertTrue(localSearchResults(query: "budget", entries: entries(docs), locale: en).isEmpty)
        XCTAssertTrue(localSearchResults(query: "   ", entries: entries(docs), locale: en).isEmpty)
        XCTAssertTrue(localSearchResults(query: "", entries: entries(docs), locale: en).isEmpty)
    }

    func testUntitledDocumentMatchesThroughItsText() {
        let docs = [document(1, title: nil, excerpt: "Hotel near Nimman")]
        XCTAssertEqual(localSearchResults(query: "hotel", entries: entries(docs), locale: en).count, 1)
    }

    func testCJKMatchesAsASubstring() {
        let docs = [document(1, title: "东京旅行计划")]
        XCTAssertEqual(titles(localSearchResults(query: "旅行", entries: entries(docs), locale: en)), ["东京旅行计划"])
    }

    func testAgreesWithTheHighlightRule() {
        // A title found here is one the row then highlights, for the same query and locale.
        let docs = [document(1, title: "Hotel shortlist"), document(2, title: "Résumé")]
        for query in ["HOTEL", "resume", "hot list"] {
            for found in localSearchResults(query: query, entries: entries(docs), locale: en) {
                XCTAssertFalse(
                    searchHighlightRanges(in: found.title ?? "", query: query, locale: en).isEmpty, query)
            }
        }
    }

    // MARK: - Ranking

    func testTitleMatchesRankAboveBodyMatchesRegardlessOfRecency() {
        let docs = [
            document(1, title: "Weekly notes", updatedAt: 9_000),
            document(2, title: "Hotel shortlist", updatedAt: 1_000),
            document(3, title: "Budget", excerpt: "hotel nights capped", updatedAt: 8_000),
        ]
        let found = localSearchResults(
            query: "hotel", entries: entries(docs, bodies: [0: "the hotel was fine"]), locale: en)
        XCTAssertEqual(titles(found), ["Hotel shortlist", "Weekly notes", "Budget"])
    }

    func testWithinARankTheMostRecentLeadsThenTitleThenID() {
        let docs = [
            document(1, title: "Beta hotel", updatedAt: 1_000),
            document(2, title: "Alpha hotel", updatedAt: 1_000),
            document(3, title: "Gamma hotel", updatedAt: 5_000),
        ]
        XCTAssertEqual(
            titles(localSearchResults(query: "hotel", entries: entries(docs), locale: en)),
            ["Gamma hotel", "Alpha hotel", "Beta hotel"])
    }

    func testAllTermsInTheTitleOutranksTermsSplitAcrossTitleAndText() {
        let docs = [
            document(1, title: "Trip", excerpt: "budget set", updatedAt: 9_000),
            document(2, title: "Trip budget", updatedAt: 1_000),
        ]
        XCTAssertEqual(
            titles(localSearchResults(query: "trip budget", entries: entries(docs), locale: en)),
            ["Trip budget", "Trip"])
    }

    func testRepeatedIDsAppearOnceAndLimitApplies() {
        let doc = document(1, title: "Hotel")
        let found = localSearchResults(query: "hotel", entries: entries([doc, doc]), locale: en)
        XCTAssertEqual(found.count, 1)

        let many = (1...10).map { document($0, title: "Hotel \($0)", updatedAt: TimeInterval($0)) }
        XCTAssertEqual(localSearchResults(query: "hotel", entries: entries(many), locale: en, limit: 3).count, 3)
        XCTAssertTrue(localSearchResults(query: "hotel", entries: entries(many), locale: en, limit: 0).isEmpty)
    }

    // MARK: - Snippets

    func testBodyOnlyMatchShowsTheMatchingLineAsItsExcerpt() {
        let docs = [document(1, title: "Notes", excerpt: "Weekly sync")]
        let body = "# Notes\n\nWeekly sync\n\n- Need a hotel near Nimman\n- Book flights"
        let found = localSearchResults(query: "hotel", entries: entries(docs, bodies: [0: body]), locale: en)
        XCTAssertEqual(found.first?.excerpt, "Need a hotel near Nimman")
    }

    func testExcerptThatAlreadyMatchesIsKept() {
        let docs = [document(1, title: "Notes", excerpt: "hotel list")]
        let found = localSearchResults(
            query: "hotel", entries: entries(docs, bodies: [0: "later: hotel again"]), locale: en)
        XCTAssertEqual(found.first?.excerpt, "hotel list")
    }

    func testTitleMatchKeepsItsExcerpt() {
        let docs = [document(1, title: "Hotel", excerpt: "unrelated words")]
        let found = localSearchResults(
            query: "hotel", entries: entries(docs, bodies: [0: "hotel in the body"]), locale: en)
        XCTAssertEqual(found.first?.excerpt, "unrelated words")
    }

    func testSnippetDropsLeadingMarkersAndIsCapped() {
        XCTAssertEqual(localSearchSnippet(body: "## Hotel plan", query: "hotel", locale: en), "Hotel plan")
        XCTAssertNil(localSearchSnippet(body: "nothing here", query: "hotel", locale: en))
        let long = String(repeating: "word ", count: 100) + "hotel " + String(repeating: "more ", count: 100)
        let snippet = localSearchSnippet(body: long, query: "hotel", locale: en)
        XCTAssertLessThanOrEqual(snippet?.count ?? .max, localSearchSnippetMaxLength)
        XCTAssertTrue(snippet?.hasPrefix("…") ?? false)
        XCTAssertTrue(snippet?.contains("hotel") ?? false, "the cap must not cut the match off")
    }

    // MARK: - Entries

    func testEntriesPairBodiesWithListedDocumentsOnly() {
        let listed = document(1, title: "Listed")
        let stranger = UUID()
        let contents = [
            CachedDocumentContent(documentID: listed.id, title: nil, markdown: "listed body", syncedAt: Date()),
            CachedDocumentContent(documentID: stranger, title: nil, markdown: "stranger body", syncedAt: Date()),
        ]
        let built = localSearchEntries(documents: [listed, listed], contents: contents)
        XCTAssertEqual(built.map(\.document.id), [listed.id])
        XCTAssertEqual(built.first?.body, "listed body")
        XCTAssertTrue(
            localSearchResults(query: "stranger", entries: built, locale: en).isEmpty,
            "a cached body nobody listed is never searched")
    }

    // MARK: - Cancellation

    func testACancelledScanReturnsNothing() async {
        let docs = (1...200).map { document($0, title: "Hotel \($0)") }
        let all = entries(docs)
        let locale = en
        let task = Task.detached { () -> [Document] in
            while !Task.isCancelled { await Task.yield() }
            return localSearchResults(query: "hotel", entries: all, locale: locale)
        }
        task.cancel()
        let found = await task.value
        XCTAssertTrue(found.isEmpty)
    }

    // MARK: - Merge

    func testServerRowsKeepTheirOrderAndLocalOnlyRowsFollow() {
        let a = document(1, title: "A")
        let b = document(2, title: "B")
        let c = document(3, title: "C")
        let merged = mergeSearchResults(server: [b, a], serverIsCurrent: true, local: [a, c])
        XCTAssertEqual(merged.server.map(\.id), [b.id, a.id])
        XCTAssertEqual(merged.localOnly.map(\.id), [c.id])
        XCTAssertEqual(merged.all.map(\.id), [b.id, a.id, c.id])
    }

    func testAnIDBothFoundAppearsOnceWithTheServersCopy() {
        var fresh = document(1, title: "Server title")
        fresh.isFavorite = true
        let stale = document(1, title: "Cached title")
        let merged = mergeSearchResults(server: [fresh], serverIsCurrent: true, local: [stale])
        XCTAssertEqual(merged.all.count, 1)
        XCTAssertEqual(merged.all.first?.title, "Server title")
        XCTAssertTrue(merged.localOnly.isEmpty)
    }

    func testStaleServerRowsGiveWayToTheDevicesMatches() {
        let old = document(1, title: "Old answer")
        let mine = document(2, title: "Mine")
        let merged = mergeSearchResults(server: [old], serverIsCurrent: false, local: [mine])
        XCTAssertTrue(merged.server.isEmpty)
        XCTAssertEqual(merged.localOnly.map(\.id), [mine.id])
    }

    func testStaleServerRowsStayWhenTheDeviceHasNothingToShow() {
        let old = document(1, title: "Old answer")
        let merged = mergeSearchResults(server: [old], serverIsCurrent: false, local: [])
        XCTAssertEqual(merged.server.map(\.id), [old.id])
        XCTAssertFalse(merged.isEmpty)
    }

    func testNothingFromEitherSideIsEmpty() {
        XCTAssertTrue(mergeSearchResults(server: [], serverIsCurrent: true, local: []).isEmpty)
    }
}
