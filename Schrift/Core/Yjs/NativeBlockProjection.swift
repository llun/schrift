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
            depth: depth, parentHandle: parent)
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
    /// classic shadow scrubs them. `nil` when the document has no total shadow.
    static func markdownShadow(_ doc: YDoc) -> String? {
        let tree = project(doc, nativeMarks: false)
        // A flat document keeps exactly the classic shadow.
        guard tree.blocks.contains(where: { $0.depth > 0 }) else {
            return YBlockProjection.projectedMarkdown(YBlockProjection.project(doc))
        }
        let document = ProjectedDocument(
            blocks: tree.blocks.map(\.block), isFullyRenderable: tree.isFullyRenderable,
            isFullyModeled: tree.isFullyModeled)
        return YBlockProjection.projectedMarkdown(document, indents: tree.blocks.map(\.depth))
            ?? YBlockProjection.projectedMarkdown(document)
    }
}
