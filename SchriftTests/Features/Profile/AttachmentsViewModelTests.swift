import XCTest

@testable import Schrift

@MainActor
final class AttachmentsViewModelTests: XCTestCase {
    private let origin = "https://docs.llun.dev"
    private let docA = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let docB = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    private func link(
        _ name: String, document: UUID, file: String, ext: String = "pdf", host: String? = nil
    ) -> String {
        "[\(name)](\(host ?? origin)/media/\(document.uuidString.lowercased())/attachments/\(file).\(ext))"
    }

    private let fileOne = "33333333-3333-4333-8333-333333333333"
    private let fileTwo = "44444444-4444-4444-8444-444444444444"

    private func content(_ id: UUID, _ markdown: String, title: String? = "Doc", at seconds: TimeInterval)
        -> CachedDocumentContent
    {
        CachedDocumentContent(
            documentID: id, title: title, markdown: markdown, syncedAt: Date(timeIntervalSince1970: seconds))
    }

    // MARK: - attachmentLibraryGroups

    func testListsAStandaloneAttachmentLine() {
        let markdown = "Intro\n\n\(link("Q3.pdf", document: docA, file: fileOne))\n\nTail"
        let groups = attachmentLibraryGroups(from: [content(docA, markdown, at: 1)], serverOrigin: origin)
        XCTAssertEqual(groups.map(\.documentID), [docA])
        XCTAssertEqual(groups.first?.attachments.map(\.name), ["Q3.pdf"])
        XCTAssertEqual(groups.first?.title, "Doc")
    }

    func testSkipsDocumentsWithoutAttachments() {
        let groups = attachmentLibraryGroups(
            from: [content(docA, "Just prose\n\n[a link](https://example.com)", at: 1)], serverOrigin: origin)
        XCTAssertEqual(groups, [])
    }

    func testSkipsAnAttachmentOnAnotherHost() {
        let markdown = link("x.pdf", document: docA, file: fileOne, host: "https://evil.example.org")
        XCTAssertEqual(attachmentLibraryGroups(from: [content(docA, markdown, at: 1)], serverOrigin: origin), [])
    }

    func testWithNoOriginNothingIsListed() {
        let markdown = link("x.pdf", document: docA, file: fileOne)
        XCTAssertEqual(attachmentLibraryGroups(from: [content(docA, markdown, at: 1)], serverOrigin: ""), [])
    }

    func testSkipsALinkInsideProse() {
        // Adjacent to prose it is part of a multi-line `.unknown`/paragraph block,
        // which the editor draws as text — so it isn't an attachment here either.
        let markdown = "See \(link("x.pdf", document: docA, file: fileOne)) for details"
        XCTAssertEqual(attachmentLibraryGroups(from: [content(docA, markdown, at: 1)], serverOrigin: origin), [])
    }

    func testListsTheSameFileOncePerDocument() {
        let line = link("x.pdf", document: docA, file: fileOne)
        let markdown = "\(line)\n\n\(line)\n\n\(link("y.docx", document: docA, file: fileTwo, ext: "docx"))"
        let groups = attachmentLibraryGroups(from: [content(docA, markdown, at: 1)], serverOrigin: origin)
        XCTAssertEqual(groups.first?.attachments.map(\.name), ["x.pdf", "y.docx"])
    }

    func testGroupsAreNewestSyncFirst() {
        let groups = attachmentLibraryGroups(
            from: [
                content(docA, link("a.pdf", document: docA, file: fileOne), at: 1),
                content(docB, link("b.pdf", document: docB, file: fileTwo), at: 2),
            ],
            serverOrigin: origin)
        XCTAssertEqual(groups.map(\.documentID), [docB, docA])
    }

    // MARK: - Rows

    func testRowsPutAHeaderBeforeEachDocumentsFiles() {
        let groups = attachmentLibraryGroups(
            from: [
                content(docA, link("a.pdf", document: docA, file: fileOne), title: "A", at: 2),
                content(docB, link("b.pdf", document: docB, file: fileTwo), title: "B", at: 1),
            ],
            serverOrigin: origin)
        let rows = attachmentLibraryRows(groups)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0], .header(documentID: docA, title: "A", isFirst: true))
        XCTAssertEqual(rows[2], .header(documentID: docB, title: "B", isFirst: false))
        guard case .file(_, let display) = rows[1] else { return XCTFail("Expected a file row") }
        XCTAssertEqual(display.name, "a.pdf")
    }

    func testOneFileLinkedFromTwoDocumentsHasDistinctRowIDs() {
        // The lazy stack needs unique ids, and the same url appears under both documents.
        let line = link("shared.pdf", document: docA, file: fileOne)
        let groups = attachmentLibraryGroups(
            from: [content(docA, line, at: 2), content(docB, line, at: 1)], serverOrigin: origin)
        let rows = attachmentLibraryRows(groups)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }

    func testABlankTitleFallsBackToUntitled() {
        XCTAssertNil(attachmentGroupTitle(nil))
        XCTAssertNil(attachmentGroupTitle("  \n"))
        XCTAssertEqual(attachmentGroupTitle(" Notes "), "Notes")
    }

    // MARK: - View model

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentsViewModelTests.\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    func testLoadReadsTheContentCache() {
        let cache = DocumentContentCacheStore(directory: directory)
        cache.save(content(docA, link("a.pdf", document: docA, file: fileOne), at: 1))
        let viewModel = AttachmentsViewModel(contentCache: cache, serverOrigin: origin)
        XCTAssertFalse(viewModel.hasLoaded)
        viewModel.load()
        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertEqual(viewModel.groups.map(\.documentID), [docA])
    }

    func testLoadPicksUpDocumentsCachedSinceTheLastLoad() {
        let cache = DocumentContentCacheStore(directory: directory)
        let viewModel = AttachmentsViewModel(contentCache: cache, serverOrigin: origin)
        viewModel.load()
        XCTAssertEqual(viewModel.groups, [])
        cache.save(content(docB, link("b.pdf", document: docB, file: fileTwo), at: 2))
        viewModel.load()
        XCTAssertEqual(viewModel.groups.map(\.documentID), [docB])
    }

    func testLoadWithholdsADocumentWhoseDeletionIsQueued() {
        let cache = DocumentContentCacheStore(directory: directory)
        cache.save(content(docA, link("a.pdf", document: docA, file: fileOne), at: 1))
        cache.save(content(docB, link("b.pdf", document: docB, file: fileTwo), at: 2))
        let viewModel = AttachmentsViewModel(
            contentCache: cache, serverOrigin: origin, isPendingDelete: { [docB] in $0 == docB })
        viewModel.load()
        XCTAssertEqual(viewModel.groups.map(\.documentID), [docA])
        XCTAssertEqual(viewModel.rows.count, 2)
    }
}
