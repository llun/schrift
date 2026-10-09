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

    // MARK: - Actions

    func testPhotoItemMatchesImageKeywords() {
        for query in ["photo", "ima", "picture", "img"] {
            XCTAssertTrue(
                filteredSlashItems(query: query).contains { $0.action == .insertPhoto },
                "Expected the photo item to match \"\(query)\"")
        }
    }

    /// The view is what `EditorView` hands `isOffline` / `isLocalDocument` to; the pure filter being
    /// right is not enough if the view forgets to pass them.
    @MainActor
    func testTheMenuViewWithholdsFileOfflineAndOnALocalDocumentOnly() {
        func ids(isOffline: Bool, isLocalDocument: Bool) -> [String] {
            SlashMenuView(query: "", isOffline: isOffline, isLocalDocument: isLocalDocument, onSelect: { _ in }).items
                .map(\.id)
        }
        XCTAssertFalse(ids(isOffline: true, isLocalDocument: false).contains("file"))
        XCTAssertFalse(ids(isOffline: false, isLocalDocument: true).contains("file"))
        XCTAssertTrue(ids(isOffline: false, isLocalDocument: false).contains("file"))
        XCTAssertTrue(ids(isOffline: true, isLocalDocument: true).contains("photo"))
    }
}
