import XCTest

@testable import Schrift

/// The native save's Markdown shadow becomes `lastPushedMarkdown`, which
/// `draftSyncDecision` compares (`canonicalMarkdown`) with the server's
/// Markdown export. For a nested list the two must agree, or every save of a
/// nested document reads as a conflict.
@MainActor
final class NativeShadowExportParityTests: DocumentEngineTestCase {
    /// The real capture of the test document (`.review/`, not committed): its
    /// raw Yjs state and the server's formatted-content export. The whole
    /// document has no total shadow (tables, callouts, media), so the list
    /// blocks are compared: every root list block and its subtree from the
    /// state, against the export's list items. Skipped where the capture is absent.
    func testTheRealCapturesNestedListsMatchTheServerExport() throws {
        let review = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".review")
        guard let state = try? Data(contentsOf: review.appendingPathComponent("state.bin")),
            let formatted = try? Data(contentsOf: review.appendingPathComponent("formatted.json")),
            let export = (try JSONSerialization.jsonObject(with: formatted) as? [String: Any])?["content"] as? String
        else { throw XCTSkip("no .review capture") }
        let doc = YDoc(clientID: 7, gc: true)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(state))
        let lists: Set<String> = ["bulletListItem", "numberedListItem", "checkListItem"]
        let tree = NativeBlockProjection.project(doc)
        XCTAssertTrue(tree.blocks.contains { $0.depth > 1 }, "the capture holds third-level lists")
        // Keep the root list blocks (with their subtrees); drop the rest.
        let root = try XCTUnwrap(doc.share[BlockNoteYjs.fragmentField])
        guard case .type(let group)? = YBlockProjection.children(of: root, includeFormats: false).first?.content
        else { return XCTFail("no root group") }
        let dropped = YBlockProjection.children(of: group, includeFormats: false).filter {
            !lists.contains(YBlockProjection.projectBlock($0, nestedChildren: true).node)
        }
        try doc.transact { tx in for item in dropped { item.delete(tx) } }
        let kept = NativeBlockProjection.project(doc).blocks
        XCTAssertTrue(kept.allSatisfy { lists.contains($0.block.node) }, "lists nest only lists here")
        let shadow = try XCTUnwrap(NativeBlockProjection.markdownShadow(doc))
        // The export's list items, in order, minus a toggle list item's subtree
        // (a different block the projection keeps opaque).
        let texts = Set(kept.map { $0.block.runs.map(\.text).joined() })
        let exported = parseEditorBlocks(export).filter { blockIsListItem($0.kind) && texts.contains($0.text) }
        XCTAssertEqual(exported.count, kept.count, "every list item is in the export")
        XCTAssertEqual(parseEditorBlocks(shadow).map(\.indent), exported.map(\.indent), "the same nesting")
        XCTAssertEqual(canonicalMarkdown(shadow), canonicalMarkdown(serializeMarkdown(exported)))
    }

    /// The export's own nested-list spelling (copied from that capture's
    /// formatted content) against blocks of the same shape.
    func testNestedListSpellingMatchesTheServerExport() throws {
        func item(_ node: String, _ id: String, _ text: String, _ children: [BlockNoteBlock] = []) -> BlockNoteBlock {
            let extra: [(key: String, value: YAnyValue)] =
                node == "checkListItem"
                ? [("checked", .bool(text.hasPrefix("Checked")))]
                : node == "numberedListItem" ? [("start", .undefined)] : []
            return BlockNoteBlock(
                node: node, props: Self.paragraphProps + extra, runs: [InlineRun(text)], id: id, children: children)
        }
        let doc = try makeDoc(
            [
                item(
                    "bulletListItem", "b1", "Bullet item",
                    [
                        item(
                            "bulletListItem", "b2", "Nested bullet",
                            [item("bulletListItem", "b3", "Third-level bullet")])
                    ]),
                item(
                    "numberedListItem", "n1", "Numbered item",
                    [
                        item(
                            "numberedListItem", "n2", "Nested numbered",
                            [item("numberedListItem", "n3", "Third-level numbered")])
                    ]),
                item("numberedListItem", "n4", "Item two"),
                item(
                    "checkListItem", "c1", "Unchecked task",
                    [item("checkListItem", "c2", "Nested task", [item("checkListItem", "c3", "Third-level task")])]),
                item("checkListItem", "c4", "Checked task"),
            ], clientID: 1)
        defer { doc.destroy() }
        let export = """
            * Bullet item
              * Nested bullet
                * Third-level bullet

            1. Numbered item
               1. Nested numbered
                  1. Third-level numbered
            2. Item two

            * [ ] Unchecked task
              * [ ] Nested task
                * [ ] Third-level task
            * [x] Checked task

            """
        let shadow = try XCTUnwrap(NativeBlockProjection.markdownShadow(doc))
        XCTAssertEqual(canonicalMarkdown(shadow), canonicalMarkdown(export))
        XCTAssertEqual(parseEditorBlocks(shadow).map(\.indent), [0, 1, 2, 0, 1, 2, 0, 0, 1, 2, 0])
    }
}
