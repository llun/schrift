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
        walk(
            group, depth: 0, parent: nil, generation: generation, interlinkingOrigin: interlinkingOrigin,
            nativeMarks: nativeMarks, seen: &seen, into: &blocks)
        let renderable = blocks.allSatisfy { !$0.block.fidelity.isOpaque }
        let modeled = renderable && blocks.allSatisfy { $0.block.fidelity == .modeled }
        return (blocks, renderable, modeled)
    }

    /// The preorder walk of `group`'s blocks (a `blockGroup`, or a `column`,
    /// whose children are containers too: PR12a).
    private static func walk(
        _ group: YType, depth: Int, parent: NativeBlockHandle?, generation: UUID, interlinkingOrigin: String?,
        nativeMarks: Bool, seen: inout Set<String>, into blocks: inout [NativeBlockSnapshot]
    ) {
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
            walk(
                nested, depth: depth + 1, parent: snapshot.handle, generation: generation,
                interlinkingOrigin: interlinkingOrigin, nativeMarks: nativeMarks, seen: &seen, into: &blocks)
        }
    }

    /// A column's blocks (PR12a), in preorder, each at its depth below the
    /// column (its top-level blocks are depth 0, with no parent): what a
    /// column surface shows and what the shadow spells per column.
    static func columnBlocks(
        _ column: YType, generation: UUID = UUID(), interlinkingOrigin: String? = nil, nativeMarks: Bool = true
    ) -> [NativeBlockSnapshot] {
        var blocks: [NativeBlockSnapshot] = []
        var seen: Set<String> = []
        walk(
            column, depth: 0, parent: nil, generation: generation, interlinkingOrigin: interlinkingOrigin,
            nativeMarks: nativeMarks, seen: &seen, into: &blocks)
        return blocks
    }

    /// One block, as `project` reads it at `depth` under `parent`: the
    /// engine's per-block snapshot. O(block); a column group, O(group).
    static func projectBlock(
        _ item: YItem, depth: Int, parent: NativeBlockHandle?, generation: UUID,
        interlinkingOrigin: String? = nil, nativeMarks: Bool = true
    ) -> NativeBlockSnapshot {
        var block = YBlockProjection.projectBlock(
            item, interlinkingOrigin: interlinkingOrigin, nativeMarks: nativeMarks, nestedChildren: true)
        if depth >= maxDepth, case .type(let container) = item.content, nestedGroup(of: container) != nil {
            block = ProjectedBlock(id: block.id, node: "", props: [], runs: [], fidelity: .opaque(reason: "nesting"))
        }
        // A familiar column group (PR12a) whose every block the native
        // projection models is modeled by it: its blocks are the column
        // editor's, and the save shadow spells it as the export does. The
        // classic projection keeps it opaque.
        if nativeMarks, block.node == "columnList", case .type(let list) = item.content {
            block.fidelity = columnFidelity(list, id: block.id, generation: generation)
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
    /// export's own Markdown (`NativeExportMarkdown`), as is one holding edge
    /// whitespace the classic rendering would trim (`hasEdgeWhitespace`), so
    /// a trailing space just typed always has a shadow. `nil` when the
    /// document has no total shadow.
    static func markdownShadow(_ doc: YDoc) -> String? {
        let tree = project(doc, nativeMarks: false)
        // A flat document with no native-only block keeps exactly the classic shadow.
        guard
            tree.blocks.contains(where: {
                $0.depth > 0 || $0.block.node == "table" || $0.block.node == "columnList"
                    || nativeOnlyReasons.contains(opaqueReason($0.block)) || hasEdgeWhitespace($0.block)
            })
        else {
            return YBlockProjection.projectedMarkdown(YBlockProjection.project(doc))
        }
        return spell(tree.blocks[...], items: rootItems(doc), allowsColumns: true)
    }

    /// The shadow of a run of root subtrees (the document's, or one column's,
    /// PR12a): classic segments, each table and export-only subtree as the
    /// export's own chunk, joined as the export joins root blocks. `items`
    /// holds the run's top-level containers by item id (a table's grid and a
    /// group's columns are read from them).
    private static func spell(
        _ blocks: ArraySlice<NativeBlockSnapshot>, items: [YID: YItem], allowsColumns: Bool
    ) -> String? {
        var parts: [String] = []
        var plain = blocks.startIndex  // the first block not yet spelled
        var root = blocks.startIndex
        while root < blocks.endIndex {
            var end = root + 1
            while end < blocks.endIndex, blocks[end].depth > 0 { end += 1 }
            if blocks[root].block.node == "table" {
                // A root table without children: the export's own grid (PR11a).
                guard end == root + 1, let item = items[blocks[root].handle.itemID],
                    let grid = tableGrid(of: item), let before = classicSpelling(blocks[plain..<root]),
                    let chunk = NativeExportMarkdown.table(grid)
                else { return nil }
                parts += [before, chunk]
                plain = end
            } else if blocks[root].block.node == "columnList" {
                // A root column group (PR12a): the export prints its column
                // frames transparently, so it is each column's blocks spelled
                // as root blocks, column after column, lists restarting at
                // each column. No group inside a column.
                guard allowsColumns, end == root + 1, let item = items[blocks[root].handle.itemID],
                    case .type(let list) = item.content,
                    ColumnGroup.read(list, id: blocks[root].id).isFamiliar,
                    let before = classicSpelling(blocks[plain..<root])
                else { return nil }
                var columns: [String] = []
                for column in ColumnGroup.columnTypes(of: list) {
                    var columnItems: [YID: YItem] = [:]
                    for child in YBlockProjection.children(of: column, includeFormats: false) {
                        columnItems[child.id] = child
                    }
                    let snapshots = columnBlocks(column, nativeMarks: false)
                    guard let spelled = spell(snapshots[...], items: columnItems, allowsColumns: false) else {
                        return nil
                    }
                    columns.append(spelled)
                }
                parts += [before] + columns
                plain = end
            } else if case let subtree = blocks[root..<end],
                needsExport(subtree) || subtree.contains(where: { hasEdgeWhitespace($0.block) })
            {
                // Edge whitespace falls back to the classic rendering only for a block the port lacks.
                // Edge whitespace never takes a shadow away: last, the classic
                // rendering with it trimmed, as the conflict comparison reads it.
                guard let before = classicSpelling(blocks[plain..<root]),
                    let chunk = exportNodes(subtree).flatMap(NativeExportMarkdown.body)
                        ?? (needsExport(subtree)
                            ? nil : classicSpelling(subtree) ?? classicSpelling(edgeTrimmed(subtree)))
                else { return nil }
                parts += [before, chunk]
                plain = end
            }
            root = end
        }
        guard let rest = classicSpelling(blocks[plain...]) else { return nil }
        guard !parts.isEmpty else { return rest }
        // The export separates root blocks by a blank line and trims only the
        // document's ends; a list split here only turns loose, which
        // `canonicalMarkdown` does not see.
        let spelled = (parts + [rest]).map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }
        return NativeExportMarkdown.trimmed(spelled.joined(separator: "\n\n"))
    }

    /// Whether the classic rendering cannot spell `block` like the export:
    /// text that starts or ends with whitespace (the classic re-parse trims
    /// `.whitespaces`, so its self-check refuses the block; the export's trim
    /// takes `jsWhitespace` off the document's ends), or a marked run that does
    /// (the export keeps that whitespace inside the delimiters, except the
    /// trailing part of bold and italic). A code block is verbatim either way.
    private static func hasEdgeWhitespace(_ block: ProjectedBlock) -> Bool {
        guard block.node != "codeBlock" else { return false }
        func edges(_ text: String) -> Bool {
            [text.unicodeScalars.first, text.unicodeScalars.last].contains { $0.map(edgeWhitespace.contains) == true }
        }
        return edges(block.runs.map(\.text).joined()) || block.runs.contains { !$0.marks.isEmpty && edges($0.text) }
    }

    private static let edgeWhitespace = CharacterSet.whitespaces.union(NativeExportMarkdown.jsWhitespace)

    /// The port's nodes for a root subtree. Outside the shapes `needsExport`
    /// sends there (where the port refuses callouts), a callout is the
    /// paragraph `exportSpelling` makes of it; `nil` for one it refuses.
    private static func exportNodes(_ subtree: ArraySlice<NativeBlockSnapshot>) -> [NativeExportMarkdown.Node]? {
        guard !needsExport(subtree) else { return NativeExportMarkdown.nodes(subtree) }
        var snapshots = Array(subtree)
        for index in snapshots.indices where opaqueReason(snapshots[index].block) == "unknownNode:callout" {
            guard let spelled = exportSpelling(snapshots[index...index])?.blocks.first else { return nil }
            snapshots[index].block = spelled
        }
        return NativeExportMarkdown.nodes(snapshots[...])
    }

    /// The subtree with each block's edge `.whitespaces` removed from its runs.
    private static func edgeTrimmed(_ subtree: ArraySlice<NativeBlockSnapshot>) -> ArraySlice<NativeBlockSnapshot> {
        func strip(_ text: String, leading: Bool) -> String {
            var scalars = Array(text.unicodeScalars)
            while let edge = leading ? scalars.first : scalars.last, CharacterSet.whitespaces.contains(edge) {
                if leading { scalars.removeFirst() } else { scalars.removeLast() }
            }
            return String(String.UnicodeScalarView(scalars))
        }
        return ArraySlice(
            subtree.map { snapshot in
                guard snapshot.block.node != "codeBlock" else { return snapshot }
                var snapshot = snapshot
                var runs = snapshot.block.runs
                while !runs.isEmpty {
                    runs[0].text = strip(runs[0].text, leading: true)
                    guard runs[0].text.isEmpty else { break }
                    runs.removeFirst()
                }
                while !runs.isEmpty {
                    runs[runs.count - 1].text = strip(runs[runs.count - 1].text, leading: false)
                    guard runs[runs.count - 1].text.isEmpty else { break }
                    runs.removeLast()
                }
                snapshot.block.runs = runs
                return snapshot
            })
    }

    /// A column group's native fidelity (PR12a): modeled when the group is
    /// familiar and the native projection models every block in it.
    private static func columnFidelity(_ list: YType, id: String, generation: UUID) -> ProjectionFidelity {
        let group = ColumnGroup.read(list, id: id)
        if case .unfamiliar(let reason) = group.familiarity { return .opaque(reason: "columnList: \(reason)") }
        for column in ColumnGroup.columnTypes(of: list)
        where !columnBlocks(column, generation: generation).allSatisfy({ $0.block.fidelity == .modeled }) {
            return .opaque(reason: "columnList: unmodeled block")
        }
        return .modeled
    }

    /// The root group's containers by item id (a table's grid is read from its item).
    private static func rootItems(_ doc: YDoc) -> [YID: YItem] {
        guard let root = doc.share[BlockNoteYjs.fragmentField],
            let groupItem = YBlockProjection.children(of: root, includeFormats: false).first,
            case .type(let group) = groupItem.content
        else { return [:] }
        var items: [YID: YItem] = [:]
        for item in YBlockProjection.children(of: group, includeFormats: false) { items[item.id] = item }
        return items
    }

    /// The grid a table block's shadow spells: its own when familiar; for a
    /// layout the web's `fixTables` would repair (a ragged row after a
    /// concurrent row and column change), the repaired one (PR11b), so a save
    /// meanwhile still has a shadow.
    static func tableGrid(of container: YItem) -> TableGrid? {
        guard case .type(let type) = container.content,
            let first = YBlockProjection.children(of: type, includeFormats: false).first,
            case .type(let table) = first.content, table.typeRef == .xmlElement(nodeName: "table")
        else { return nil }
        let grid = TableGrid.read(table)
        if case .unfamiliar(let reason) = grid.familiarity, TableGrid.layoutReasons.contains(reason) {
            return TableModel.fixedGrid(table)
        }
        return grid
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
