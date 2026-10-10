import XCTest

@testable import Schrift

/// The editor's content reads restore leaf nesting the server's markdown export flattens, from
/// the document's BlockNote tree (`formatted-content/?content_format=json`) — and fall back to
/// the flat export on any doubt.
@MainActor
final class EditorViewModelLeafNestingTests: EditorViewModelTestCase {
    private let photoURL = "https://docs.example.org/media/p.png"
    private var photo: String { "![photo.png](\(photoURL))" }
    /// The export of a checklist item with a photo nested under it, followed by a sibling — the
    /// verbatim shape of BlockNote 0.51.4's `blocksToMarkdownLossy`.
    private var flatExport: String { "* [ ] Task\n\n\(photo)\n\n* [ ] Next\n" }
    private var nestedMarkdown: String { "- [ ] Task\n  \(photo)\n- [ ] Next\n" }

    private func treeBody(updatedAt: String = "2026-01-15T10:30:00Z") -> Data {
        Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": [
              {"id": "a", "type": "checkListItem", "props": {"checked": false},
               "content": [{"type": "text", "text": "Task", "styles": {}}],
               "children": [{"id": "b", "type": "image",
                 "props": {"name": "photo.png", "url": "\(photoURL)", "caption": "", "showPreview": true},
                 "children": []}]},
              {"id": "d", "type": "checkListItem", "props": {"checked": false},
               "content": [{"type": "text", "text": "Next", "styles": {}}], "children": []}],
             "created_at": "2026-01-15T10:30:00Z", "updated_at": "\(updatedAt)"}
            """.utf8)
    }

    /// The markdown read answers the flat export; the tree read answers `treeStatus` with
    /// `treeBody`.
    private func stubExportAndTree(log: RequestRecorder, treeStatus: Int = 200, treeBody: Data? = nil) {
        let markdownBody = formattedBody(content: flatExport.replacingOccurrences(of: "\n", with: "\\n"))
        let tree = treeBody ?? self.treeBody()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if url.contains("content_format=json") {
                return .init(statusCode: treeStatus, headers: [:], body: treeStatus == 200 ? tree : Data(), error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: markdownBody, error: nil)
        }
    }

    private var nestedBlocks: [EditorBlock] {
        [
            EditorBlock(kind: .checklistItem(checked: false), text: "Task"),
            EditorBlock(kind: .image(alt: "photo.png", url: photoURL), indent: 1),
            EditorBlock(kind: .checklistItem(checked: false), text: "Next"),
        ]
    }

    private var flatBlocks: [EditorBlock] {
        nestedBlocks.map { block in
            var flat = block
            flat.indent = 0
            return flat
        }
    }

    func testAFlatExportWithANestedTreeInstallsTheNesting() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        let log = RequestRecorder()
        stubExportAndTree(log: log)

        await viewModel.load()

        XCTAssertTrue(blocksContentEqual(viewModel.blocks, nestedBlocks), "\(viewModel.blocks)")
        XCTAssertEqual(viewModel.rawMarkdown, nestedMarkdown)
        XCTAssertNil(viewModel.errorKey)
        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "content_format=json"), 1)
        // The cache holds the restored body, so the next (offline) open shows the nesting too.
        XCTAssertEqual(contentCache.content(for: documentID)?.markdown, nestedMarkdown)
        // Restoring structure is not an edit.
        XCTAssertFalse(viewModel.isDirty)
    }

    func testAFailedTreeReadInstallsTheFlatExport() async {
        let (viewModel, _, _, _) = makeEnvironment()
        let log = RequestRecorder()
        stubExportAndTree(log: log, treeStatus: 500)

        await viewModel.load()

        XCTAssertTrue(blocksContentEqual(viewModel.blocks, flatBlocks), "\(viewModel.blocks)")
        XCTAssertEqual(viewModel.rawMarkdown, flatExport)
        XCTAssertNil(viewModel.errorKey, "the tree is best-effort: its failure is never the read's")
        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "content_format=json"), 1)
    }

    /// A tree and a markdown body from either side of a co-author's write are not paired.
    func testATreeFromAnotherWriteIsIgnored() async {
        let (viewModel, _, _, _) = makeEnvironment()
        let log = RequestRecorder()
        stubExportAndTree(log: log, treeBody: treeBody(updatedAt: "2026-02-20T10:30:00Z"))

        await viewModel.load()

        XCTAssertTrue(blocksContentEqual(viewModel.blocks, flatBlocks), "\(viewModel.blocks)")
    }

    /// The extra request is made only for a body the export's flattening could have produced.
    func testABodyThatCannotHideNestingAsksForNoTree() async {
        let (viewModel, _, _, _) = makeEnvironment()
        let log = RequestRecorder()
        stubLoad(content: "* [ ] Task\\n\\nPara\\n\\n\(photo)", log: log)

        await viewModel.load()

        XCTAssertFalse(viewModel.blocks.isEmpty)
        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "content_format=json"), 0)
    }

    /// A body cached flat (before the overlay existed, or while it could not run) compares equal
    /// to its restored revalidation — `canonicalMarkdown` ignores leaf nesting — so the ordinary
    /// "server changed" test would leave the flat copy on screen until the next open. A clean,
    /// non-editing screen shows the restored structure straight away.
    func testACachedFlatCopyShowsItsRestoredNestingOnRevalidation() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(offlineCachedEntry(markdown: flatExport))
        let log = RequestRecorder()
        stubExportAndTree(log: log)

        await viewModel.load()

        XCTAssertTrue(blocksContentEqual(viewModel.blocks, nestedBlocks), "\(viewModel.blocks)")
        XCTAssertEqual(viewModel.displaySource, .clean)
        XCTAssertFalse(viewModel.updateAvailable, "same content: no banner")
    }

    /// A flat read the tree could not vouch for — a failed tree read is what a transient
    /// error, a server without the JSON format and a stale pairing all produce — never un-nests
    /// a screen that shows the restored structure, **and never overwrites the nested cached
    /// copy with the flat export**: otherwise the next open (offline, or with the tree read
    /// failing again) shows the document flat.
    func testAFlatRevalidationKeepsTheRestoredNesting() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(offlineCachedEntry(markdown: nestedMarkdown))
        let log = RequestRecorder()
        stubExportAndTree(log: log, treeStatus: 500)

        await viewModel.load()

        XCTAssertTrue(blocksContentEqual(viewModel.blocks, nestedBlocks), "\(viewModel.blocks)")
        XCTAssertFalse(viewModel.updateAvailable)
        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "content_format=json"), 1)
        XCTAssertEqual(contentCache.content(for: documentID)?.markdown, nestedMarkdown)
        XCTAssertFalse(viewModel.isDirty)

        // And a second failed read changes nothing: the screen's spelling is what the cache
        // keeps, and the next open still finds the nesting.
        await viewModel.refresh()
        XCTAssertTrue(blocksContentEqual(viewModel.blocks, nestedBlocks), "\(viewModel.blocks)")
        XCTAssertEqual(contentCache.content(for: documentID)?.markdown, nestedMarkdown)
    }

    /// The tree's top-level image — the photo is no longer nested on the server.
    private var flatTreeBody: Data {
        Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": [
              {"id": "a", "type": "checkListItem", "props": {"checked": false},
               "content": [{"type": "text", "text": "Task", "styles": {}}], "children": []},
              {"id": "b", "type": "image",
               "props": {"name": "photo.png", "url": "\(photoURL)", "caption": "", "showPreview": true},
               "children": []},
              {"id": "d", "type": "checkListItem", "props": {"checked": false},
               "content": [{"type": "text", "text": "Next", "styles": {}}], "children": []}],
             "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
            """.utf8)
    }

    /// A co-author un-nested the photo on the web. The markdown export reads exactly as it did
    /// when the photo was nested, so only the tree can say so — and when it positively does
    /// (`.confirmedFlat`), a clean, non-editing screen shows the flat structure, and the cache
    /// follows it.
    func testACoAuthorsUnNestingInstallsTheFlatStructure() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(offlineCachedEntry(markdown: nestedMarkdown))
        let log = RequestRecorder()
        stubExportAndTree(log: log, treeBody: flatTreeBody)

        await viewModel.load()

        XCTAssertTrue(blocksContentEqual(viewModel.blocks, flatBlocks), "\(viewModel.blocks)")
        XCTAssertEqual(viewModel.rawMarkdown, flatExport)
        XCTAssertEqual(contentCache.content(for: documentID)?.markdown, flatExport)
        XCTAssertEqual(viewModel.displaySource, .clean)
        XCTAssertFalse(viewModel.updateAvailable, "same content: no banner")
        XCTAssertFalse(viewModel.isDirty, "adopting the server's structure is not an edit")
    }

    /// Mid-edit the confirmation waits, as the reveal does: nothing swaps the blocks under
    /// the caret over a structure-only change.
    func testAnUnNestingWaitsWhileEditing() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(offlineCachedEntry(markdown: nestedMarkdown))
        let log = RequestRecorder()
        stubOffline(log: log)
        await viewModel.load()
        viewModel.startEditing()
        stubExportAndTree(log: log, treeBody: flatTreeBody)

        await viewModel.load()

        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "content_format=json"), 1)
        XCTAssertTrue(viewModel.isEditing)
        XCTAssertTrue(blocksContentEqual(viewModel.blocks, nestedBlocks), "\(viewModel.blocks)")
        XCTAssertFalse(viewModel.isDirty)
    }
}
