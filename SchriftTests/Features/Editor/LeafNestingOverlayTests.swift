import XCTest

@testable import Schrift

/// The pure halves of restoring leaf nesting the server's markdown export flattens
/// (`LeafNestingOverlay.swift`). Every "export" fixture here is the verbatim output of
/// `@blocknote/server-util` 0.51.4's `blocksToMarkdownLossy` for the tree beside it, which is
/// what the docs backend's `formatted-content/?content_format=markdown` serves.
final class LeafNestingOverlayTests: XCTestCase {
    private let origin = "https://docs.example.com"
    private let imageURL =
        "https://docs.example.com/media/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/attachments/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.png"
    private let fileURL =
        "https://docs.example.com/media/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/attachments/cccccccc-cccc-4ccc-8ccc-cccccccccccc.pdf"
    private var photo: String { "![photo.png](\(imageURL))" }
    private var file: String { "[report.pdf](\(fileURL))" }

    private func check(_ children: [BlockNoteTreeNode] = []) -> BlockNoteTreeNode {
        BlockNoteTreeNode(type: "checkListItem", children: children)
    }

    private func numbered(_ children: [BlockNoteTreeNode] = []) -> BlockNoteTreeNode {
        BlockNoteTreeNode(type: "numberedListItem", children: children)
    }

    private var image: BlockNoteTreeNode { BlockNoteTreeNode(type: "image", url: imageURL, showPreview: true) }
    private var fileNode: BlockNoteTreeNode { BlockNoteTreeNode(type: "file", url: fileURL) }

    private func recover(_ markdown: String, _ tree: [BlockNoteTreeNode]) -> String? {
        markdownRecoveringLeafNesting(markdown, tree: tree, serverOrigin: origin)
    }

    // MARK: - Every export shape restores

    func testAPhotoUnderAChecklistItem() {
        XCTAssertEqual(
            recover("* [ ] Task\n\n\(photo)\n\n* [ ] Next\n", [check([image]), check()]),
            "- [ ] Task\n  \(photo)\n- [ ] Next\n")
    }

    func testAPhotoAndAFileUnderOneItem() throws {
        let recovered = try XCTUnwrap(
            recover("* [ ] Task\n\n\(photo)\n\n\(file)\n\n* [ ] Next\n", [check([image, fileNode]), check()]))
        XCTAssertEqual(recovered, "- [ ] Task\n  \(photo)\n  \(file)\n- [ ] Next\n")
        // The file is an attachment, at its parent's level, when read back with the origin.
        XCTAssertEqual(
            parseEditorBlocks(recovered, serverOrigin: origin).map(\.kind),
            [
                .checklistItem(checked: false), .image(alt: "photo.png", url: imageURL),
                .attachment(name: "report.pdf", url: fileURL), .checklistItem(checked: false),
            ])
        XCTAssertEqual(parseEditorBlocks(recovered, serverOrigin: origin).map(\.indent), [0, 1, 1, 0])
    }

    /// The export pulls the item's later children up with the leaf; the tree puts them back.
    func testAListItemAfterTheLeafIsRestoredToo() {
        XCTAssertEqual(
            recover(
                "* [ ] Task\n\n\(photo)\n\n* [ ] Sub\n* [ ] Next\n",
                [check([image, check()]), check()]),
            "- [ ] Task\n  \(photo)\n  - [ ] Sub\n- [ ] Next\n")
    }

    func testEverySiblingAfterTheLeafIsRestored() {
        XCTAssertEqual(
            recover(
                "* [ ] T\n\n\(photo)\n\n* [ ] Sub\n* [ ] Sub2\n* [ ] Next\n",
                [check([image, check(), check()]), check()]),
            "- [ ] T\n  \(photo)\n  - [ ] Sub\n  - [ ] Sub2\n- [ ] Next\n")
    }

    func testAPhotoUnderANestedItem() {
        XCTAssertEqual(
            recover("* [ ] Task\n  * [ ] Sub\n\n\(photo)\n\n* [ ] Next\n", [check([check([image])]), check()]),
            "- [ ] Task\n  - [ ] Sub\n    \(photo)\n- [ ] Next\n")
    }

    func testASiblingOfTheLeafsParentIsRestored() {
        XCTAssertEqual(
            recover(
                "* [ ] A\n  * [ ] B\n\n\(photo)\n\n* [ ] C\n* [ ] D\n",
                [check([check([image]), check()]), check()]),
            "- [ ] A\n  - [ ] B\n    \(photo)\n  - [ ] C\n- [ ] D\n")
    }

    /// The export keeps the relative depth of a subtree after the break; the tree's absolute
    /// depth is what is restored.
    func testASubtreeAfterTheLeafKeepsItsShape() {
        XCTAssertEqual(
            recover(
                "* [ ] T\n\n\(photo)\n\n* [ ] Sub\n  * [ ] SubSub\n* [ ] Next\n",
                [check([image, check([check()])]), check()]),
            "- [ ] T\n  \(photo)\n  - [ ] Sub\n    - [ ] SubSub\n- [ ] Next\n")
    }

    /// The export restarts the numbering (`1. B`); the recovered list counts on past the photo.
    func testANumberedItem() {
        XCTAssertEqual(
            recover("1. A\n\n\(photo)\n\n1. B\n", [numbered([image]), numbered()]),
            "1. A\n   \(photo)\n2. B\n")
    }

    /// A file's caption exports as a paragraph after it; after the *last* child it simply
    /// stays a top-level paragraph.
    func testACaptionAfterTheLastChildStaysAParagraph() {
        XCTAssertEqual(
            recover(
                "* [ ] Task\n\n\(photo)\n\n\(file)\n\nCap\n\n* [ ] Next\n",
                [check([image, fileNode]), check()]),
            "- [ ] Task\n  \(photo)\n  \(file)\n\nCap\n\n- [ ] Next\n")
    }

    /// A docs `pdf` block exports as a link only with `showPreview: false`; with the default
    /// preview it exports nothing, so it is not matched against anything.
    func testAPreviewPdfIsSkippedAndALinkPdfAnchorsAsAFile() {
        let previewPdf = BlockNoteTreeNode(type: "pdf", url: fileURL, showPreview: true)
        let defaultPdf = BlockNoteTreeNode(type: "pdf", url: fileURL)
        let linkPdf = BlockNoteTreeNode(type: "pdf", url: fileURL, showPreview: false)

        for pdf in [previewPdf, defaultPdf] {
            XCTAssertEqual(
                recover("* [ ] Task\n\n\(photo)\n\n* [ ] Next\n", [check([pdf, image]), check()]),
                "- [ ] Task\n  \(photo)\n- [ ] Next\n")
        }
        XCTAssertEqual(
            recover("* [ ] Task\n\n\(file)\n\n* [ ] Next\n", [check([linkPdf]), check()]),
            "- [ ] Task\n  \(file)\n- [ ] Next\n")
    }

    // MARK: - Every doubt declines

    /// A caption *between* two children exports as a paragraph there, and the flat model has
    /// no way to nest the second child under the item past it.
    func testACaptionBetweenChildrenDeclines() {
        XCTAssertNil(
            recover(
                "* [ ] Task\n\n\(file)\n\nCap\n\n\(photo)\n\n* [ ] Next\n",
                [check([fileNode, image]), check()]))
    }

    func testALinkPdfTheMarkdownLacksDeclines() {
        let linkPdf = BlockNoteTreeNode(type: "pdf", url: fileURL, showPreview: false)
        XCTAssertNil(recover("* [ ] Task\n\n\(photo)\n\n* [ ] Next\n", [check([linkPdf, image]), check()]))
    }

    func testAnyMismatchBetweenTheTwoReadsDeclines() {
        let markdown = "* [ ] Task\n\n\(photo)\n\n* [ ] Next\n"
        let otherImage = BlockNoteTreeNode(type: "image", url: imageURL + "?v=2")
        XCTAssertNil(recover(markdown, [check([otherImage]), check()]), "a different url")
        XCTAssertNil(recover(markdown, [check([image])]), "a block the tree lacks")
        XCTAssertNil(recover(markdown, [check([image]), check(), check()]), "a block the markdown lacks")
        XCTAssertNil(
            recover(markdown, [BlockNoteTreeNode(type: "bulletListItem", children: [image]), check()]),
            "a different list kind")
    }

    /// A photo nested under a paragraph (or a heading, a toggle…) has no spelling in the
    /// editor's model.
    func testALeafUnderANonListParentDeclines() {
        XCTAssertNil(
            recover(
                "Para\n\n\(photo)\n\n* [ ] Next\n",
                [BlockNoteTreeNode(type: "paragraph", children: [image]), check()]))
    }

    /// The tree may only add structure the export lost — never contradict structure the
    /// markdown shows.
    func testATreeThatContradictsTheMarkdownsNestingDeclines() {
        XCTAssertNil(
            recover(
                "* a\n  * b\n\n\(photo)\n",
                [BlockNoteTreeNode(type: "bulletListItem"), BlockNoteTreeNode(type: "bulletListItem"), image]))
    }

    func testNothingToRestoreIsNil() {
        XCTAssertNil(recover("* [ ] Task\n\n\(photo)\n\n* [ ] Next\n", [check(), image, check()]))
    }

    /// Without the origin a file is a link-line paragraph, which is not an anchor — so the
    /// tree's file has nothing to match.
    func testAFileWithoutTheOriginDeclines() {
        XCTAssertNil(
            markdownRecoveringLeafNesting(
                "* [ ] Task\n\n\(file)\n\n* [ ] Next\n", tree: [check([fileNode]), check()], serverOrigin: ""))
    }

    /// A tree deeper than `maxListIndent` cannot be drawn, so it is not half-applied either.
    func testDeeperThanTheEditorNestsDeclines() {
        var tree = image
        for _ in 0...maxListIndent {
            tree = BlockNoteTreeNode(type: "bulletListItem", children: [tree])
        }
        let items = (0...maxListIndent).map { String(repeating: "  ", count: $0) + "* item" }
        XCTAssertNil(recover(items.joined(separator: "\n") + "\n\n\(photo)\n", [tree]))
    }

    // MARK: - The gate

    func testOnlyALeafDirectlyAfterAListItemMayHideNesting() {
        XCTAssertTrue(markdownMayHideLeafNesting("* [ ] Task\n\n\(photo)\n"))
        XCTAssertTrue(markdownMayHideLeafNesting("1. Step\n\n\(file)\n"))
        XCTAssertTrue(markdownMayHideLeafNesting("* a\n  * b\n\n\(photo)\n"))
        XCTAssertFalse(markdownMayHideLeafNesting("Para\n\n\(photo)\n"))
        XCTAssertFalse(markdownMayHideLeafNesting("\(photo)\n\n* [ ] Task\n"))
        XCTAssertFalse(markdownMayHideLeafNesting("* [ ] Task\n\nPara\n"))
        XCTAssertFalse(markdownMayHideLeafNesting("* [ ] Task\n* [ ] Next\n"))
        // Already nested: nothing hidden.
        XCTAssertFalse(markdownMayHideLeafNesting("- [ ] Task\n  \(photo)\n- [ ] Next\n"))
    }

    // MARK: - The export model

    /// Zeroing a leaf's indent and renormalizing re-attached the *second* sibling after it;
    /// the export restarts the whole run at the top. The comparisons have to agree with it,
    /// or the app's own push of such a document reads back as a server change.
    func testCanonicalMarkdownMatchesTheExportOfEverySiblingAfterALeaf() {
        let local = "- [ ] T\n  \(photo)\n  - [ ] Sub\n  - [ ] Sub2\n- [ ] Next\n"
        let export = "* [ ] T\n\n\(photo)\n\n* [ ] Sub\n* [ ] Sub2\n* [ ] Next\n"
        XCTAssertEqual(canonicalMarkdown(local), canonicalMarkdown(export))

        let deep = "- [ ] A\n  - [ ] B\n    \(photo)\n  - [ ] C\n- [ ] D\n  - [ ] E\n"
        let deepExport = "* [ ] A\n  * [ ] B\n\n\(photo)\n\n* [ ] C\n* [ ] D\n  * [ ] E\n"
        XCTAssertEqual(canonicalMarkdown(deep), canonicalMarkdown(deepExport))
    }

    func testTheExportModelLeavesADocumentWithoutNestedLeavesAlone() {
        let blocks = parseEditorBlocks("* a\n  * b\n    * c\n* d\n\n\(photo)\n\nText\n")
        XCTAssertEqual(flattenedLikeServerExport(blocks), blocks)
    }

    // MARK: - Revealing restored nesting over a flat screen

    func testOnlyAFetchThatNestsALeafRevealsNesting() {
        let nested = "- [ ] Task\n  \(photo)\n- [ ] Next\n"
        let flat = "* [ ] Task\n\n\(photo)\n\n* [ ] Next\n"
        XCTAssertTrue(fetchedMarkdownRevealsLeafNesting(nested, over: flat))
        XCTAssertFalse(fetchedMarkdownRevealsLeafNesting(flat, over: nested), "a flat read never un-nests")
        XCTAssertFalse(fetchedMarkdownRevealsLeafNesting(nested, over: nested))
        XCTAssertFalse(
            fetchedMarkdownRevealsLeafNesting(nested, over: nested.replacingOccurrences(of: "- ", with: "* ")))
    }
}
