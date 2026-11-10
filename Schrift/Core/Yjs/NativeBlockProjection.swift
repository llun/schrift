import Foundation

/// The native tree projection: every block of the replica's
/// `blockGroup → blockContainer → blockGroup …` tree in preorder, each with its
/// depth, parent and handle. Each block reads exactly as the classic
/// per-block projection reads it (`YBlockProjection.projectBlock`), except
/// that a container holding its content element and one nested `blockGroup`
/// is no longer opaque: its children follow it, one level deeper.
///
/// Total and never-trapping, like the classic projection. A container with a
/// missing or repeated id is opaque and stands for its whole subtree (its
/// children are not projected), as is one nested deeper than `maxDepth`.
/// `BlockIndex` follows the same rules (`nestedGroup(of:)`), so the engine's
/// incremental patches converge to this projection.
enum NativeBlockProjection {
    /// The deepest block level projected (root blocks are depth 0). A block
    /// at this depth with children is opaque, so a hostile replica cannot
    /// recurse without bound; the writer never nests this deep
    /// (`BlockNoteWriter.maxNestingDepth`).
    static let maxDepth = 64

    static func project(
        _ doc: YDoc, generation: UUID = UUID(), interlinkingOrigin: String? = nil, nativeMarks: Bool = true
    ) -> (blocks: [NativeBlockSnapshot], isFullyRenderable: Bool, isFullyModeled: Bool) {
        guard let root = doc.share[BlockNoteYjs.fragmentField] else { return ([], true, true) }
        let rootChildren = YBlockProjection.children(of: root, includeFormats: false)
        if rootChildren.isEmpty { return ([], true, true) }
        guard rootChildren.count == 1, case .type(let group) = rootChildren[0].content,
            group.typeRef == .xmlElement(nodeName: "blockGroup")
        else { return ([], false, false) }
        var blocks: [NativeBlockSnapshot] = []
        var seen: Set<String> = []
        func walk(_ group: YType, depth: Int, parent: NativeBlockHandle?) {
            for item in YBlockProjection.children(of: group, includeFormats: false) {
                var snapshot = projectBlock(
                    item, depth: depth, parent: parent, generation: generation,
                    interlinkingOrigin: interlinkingOrigin, nativeMarks: nativeMarks)
                // Only the first of a repeated id is addressable; an id-less or
                // repeated container stands for its subtree.
                let unique = !snapshot.id.isEmpty && seen.insert(snapshot.id).inserted
                if !unique, !snapshot.block.fidelity.isOpaque {
                    snapshot.block = ProjectedBlock(
                        id: snapshot.id, node: "", props: [], runs: [],
                        fidelity: .opaque(reason: snapshot.id.isEmpty ? "missing block id" : "duplicate block id"))
                    snapshot.preview = .preserved(node: "", summary: "")
                }
                blocks.append(snapshot)
                guard unique, depth < maxDepth, case .type(let container) = item.content,
                    let nested = nestedGroup(of: container)
                else { continue }
                walk(nested, depth: depth + 1, parent: snapshot.handle)
            }
        }
        walk(group, depth: 0, parent: nil)
        let renderable = blocks.allSatisfy { !$0.block.fidelity.isOpaque }
        let modeled = renderable && blocks.allSatisfy { $0.block.fidelity == .modeled }
        return (blocks, renderable, modeled)
    }

    /// One block, as `project` reads it at `depth` under `parent`: the
    /// engine's per-block snapshot. O(block).
    static func projectBlock(
        _ item: YItem, depth: Int, parent: NativeBlockHandle?, generation: UUID,
        interlinkingOrigin: String? = nil, nativeMarks: Bool = true
    ) -> NativeBlockSnapshot {
        var block = YBlockProjection.projectBlock(
            item, interlinkingOrigin: interlinkingOrigin, nativeMarks: nativeMarks, nestedChildren: true)
        if depth >= maxDepth, case .type(let container) = item.content, nestedGroup(of: container) != nil {
            block = ProjectedBlock(id: block.id, node: "", props: [], runs: [], fidelity: .opaque(reason: "nesting"))
        }
        return NativeBlockSnapshot(
            handle: NativeBlockHandle(generation: generation, itemID: item.id, stringID: block.id), block: block,
            depth: depth, parentHandle: parent, preview: NativeBlockPreview.read(item, block: block))
    }

    /// The nested `blockGroup` the tree descends into: only a container whose
    /// countable children are exactly its content element and that group.
    /// Any other shape is the classic projection's opaque container.
    static func nestedGroup(of container: YType) -> YType? {
        let children = YBlockProjection.children(of: container, includeFormats: false)
        guard children.count == 2, case .type(let element) = children[0].content,
            element.typeRef != .xmlElement(nodeName: "blockGroup"), case .xmlElement = element.typeRef,
            case .type(let group) = children[1].content, group.typeRef == .xmlElement(nodeName: "blockGroup")
        else { return nil }
        return group
    }

    /// The native save's Markdown shadow (`ReplicaSaveAdapter`, `canType`): a
    /// flat document's classic shadow; for a tree, the classic rendering of
    /// its blocks, each indented to its depth (Markdown keeps only list
    /// nesting; other nesting reads flat), else flat. Marks are scrubbed as the
    /// classic shadow scrubs them. Blocks only the native editor models take
    /// the server export's spelling (`exportSpelling`), and a root subtree the
    /// classic rendering cannot spell like the export (`needsExport`) is the
    /// export's own Markdown (`NativeExportMarkdown`). `nil` when the document
    /// has no total shadow.
    static func markdownShadow(_ doc: YDoc) -> String? {
        let tree = project(doc, nativeMarks: false)
        // A flat document with no native-only block keeps exactly the classic shadow.
        guard tree.blocks.contains(where: { $0.depth > 0 || nativeOnlyReasons.contains(opaqueReason($0.block)) })
        else {
            return YBlockProjection.projectedMarkdown(YBlockProjection.project(doc))
        }
        let blocks = tree.blocks
        var parts: [String] = []
        var plain = blocks.startIndex  // the first block not yet spelled
        var root = blocks.startIndex
        while root < blocks.endIndex {
            var end = root + 1
            while end < blocks.endIndex, blocks[end].depth > 0 { end += 1 }
            if needsExport(blocks[root..<end]) {
                guard let before = classicSpelling(blocks[plain..<root]),
                    let chunk = NativeExportMarkdown.markdown(NativeExportMarkdown.nodes(blocks[root..<end]))
                else { return nil }
                parts += [before, chunk]
                plain = end
            }
            root = end
        }
        guard let rest = classicSpelling(blocks[plain...]) else { return nil }
        guard !parts.isEmpty else { return rest }
        // The export separates root blocks by a blank line; a list split here
        // only turns loose, which `canonicalMarkdown` does not see.
        let spelled = (parts + [rest]).map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }
        return spelled.joined(separator: "\n\n") + "\n"
    }

    /// The classic rendering of a run of root subtrees, native-only blocks
    /// rewritten (`exportSpelling`).
    private static func classicSpelling(_ snapshots: ArraySlice<NativeBlockSnapshot>) -> String? {
        guard let (blocks, indents) = exportSpelling(snapshots) else { return nil }
        let document = ProjectedDocument(
            blocks: blocks, isFullyRenderable: blocks.allSatisfy { !$0.fidelity.isOpaque }, isFullyModeled: false)
        guard indents.contains(where: { $0 > 0 }) else { return YBlockProjection.projectedMarkdown(document) }
        return YBlockProjection.projectedMarkdown(document, indents: indents)
            ?? YBlockProjection.projectedMarkdown(document)
    }

    /// Whether the export spells this subtree in a way the classic rendering
    /// cannot: a toggle list item with a non-list descendant (the export
    /// indents it as a continuation paragraph and moves it ahead of the list
    /// children), or a callout or page break with children. A callout in
    /// such a subtree has no shadow (`NativeExportMarkdown`): it is Schrift's
    /// own block, and the server's export of it there is unknown.
    private static func needsExport(_ subtree: ArraySlice<NativeBlockSnapshot>) -> Bool {
        let lists: Set<String> = ["bulletListItem", "numberedListItem", "checkListItem", "toggleListItem"]
        return subtree.indices.contains { index in
            let snapshot = subtree[index]
            let descendants = subtree[(index + 1)...].prefix { $0.depth > snapshot.depth }
            switch opaqueReason(snapshot.block) {
            case "unknownNode:toggleListItem": return descendants.contains { !lists.contains($0.block.node) }
            case "unknownNode:callout", "unknownNode:pageBreak": return !descendants.isEmpty
            default: return false
            }
        }
    }

    /// The classic projection's opaque reasons for the blocks the native
    /// projection models (PR05b, PR06b).
    private static let nativeOnlyReasons: Set<String?> = [
        "unknownNode:callout", "unknownNode:toggleListItem", "unknownNode:pageBreak", "toggleable heading",
    ]

    private static func opaqueReason(_ block: ProjectedBlock) -> String? {
        if case .opaque(let reason) = block.fidelity { return reason }
        return nil
    }

    /// The classic tree rewritten the way the server's Markdown export
    /// (BlockNote's `blocksToMarkdownLossy`) spells the native-only blocks, as
    /// the real capture shows (`NativeShadowExportParityTests`): a callout is a
    /// paragraph with its emoji in front, a toggle list item a bullet, a
    /// toggle heading a plain heading, and a page break is dropped. Lossy like
    /// the export; the raw Yjs save still carries the real block. Shapes this
    /// cannot spell go to `NativeExportMarkdown` (`needsExport`). `nil` for a
    /// callout without a non-empty string emoji.
    private static func exportSpelling(_ tree: ArraySlice<NativeBlockSnapshot>) -> (
        blocks: [ProjectedBlock], indents: [Int]
    )? {
        var blocks: [ProjectedBlock] = []
        var indents: [Int] = []
        for snapshot in tree {
            var block = snapshot.block
            switch opaqueReason(block) {
            case "unknownNode:pageBreak":
                guard block.runs.isEmpty else { return nil }
                continue
            case "unknownNode:toggleListItem":
                block.node = "bulletListItem"
                block.fidelity = .lossy(reasons: ["toggleListItem"])
            case "toggleable heading":
                block.fidelity = .lossy(reasons: ["prop:isToggleable"])
            case "unknownNode:callout":
                guard case .string(let emoji)? = block.props.first(where: { $0.key == "emoji" })?.value,
                    !emoji.isEmpty
                else { return nil }
                let empty = block.runs.allSatisfy(\.text.isEmpty)
                block.node = "paragraph"
                block.runs = empty ? [InlineRun(emoji)] : [InlineRun(emoji + " ")] + block.runs
                block.fidelity = .lossy(reasons: ["callout"])
            default:
                break
            }
            blocks.append(block)
            indents.append(snapshot.depth)
        }
        return (blocks, indents)
    }
}
