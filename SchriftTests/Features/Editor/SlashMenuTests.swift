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

    /// Editing offline is supported because the draft pipeline queues every edit —
    /// but a photo POSTs a multipart attachment, and there is no queue for one. Offered
    /// offline it would open the picker and re-encode the chosen image only to fail, so
    /// it is withheld like "Add a subpage" and "New page". Everything else is a local
    /// block transformation and stays available.
    func testOfflineWithholdsEveryUploadAndKeepsEveryLocalTransformation() {
        let offline = filteredSlashItems(query: "", isOffline: true)

        XCTAssertFalse(offline.contains { $0.action.requiresUpload })
        // Exactly the uploading items are missing; every local transformation
        // stays, because the draft pipeline queues those like any other edit.
        XCTAssertEqual(offline.count, allSlashMenuItems.filter { !$0.action.requiresUpload }.count)
        XCTAssertEqual(allSlashMenuItems.filter { $0.action.requiresUpload }.count, 2, "photo and file")

        let online = filteredSlashItems(query: "", isOffline: false)
        XCTAssertTrue(online.contains { $0.action == .insertPhoto })
        XCTAssertTrue(online.contains { $0.action == .insertAttachment })
    }

    func testALocalDocumentWithholdsEveryUploadToo() {
        // A client-minted id has nothing to upload against.
        let local = filteredSlashItems(query: "", isLocalDocument: true)
        XCTAssertFalse(local.contains { $0.action.requiresUpload })
    }

    func testTheFileItemMatchesTheWordsSomeoneWouldType() {
        for query in ["file", "attach", "pdf", "doc", "upload"] {
            XCTAssertTrue(
                filteredSlashItems(query: query).contains { $0.action == .insertAttachment },
                "\(query) should surface the File item")
        }
    }

    func testTheFileItemUsesABundledIcon() {
        // `.description` is in the subset font; naming an unbundled glyph would
        // render as a blank box.
        // `.description` is in the bundled subset; naming an unbundled Material
        // glyph would render as a blank box. (Asserting membership in
        // `MaterialIcon.allCases` would prove nothing — every case is in it.)
        XCTAssertEqual(allSlashMenuItems.first { $0.action == .insertAttachment }?.icon, .description)
    }

    /// The gate applies to a search that names it too, not just the unfiltered list —
    /// otherwise typing "/photo" would walk straight past it.
    func testOfflineWithholdsPhotoFromAMatchingQuery() {
        XCTAssertTrue(filteredSlashItems(query: "photo", isOffline: true).isEmpty)
        XCTAssertEqual(filteredSlashItems(query: "photo", isOffline: false).map(\.id), ["photo"])
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
