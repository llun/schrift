import XCTest

@testable import Schrift

final class PendingDraftStoreTests: XCTestCase {
    private func makeStore() -> (PendingDraftStore, UserDefaults) {
        let suiteName = "PendingDraftStoreTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        return (PendingDraftStore(userDefaults: userDefaults), userDefaults)
    }

    private func makeDraft(
        id: String = "11111111-1111-4111-8111-111111111111",
        markdown: String = "# Draft",
        updatedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> PendingDraft {
        PendingDraft(documentID: UUID(uuidString: id)!, title: "Doc", markdown: markdown, updatedAt: updatedAt)
    }

    func testDraftIsNilWhenNothingStored() {
        let (store, _) = makeStore()

        XCTAssertNil(store.draft(for: UUID()))
        XCTAssertTrue(store.allDrafts().isEmpty)
    }

    func testSaveAndLoadRoundTrips() {
        let (store, _) = makeStore()
        let draft = makeDraft()

        store.save(draft)

        XCTAssertEqual(store.draft(for: draft.documentID), draft)
    }

    func testSavingAgainReplacesTheDraftForThatDocument() {
        let (store, _) = makeStore()
        store.save(makeDraft(markdown: "old"))
        let newer = makeDraft(markdown: "new", updatedAt: Date(timeIntervalSince1970: 2_000))

        store.save(newer)

        XCTAssertEqual(store.draft(for: newer.documentID), newer)
        XCTAssertEqual(store.allDrafts().count, 1)
    }

    func testRemoveDeletesOnlyThatDocument() {
        let (store, _) = makeStore()
        let first = makeDraft(id: "11111111-1111-4111-8111-111111111111")
        let second = makeDraft(id: "22222222-2222-4222-8222-222222222222")
        store.save(first)
        store.save(second)

        store.remove(documentID: first.documentID)

        XCTAssertNil(store.draft(for: first.documentID))
        XCTAssertEqual(store.draft(for: second.documentID), second)
    }

    func testAllDraftsAreSortedOldestFirst() {
        let (store, _) = makeStore()
        let older = makeDraft(id: "11111111-1111-4111-8111-111111111111", updatedAt: Date(timeIntervalSince1970: 100))
        let newer = makeDraft(id: "22222222-2222-4222-8222-222222222222", updatedAt: Date(timeIntervalSince1970: 200))
        store.save(newer)
        store.save(older)

        XCTAssertEqual(store.allDrafts(), [older, newer])
    }

    func testCorruptDataIsTreatedAsEmpty() {
        let (store, userDefaults) = makeStore()
        userDefaults.set(Data("not json".utf8), forKey: "dev.llun.Schrift.pendingDrafts")

        XCTAssertNil(store.draft(for: UUID()))
        XCTAssertTrue(store.allDrafts().isEmpty)
    }

    func testDraftWithBaselineRoundTrips() {
        let (store, _) = makeStore()
        let draft = PendingDraft(
            documentID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            title: "Doc",
            markdown: "# Draft",
            updatedAt: Date(timeIntervalSince1970: 1_000),
            baseline: DraftBaseline(
                serverUpdatedAt: Date(timeIntervalSince1970: 900), markdown: "# Server", title: "Server Doc"),
            lastPushedMarkdown: "# Pushed",
            // Safety-critical: this is what makes an unanswered conflict hold survive a relaunch.
            conflictServerUpdatedAt: Date(timeIntervalSince1970: 1_500))

        store.save(draft)

        let loaded = store.draft(for: draft.documentID)
        XCTAssertEqual(loaded, draft)
        XCTAssertEqual(loaded?.baseline?.serverUpdatedAt, Date(timeIntervalSince1970: 900))
        XCTAssertEqual(loaded?.baseline?.markdown, "# Server")
        XCTAssertEqual(loaded?.baseline?.title, "Server Doc")
        XCTAssertEqual(loaded?.lastPushedMarkdown, "# Pushed")
        XCTAssertEqual(loaded?.conflictServerUpdatedAt, Date(timeIntervalSince1970: 1_500))
    }

    /// A draft written before `DraftBaseline` carried a **title** must still load through the
    /// real store — a baseline that failed to decode would take the whole draft with it, and a
    /// draft is unsaved work. The title decodes as nil, which keeps the title rule inert and the
    /// draft's behavior exactly as it was.
    func testLegacyBaselineWithoutATitleDecodesWithTheDraftIntact() {
        let (store, userDefaults) = makeStore()
        let documentID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        // Verbatim shape of a draft persisted by a build with baseline but no title (dates are
        // millisecondsSince1970, per the store).
        let legacy = """
            {"\(documentID.uuidString)":{"documentID":"\(documentID.uuidString)","title":"Doc",\
            "markdown":"# Offline edit","updatedAt":1000000,\
            "baseline":{"serverUpdatedAt":900000,"markdown":"# Server"}}}
            """
        userDefaults.set(Data(legacy.utf8), forKey: "dev.llun.Schrift.pendingDrafts")

        let loaded = store.draft(for: documentID)

        XCTAssertEqual(loaded?.markdown, "# Offline edit", "the unsaved work still loads")
        XCTAssertEqual(loaded?.title, "Doc")
        XCTAssertEqual(loaded?.baseline?.markdown, "# Server")
        XCTAssertEqual(loaded?.baseline?.serverUpdatedAt, Date(timeIntervalSince1970: 900))
        XCTAssertNil(loaded?.baseline?.title, "unknown — never a rename to adopt or conflict over")
    }

    /// A draft persisted by a build predating the baseline fields must still decode
    /// — with the new fields nil, which routes it to the tolerance rule.
    func testLegacyDraftWithoutBaselineDecodesWithNilFields() {
        let (store, userDefaults) = makeStore()
        let id = "11111111-1111-4111-8111-111111111111"
        // updatedAt is encoded as millisecondsSince1970 (matching the store).
        let legacyJSON = """
            {"\(id)": {"documentID": "\(id)", "title": "Doc", "markdown": "# Legacy", "updatedAt": 1000000}}
            """
        userDefaults.set(Data(legacyJSON.utf8), forKey: "dev.llun.Schrift.pendingDrafts")

        let draft = store.draft(for: UUID(uuidString: id)!)
        XCTAssertEqual(draft?.markdown, "# Legacy")
        XCTAssertEqual(draft?.updatedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertNil(draft?.baseline)
        XCTAssertNil(draft?.lastPushedMarkdown)
        XCTAssertNil(draft?.conflictServerUpdatedAt, "a pre-conflict-feature draft decodes with no hold")
    }
}
