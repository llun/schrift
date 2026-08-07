import XCTest

@testable import Schrift

final class SlashMenuTests: XCTestCase {
    func testSlashQueryDetectedOnParagraphsOnly() {
        XCTAssertEqual(slashQuery(text: "/", kind: .paragraph), "")
        XCTAssertEqual(slashQuery(text: "/head", kind: .paragraph), "head")
        XCTAssertNil(slashQuery(text: "/head", kind: .bulletItem))
        XCTAssertNil(slashQuery(text: "no slash", kind: .paragraph))
        XCTAssertNil(slashQuery(text: "middle / slash", kind: .paragraph))
    }

    func testEmptyQueryReturnsAllItems() {
        XCTAssertEqual(filteredSlashItems(query: ""), allSlashMenuItems)
    }

    func testFilteringMatchesTitleSubstrings() {
        let items = filteredSlashItems(query: "heading")
        XCTAssertEqual(items.map(\.id), ["heading1", "heading2", "heading3"])
    }

    func testFilteringMatchesKeywordPrefixes() {
        XCTAssertEqual(filteredSlashItems(query: "h1").map(\.id), ["heading1"])
        XCTAssertTrue(filteredSlashItems(query: "todo").map(\.id).contains("checklist"))
        XCTAssertTrue(filteredSlashItems(query: "hr").map(\.id).contains("divider"))
    }

    func testFilteringIsCaseInsensitive() {
        XCTAssertEqual(filteredSlashItems(query: "HEAD").map(\.id), ["heading1", "heading2", "heading3"])
    }

    func testNoMatchesReturnsEmpty() {
        XCTAssertTrue(filteredSlashItems(query: "zzzz").isEmpty)
    }

    /// Offline withholds only what has nowhere to go. **File** still POSTs with no queue
    /// behind it; **Photo** is offered, because a queued photo is stored on the device and
    /// uploaded by the attachment replay.
    func testOfflineWithholdsOnlyTheFileItem() {
        let offline = filteredSlashItems(query: "", isOffline: true)

        XCTAssertFalse(offline.contains { $0.action == .insertAttachment })
        XCTAssertTrue(offline.contains { $0.action == .insertPhoto })
        XCTAssertEqual(offline.count, allSlashMenuItems.count - 1)
        XCTAssertEqual(
            allSlashMenuItems.filter { $0.action.requiresImmediateUpload }.count, 1,
            "file only — photo has a queue now")

        let online = filteredSlashItems(query: "", isOffline: false)
        XCTAssertTrue(online.contains { $0.action == .insertPhoto })
        XCTAssertTrue(online.contains { $0.action == .insertAttachment })
    }

    func testALocalDocumentWithholdsTheFileItemButOffersPhoto() {
        // A client-minted id has nothing to upload against — but a queued photo waits for the
        // document's own create and uploads after it, so it is offered.
        let local = filteredSlashItems(query: "", isLocalDocument: true)
        XCTAssertFalse(local.contains { $0.action == .insertAttachment })
        XCTAssertTrue(local.contains { $0.action == .insertPhoto })
    }

    /// The gate applies to a search that names it too, not just the unfiltered list.
    func testPhotoIsFoundByAMatchingQueryEvenOffline() {
        XCTAssertEqual(filteredSlashItems(query: "photo", isOffline: true).map(\.id), ["photo"])
        XCTAssertTrue(filteredSlashItems(query: "file", isOffline: true).isEmpty)
    }

    func testTheFileItemMatchesTheWordsSomeoneWouldType() {
        for query in ["file", "attach", "pdf", "doc", "upload"] {
            XCTAssertTrue(
                filteredSlashItems(query: query).contains { $0.action == .insertAttachment },
                "\(query) should surface the File item")
        }
    }

    func testTheFileItemUsesABundledIcon() {
        // `.description` is in the bundled subset; naming an unbundled Material glyph would
        // render as a blank box. (Asserting membership in `MaterialIcon.allCases` would prove
        // nothing — every case is in it.)
        XCTAssertEqual(allSlashMenuItems.first { $0.action == .insertAttachment }?.icon, .description)
    }

    /// And a search that names it finds it, not just the unfiltered list.
    func testPhotoIsFoundByAMatchingQuery() {
        XCTAssertEqual(filteredSlashItems(query: "photo").map(\.id), ["photo"])
    }

    // MARK: - Actions

    func testConvertItemsCarryTheirBlockKind() {
        XCTAssertEqual(allSlashMenuItems.first { $0.id == "heading2" }?.action, .convert(.heading(level: 2)))
        XCTAssertEqual(allSlashMenuItems.first { $0.id == "divider" }?.action, .convert(.divider))
    }

    /// Every other item just swaps a `BlockKind`; the photo item is the one
    /// side-effecting action, and its block is inserted later, on upload success.
    func testPhotoItemIsTheOnlySideEffectAction() {
        XCTAssertEqual(allSlashMenuItems.filter { $0.action == .insertPhoto }.map(\.id), ["photo"])
    }

    func testPhotoItemMatchesImageKeywords() {
        for query in ["photo", "ima", "picture", "img"] {
            XCTAssertTrue(
                filteredSlashItems(query: query).contains { $0.action == .insertPhoto },
                "Expected the photo item to match \"\(query)\"")
        }
    }
}
