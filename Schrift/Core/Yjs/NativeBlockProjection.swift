import Foundation

/// The first offending block and reason computed by `NativeBlockProjection` when a
/// document cannot be authored natively (`canType == false`). Contains only schema
/// metadata — never document text.
struct NativeUnfamiliarBlock: Equatable, Sendable {
    let node: String
    let reason: String
}

/// The native editor's one typability rule (PR02): whether a document can be
/// authored natively, and the first reason it cannot. `canType` is true when
/// the root shape is canonical, there is no unsupported auxiliary root, every
/// block id is addressable, no opaque block is anything but a locked card, and
/// the blocks Markdown can spell — every block but the locked cards — have a
/// total shadow. A locked card is a leaf block of an unknown type: it never
/// makes the document read-only, and no native edit touches it. A `.lossy`
/// block never makes the document read-only either: a styled-only block (known
/// styling props `textColor`, `backgroundColor`, `textAlignment`) keeps full
/// editing except merges, while any other `.lossy` block (unknown prop,
/// non-styling prop or unknown mark) is a locked *text* block that takes text,
/// marks and its own schema props and refuses split, convert, merge and move.
/// Any other opaque block (one with children, a column group, a known node
/// read as opaque, a block cut at the depth bound) keeps the whole document
/// read-only.
struct NativeTypability: Equatable, Sendable {
    let canType: Bool
    let unfamiliarContent: NativeUnfamiliarBlock?
}

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
    /// The native tree projection's result: every block in preorder, and the
    /// two document-level flags the classic projection also reports.
    typealias Projection = (blocks: [NativeBlockSnapshot], isFullyRenderable: Bool, isFullyModeled: Bool)

    /// The deepest block level projected (root blocks are depth 0). A block
    /// at this depth with children is opaque, so a hostile replica cannot
    /// recurse without bound; the writer never nests this deep
    /// (`BlockNoteWriter.maxNestingDepth`).
    static let maxDepth = 64

    static let maxBroadcastItemsPerRoot = 10_000
    static let maxBroadcastItemUTF8Bytes = 256
    static let maxBroadcastRoots = 8
    static let broadcastItemPrefix = "broadcast: "

    /// Whether `name` / `type` is the Docs web app's auxiliary broadcast root
    /// (`doc-<UUID>`, a `Y.Array` or untyped wire root holding at most
    /// `maxBroadcastItemsPerRoot` undeleted string items, each starting with
    /// `"broadcast: "` and at most `maxBroadcastItemUTF8Bytes` UTF-8 bytes).
    /// Preserved byte for byte and never written, ignored by native
    /// familiarity and save-shadow checks.
    static func isKnownAuxiliaryRoot(name: String, type: YType) -> Bool {
        guard name.hasPrefix("doc-"), name.utf8.count == 40 else { return false }
        let uuidPart = String(name.dropFirst(4))
        guard uuidPart.count == 36, UUID(uuidString: uuidPart) != nil else { return false }
        guard type.typeRef == nil || type.typeRef == .array, !type.isText, type.map.isEmpty else {
            return false
        }
        guard type.length <= UInt(maxBroadcastItemsPerRoot) else { return false }
        var itemCount = 0
        var item = type.start
        while let current = item {
            item = current.right
            guard !current.deleted else { continue }
            guard case .any(let values) = current.content else { return false }
            itemCount += values.count
            if itemCount > maxBroadcastItemsPerRoot { return false }
            for value in values {
                guard case .string(let text) = value,
                    text.hasPrefix(broadcastItemPrefix),
                    text.utf8.count <= maxBroadcastItemUTF8Bytes
                else { return false }
            }
        }
        return true
    }

    /// True when `doc.share` contains any top-level root other than
    /// `document-store` and at most `maxBroadcastRoots` known `doc-<UUID>`
    /// broadcast arrays.
    static func hasUnsupportedAuxiliaryRoot(_ doc: YDoc) -> Bool {
        var knownAuxiliaryRoots = 0
        for (name, type) in doc.share {
            if name == BlockNoteYjs.fragmentField { continue }
            guard knownAuxiliaryRoots < maxBroadcastRoots, isKnownAuxiliaryRoot(name: name, type: type) else {
                return true
            }
            knownAuxiliaryRoots += 1
        }
        return false
    }

    static func project(
        _ doc: YDoc, generation: UUID = UUID(), interlinkingOrigin: String? = nil, nativeMarks: Bool = true,
        inlineObjects: Bool = false
    ) -> Projection {
        let hasBadExtraRoot = hasUnsupportedAuxiliaryRoot(doc)
        guard let root = doc.share[BlockNoteYjs.fragmentField] else {
            return ([], !hasBadExtraRoot, !hasBadExtraRoot)
        }
        let rootChildren = YBlockProjection.children(of: root, includeFormats: false)
        if rootChildren.isEmpty {
            return ([], !hasBadExtraRoot, !hasBadExtraRoot)
        }
        guard rootChildren.count == 1, case .type(let group) = rootChildren[0].content,
            group.typeRef == .xmlElement(nodeName: "blockGroup")
        else { return ([], false, false) }
        var blocks: [NativeBlockSnapshot] = []
        var seen: Set<String> = []
        walk(
            group, depth: 0, parent: nil, generation: generation, interlinkingOrigin: interlinkingOrigin,
            nativeMarks: nativeMarks, inlineObjects: inlineObjects, seen: &seen, into: &blocks)
        let renderable = blocks.allSatisfy { !$0.block.fidelity.isOpaque }
        let modeled = renderable && blocks.allSatisfy { $0.block.fidelity == .modeled } && !hasBadExtraRoot
        return (blocks, renderable, modeled)
    }

    /// The preorder walk of `group`'s blocks (a `blockGroup`, or a `column`,
    /// whose children are containers too: PR12a).
    private static func walk(
        _ group: YType, depth: Int, parent: NativeBlockHandle?, generation: UUID, interlinkingOrigin: String?,
        nativeMarks: Bool, inlineObjects: Bool, seen: inout Set<String>, into blocks: inout [NativeBlockSnapshot]
    ) {
        for item in YBlockProjection.children(of: group, includeFormats: false) {
            var snapshot = projectBlock(
                item, depth: depth, parent: parent, generation: generation,
                interlinkingOrigin: interlinkingOrigin, nativeMarks: nativeMarks, inlineObjects: inlineObjects)
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
                interlinkingOrigin: interlinkingOrigin, nativeMarks: nativeMarks, inlineObjects: inlineObjects,
                seen: &seen, into: &blocks)
        }
    }

    /// A column's blocks (PR12a), in preorder, each at its depth below the
    /// column (its top-level blocks are depth 0, with no parent): what a
    /// column surface shows and what the shadow spells per column.
    static func columnBlocks(
        _ column: YType, generation: UUID = UUID(), interlinkingOrigin: String? = nil, nativeMarks: Bool = true,
        inlineObjects: Bool = false
    ) -> [NativeBlockSnapshot] {
        var blocks: [NativeBlockSnapshot] = []
        var seen: Set<String> = []
        walk(
            column, depth: 0, parent: nil, generation: generation, interlinkingOrigin: interlinkingOrigin,
            nativeMarks: nativeMarks, inlineObjects: inlineObjects, seen: &seen, into: &blocks)
        return blocks
    }

    /// One block, as `project` reads it at `depth` under `parent`: the
    /// engine's per-block snapshot. O(block); a column group, O(group).
    static func projectBlock(
        _ item: YItem, depth: Int, parent: NativeBlockHandle?, generation: UUID,
        interlinkingOrigin: String? = nil, nativeMarks: Bool = true, inlineObjects: Bool = false
    ) -> NativeBlockSnapshot {
        var block = YBlockProjection.projectBlock(
            item, interlinkingOrigin: interlinkingOrigin, nativeMarks: nativeMarks, nestedChildren: true,
            inlineObjects: inlineObjects)
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
    static func markdownShadow(_ doc: YDoc, interlinkingOrigin: String? = nil) -> String? {
        guard !hasUnsupportedAuxiliaryRoot(doc) else { return nil }
        let tree = project(doc, nativeMarks: false, inlineObjects: true)
        // A flat document with no native-only block or inline object keeps
        // exactly the classic shadow.
        guard
            tree.blocks.contains(where: {
                $0.depth > 0 || $0.block.node == "table" || $0.block.node == "columnList"
                    || MediaBlock.isMediaLike($0.block.node)
                    || SourceBlock.isSource($0.block.node)
                    || nativeOnlyReasons.contains(opaqueReason($0.block)) || hasEdgeWhitespace($0.block)
                    || hasInlineObject($0.block)
            })
        else {
            return YBlockProjection.projectedMarkdown(YBlockProjection.project(doc))
        }
        return spell(
            tree.blocks[...], items: rootItems(doc), containers: allContainerItems(doc), allowsColumns: true,
            interlinkingOrigin: interlinkingOrigin)
    }

    /// The save's Markdown shadow with the locked cards left out (PR02): the
    /// blocks Markdown can spell, in order, and nothing for the opaque ones —
    /// the blocks a native edit never touches. `nil` only when the remainder
    /// has no total shadow. `markdownShadow` itself is unchanged: it is `nil`
    /// for any opaque block, which its golden and oracle tests pin.
    static func markdownShadowIgnoringOpaque(_ doc: YDoc, interlinkingOrigin: String? = nil) -> String? {
        guard !hasUnsupportedAuxiliaryRoot(doc) else { return nil }
        return opaqueAwareShadow(doc, native: project(doc).blocks, interlinkingOrigin: interlinkingOrigin).shadow
    }

    /// The classic tree with the locked cards flagged, and the shadow of what
    /// is left. `native` is the native projection's blocks, whose opaque ones
    /// are the locked cards; the classic tree is projected once here so the
    /// shadow and the refusal that explains a missing one read the same walk.
    private static func opaqueAwareShadow(
        _ doc: YDoc, native: [NativeBlockSnapshot], interlinkingOrigin: String?
    ) -> (shadow: String?, tree: [NativeBlockSnapshot], locked: [Bool]) {
        // No locked card: the plain shadow, without a second tree walk (open and
        // save of a large document pay for every walk). The tree is built later
        // only if a refusal needs explaining.
        guard native.contains(where: { $0.block.fidelity.isOpaque }) else {
            return (markdownShadow(doc, interlinkingOrigin: interlinkingOrigin), [], [])
        }
        let tree = project(doc, nativeMarks: false, inlineObjects: true)
        let locked = lockedFlags(native, tree.blocks)
        guard locked.contains(true) else {
            return (markdownShadow(doc, interlinkingOrigin: interlinkingOrigin), tree.blocks, locked)
        }
        let shadow = spell(
            droppingLocked(tree.blocks, locked: locked)[...], items: rootItems(doc),
            containers: allContainerItems(doc), allowsColumns: true, interlinkingOrigin: interlinkingOrigin)
        return (shadow, tree.blocks, locked)
    }

    /// Which of `classic` are locked cards: the blocks the native projection
    /// reads as opaque. Both walks have the same shape (same items, order and
    /// depths), so the flags line up index for index; a shape mismatch locks
    /// nothing, which keeps the document read-only rather than guessing.
    private static func lockedFlags(_ native: [NativeBlockSnapshot], _ classic: [NativeBlockSnapshot]) -> [Bool] {
        guard native.count == classic.count else { return Array(repeating: false, count: classic.count) }
        return native.map { $0.block.fidelity.isOpaque }
    }

    /// `blocks` without the locked cards and their descendants.
    private static func droppingLocked(_ blocks: [NativeBlockSnapshot], locked: [Bool]) -> [NativeBlockSnapshot] {
        var kept: [NativeBlockSnapshot] = []
        kept.reserveCapacity(blocks.count)
        var skipDeeperThan: Int?
        for (index, snapshot) in blocks.enumerated() {
            if let depth = skipDeeperThan {
                if snapshot.depth > depth { continue }
                skipDeeperThan = nil
            }
            guard index < locked.count, locked[index] else {
                kept.append(snapshot)
                continue
            }
            skipDeeperThan = snapshot.depth
        }
        return kept
    }

    /// The save's Markdown shadow when the document has no total one: the
    /// blocks Markdown can spell, in order, and nothing for the rest (or, when
    /// even that subset cannot be rendered, every block's plain text). Never
    /// nil, so a capture never fails for lack of a shadow — a replica draft's
    /// markdown is only a fingerprint/display shadow, and the raw Yjs bytes
    /// are what the save sends. Deterministic: the same document always
    /// projects the same string.
    static func lossyMarkdownShadow(_ doc: YDoc, interlinkingOrigin: String? = nil) -> String {
        // The plain shadow first: a document without locked cards (the common case)
        // never pays for the card-aware walk on every save.
        if let total = markdownShadow(doc, interlinkingOrigin: interlinkingOrigin) { return total }
        if let total = markdownShadowIgnoringOpaque(doc, interlinkingOrigin: interlinkingOrigin) { return total }
        let tree = project(doc, nativeMarks: false, inlineObjects: true)
        let spellable = tree.blocks.filter { snapshot in
            !snapshot.block.fidelity.isOpaque
                && YBlockProjection.editorBlock(snapshot.block, escapeAll: false) != nil
        }
        let document = ProjectedDocument(
            blocks: spellable.map(\.block), isFullyRenderable: true, isFullyModeled: false)
        if let markdown = YBlockProjection.projectedMarkdown(document) { return markdown }
        // Last resort: every block's text, which Markdown cannot misread into
        // a different document (a block the classic rendering would trim, or
        // one it cannot spell at all, still contributes its text).
        return tree.blocks.map { $0.block.runs.map(\.text).joined() }.joined(separator: "\n\n")
    }

    /// The shadow of a run of root subtrees (the document's, or one column's,
    /// PR12a): classic segments, each table and export-only subtree as the
    /// export's own chunk, joined as the export joins root blocks. `items`
    /// holds the run's top-level containers by item id (a table's grid and a
    /// group's columns are read from them).
    private static func spell(
        _ blocks: ArraySlice<NativeBlockSnapshot>, items: [YID: YItem], containers: [YID: YItem],
        allowsColumns: Bool, interlinkingOrigin: String?
    ) -> String? {
        guard let stripped = stripFamiliarSources(blocks, containers: containers) else { return nil }
        var droppedAny = stripped.droppedAny
        let blocks = stripped.blocks[...]
        var parts: [String] = []
        var plain = blocks.startIndex  // the first block not yet spelled
        var root = blocks.startIndex
        while root < blocks.endIndex {
            var end = root + 1
            while end < blocks.endIndex, blocks[end].depth > 0 { end += 1 }
            // Media below the root or with children (PR13a): only the classic
            // projection's plain image line has a spelling (the export's
            // flattening there is unconfirmed).
            if blocks[root..<end].contains(where: {
                MediaBlock.isMediaLike($0.block.node) && $0.block.fidelity != .modeled
                    && ($0.depth > 0 || end > root + 1)
            }) {
                return nil
            }
            if MediaBlock.isMediaLike(blocks[root].block.node), end == root + 1 {
                // A root media block (PR13a): the export's own chunk, read
                // from its element (the classic projection keeps most media opaque).
                guard let item = items[blocks[root].handle.itemID], let element = contentElement(of: item),
                    let props = YBlockProjection.props(of: element),
                    MediaBlock.unfamiliarReason(
                        node: blocks[root].block.node, props: props, hasContent: hasContent(element)) == nil,
                    let before = classicSpelling(blocks[plain..<root]),
                    let chunk = NativeExportMarkdown.media(node: blocks[root].block.node, props: props)
                else { return nil }
                parts += [before, chunk]
                plain = end
            } else if blocks[root].block.node == "table" {
                // A root table without children: the export's own grid (PR11a).
                guard end == root + 1, let item = items[blocks[root].handle.itemID],
                    let grid = tableGrid(of: item), let before = classicSpelling(blocks[plain..<root]),
                    let chunk = NativeExportMarkdown.table(grid, interlinkingOrigin: interlinkingOrigin)
                else { return nil }
                parts += [before, chunk]
                plain = end
            } else if blocks[root].block.node == "columnList" {
                // A root column group (PR12a): the export prints its column
                // frames transparently, so it is each column's blocks spelled
                // as root blocks, column after column, lists restarting at
                // each column. No group inside a column. Columns emptied by
                // dropping familiar mathBlock/diagram nodes are omitted, and a
                // columnList left with <2 non-empty columns is dropped whole.
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
                    let snapshots = columnBlocks(column, nativeMarks: false, inlineObjects: true)
                    guard let columnStripped = stripFamiliarSources(snapshots[...], containers: containers) else {
                        return nil
                    }
                    if columnStripped.blocks.isEmpty {
                        droppedAny = true
                        continue
                    }
                    guard
                        let spelled = spell(
                            columnStripped.blocks[...], items: columnItems, containers: containers,
                            allowsColumns: false, interlinkingOrigin: interlinkingOrigin)
                    else {
                        return nil
                    }
                    columns.append(spelled)
                }
                if columns.count < 2 {
                    droppedAny = true
                    if !before.isEmpty { parts.append(before) }
                } else {
                    parts += [before] + columns
                }
                plain = end
            } else if case let subtree = blocks[root..<end],
                needsExport(subtree)
                    || subtree.contains(where: { hasEdgeWhitespace($0.block) || hasInlineObject($0.block) })
            {
                let requiresExport = needsExport(subtree) || subtree.contains { hasInlineObject($0.block) }
                // Edge whitespace falls back to the classic rendering only for a block the port lacks.
                // Edge whitespace never takes a shadow away: last, the classic
                // rendering with it trimmed, as the conflict comparison reads it.
                guard let before = classicSpelling(blocks[plain..<root]),
                    let chunk = exportNodes(subtree).flatMap({
                        NativeExportMarkdown.body($0, interlinkingOrigin: interlinkingOrigin)
                    })
                        ?? (requiresExport
                            ? nil : classicSpelling(subtree) ?? classicSpelling(edgeTrimmed(subtree)))
                else { return nil }
                parts += [before, chunk]
                plain = end
            }
            root = end
        }
        guard let rest = classicSpelling(blocks[plain...]) else { return nil }
        if parts.isEmpty { return (droppedAny && rest.isEmpty) ? "\n" : rest }
        // The export separates root blocks by a blank line and trims only the
        // document's ends; a list split here only turns loose, which
        // `canonicalMarkdown` does not see.
        let spelled = (parts + [rest]).map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }
        if spelled.isEmpty { return droppedAny ? "\n" : "" }
        return NativeExportMarkdown.trimmed(spelled.joined(separator: "\n\n"))
    }

    /// Drops familiar `mathBlock` and `diagram` subtrees (including any nested
    /// descendants, matching `y-provider`), returning `nil` if any encountered
    /// source block is unfamiliar.
    private static func stripFamiliarSources(
        _ blocks: ArraySlice<NativeBlockSnapshot>, containers: [YID: YItem]
    ) -> (blocks: [NativeBlockSnapshot], droppedAny: Bool)? {
        var kept: [NativeBlockSnapshot] = []
        kept.reserveCapacity(blocks.count)
        var droppedAny = false
        var index = blocks.startIndex
        while index < blocks.endIndex {
            let snapshot = blocks[index]
            if SourceBlock.isSource(snapshot.block.node) {
                guard let item = containers[snapshot.handle.itemID], let element = contentElement(of: item),
                    SourceBlock.isFamiliar(element)
                else { return nil }
                let depth = snapshot.depth
                index += 1
                while index < blocks.endIndex, blocks[index].depth > depth { index += 1 }
                droppedAny = true
                continue
            }
            kept.append(snapshot)
            index += 1
        }
        return (kept, droppedAny)
    }

    /// Every `blockContainer` item in `doc`, including nested and column-hosted
    /// containers, keyed by item id.
    private static func allContainerItems(_ doc: YDoc) -> [YID: YItem] {
        guard let root = doc.share[BlockNoteYjs.fragmentField],
            let groupItem = YBlockProjection.children(of: root, includeFormats: false).first,
            case .type(let rootGroup) = groupItem.content
        else { return [:] }
        var items: [YID: YItem] = [:]
        var stack: [YType] = [rootGroup]
        var visited: Set<ObjectIdentifier> = []
        while let current = stack.popLast() {
            guard visited.insert(ObjectIdentifier(current)).inserted else { continue }
            for item in YBlockProjection.children(of: current, includeFormats: false) {
                guard case .type(let type) = item.content, case .xmlElement(let name)? = type.typeRef else { continue }
                switch name {
                case "blockContainer":
                    items[item.id] = item
                    if let nested = nestedGroup(of: type) { stack.append(nested) }
                case "columnList", "column":
                    stack.append(type)
                default:
                    break
                }
            }
        }
        return items
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

    private static func hasInlineObject(_ block: ProjectedBlock) -> Bool {
        block.runs.contains { $0.inlineObject != nil }
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

    /// A container's content element (its first element child).
    private static func contentElement(of container: YItem) -> YType? {
        guard case .type(let type) = container.content,
            let first = YBlockProjection.children(of: type, includeFormats: false).first,
            case .type(let element) = first.content, case .xmlElement = element.typeRef
        else { return nil }
        return element
    }

    /// Whether an element holds anything but empty text (a media block holds
    /// nothing), as the projection's runs read it.
    private static func hasContent(_ element: YType) -> Bool {
        YBlockProjection.children(of: element, includeFormats: false).contains { child in
            guard case .type(let type) = child.content, type.typeRef == .xmlText else { return true }
            return YBlockProjection.textRuns(type).map { $0.contains { !$0.text.isEmpty } } ?? true
        }
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

    /// The native editor's one typability rule (PR02): whether `doc` can be
    /// authored natively, and the first reason it cannot. A leaf block of an
    /// unknown type is a locked card — it never makes the document read-only,
    /// and no native edit touches it — and a `.lossy` block (styled-only or
    /// locked text) never makes the document read-only either, so only a
    /// document-level unknown, an unaddressable id, any other opaque block, or
    /// a missing shadow of the remaining blocks stops authoring.
    static func typability(_ doc: YDoc, interlinkingOrigin: String? = nil) -> NativeTypability {
        typability(doc, projected: project(doc), interlinkingOrigin: interlinkingOrigin)
    }

    /// `typability` for a caller that already projected `doc`.
    static func typability(
        _ doc: YDoc, projected: Projection, interlinkingOrigin: String? = nil
    ) -> NativeTypability {
        guard
            let reason = firstUnsupportedReason(
                doc, projected: projected, interlinkingOrigin: interlinkingOrigin)
        else { return NativeTypability(canType: true, unfamiliarContent: nil) }
        return NativeTypability(canType: false, unfamiliarContent: reason)
    }

    /// Computes the first block type and reason why `doc` cannot be authored
    /// natively (`canType == false`), or `nil` when it can. Never returns
    /// document text. A locked card (a leaf block of an unknown type) is never
    /// a reason, and neither is a `.lossy` block (styled-only or locked text);
    /// any other opaque block is.
    static func firstUnsupportedReason(_ doc: YDoc, interlinkingOrigin: String? = nil) -> NativeUnfamiliarBlock? {
        firstUnsupportedReason(doc, projected: project(doc), interlinkingOrigin: interlinkingOrigin)
    }

    /// `firstUnsupportedReason` for a caller that already projected `doc`.
    static func firstUnsupportedReason(
        _ doc: YDoc, projected: Projection, interlinkingOrigin: String? = nil
    ) -> NativeUnfamiliarBlock? {
        if (projected.blocks.isEmpty && !projected.isFullyRenderable) || hasUnsupportedAuxiliaryRoot(doc) {
            return NativeUnfamiliarBlock(node: "", reason: "unsupported root")
        }
        // The engine addresses blocks by id; a missing or repeated one makes
        // every command refuse, so the surface must stay read-only.
        if let unaddressable = firstUnaddressableBlock(projected.blocks) { return unaddressable }
        // Only a leaf block of an unknown type is a locked card.
        if let unlockable = firstUnlockableOpaqueBlock(projected.blocks) { return unlockable }
        let shadow = opaqueAwareShadow(doc, native: projected.blocks, interlinkingOrigin: interlinkingOrigin)
        guard shadow.shadow == nil else { return nil }
        let tree = shadow.tree.isEmpty ? project(doc, nativeMarks: false, inlineObjects: true).blocks : shadow.tree
        let locked = shadow.locked.isEmpty ? Array(repeating: false, count: tree.count) : shadow.locked
        return firstShadowRefusal(
            tree, locked: locked, items: rootItems(doc), containers: allContainerItems(doc),
            allowsColumns: true, interlinkingOrigin: interlinkingOrigin)
            ?? NativeUnfamiliarBlock(node: tree.first?.block.node ?? "", reason: "unsupported markdown")
    }

    /// The first opaque block that cannot be a locked card. Only a leaf block
    /// of an unknown type is one (`unknownNode:`, and outside the payload's
    /// `contentNodes`): the engine's delete payload check refuses it, and it has no child blocks to move in or
    /// out. A known node read as opaque (a bad mark, a missing level), a block
    /// cut at the depth bound (its children unprojected), a container or one with
    /// children keeps the whole document read-only, as before PR02.
    private static func firstUnlockableOpaqueBlock(_ blocks: [NativeBlockSnapshot]) -> NativeUnfamiliarBlock? {
        for (index, snapshot) in blocks.enumerated() {
            guard case .opaque(let reason) = snapshot.block.fidelity else { continue }
            let hasChildren = index + 1 < blocks.count && blocks[index + 1].depth > snapshot.depth
            if !isLockedCard(node: snapshot.block.node, reason: reason, hasChildren: hasChildren) {
                return NativeUnfamiliarBlock(node: snapshot.block.node, reason: reason)
            }
        }
        return nil
    }

    /// Whether an opaque block is a locked card: a leaf block of an unknown
    /// type, outside the payload's `contentNodes` and never a column. The one
    /// definition the typability rule and the engine's delete check share.
    static func isLockedCard(node: String, reason: String, hasChildren: Bool) -> Bool {
        reason.hasPrefix("unknownNode:") && !BlockNoteSubtreePayload.contentNodes.contains(node)
            && !["columnList", "column"].contains(node) && !hasChildren
    }

    /// The first block the engine cannot address: an empty id, or one that
    /// repeats. `walk` already reads such a block as opaque and stops
    /// descending, so this matches `BlockIndex`'s addressable set.
    private static func firstUnaddressableBlock(_ blocks: [NativeBlockSnapshot]) -> NativeUnfamiliarBlock? {
        var seen: Set<String> = []
        for snapshot in blocks {
            if snapshot.id.isEmpty {
                return NativeUnfamiliarBlock(node: snapshot.block.node, reason: "missing block id")
            }
            if !seen.insert(snapshot.id).inserted {
                return NativeUnfamiliarBlock(node: snapshot.block.node, reason: "duplicate block id")
            }
        }
        return nil
    }

    /// `firstShadowRefusal` with the locked cards left out first: they are
    /// never a reason, and their subtrees are not spelled.
    private static func firstShadowRefusal(
        _ blocks: [NativeBlockSnapshot], locked: [Bool], items: [YID: YItem], containers: [YID: YItem],
        allowsColumns: Bool, interlinkingOrigin: String?
    ) -> NativeUnfamiliarBlock? {
        firstShadowRefusal(
            droppingLocked(blocks, locked: locked)[...], items: items, containers: containers,
            allowsColumns: allowsColumns, interlinkingOrigin: interlinkingOrigin)
    }

    private static func firstShadowRefusal(
        _ blocks: ArraySlice<NativeBlockSnapshot>, items: [YID: YItem], containers: [YID: YItem],
        allowsColumns: Bool, interlinkingOrigin: String?
    ) -> NativeUnfamiliarBlock? {
        for snapshot in blocks where SourceBlock.isSource(snapshot.block.node) {
            guard let item = containers[snapshot.handle.itemID], let element = contentElement(of: item) else {
                return NativeUnfamiliarBlock(node: snapshot.block.node, reason: "content")
            }
            if let props = YBlockProjection.props(of: element),
                let reason = SourceBlock.unfamiliarReason(
                    node: snapshot.block.node, props: props, element: element)
            {
                return NativeUnfamiliarBlock(node: snapshot.block.node, reason: reason)
            }
        }
        guard let stripped = stripFamiliarSources(blocks, containers: containers) else { return nil }
        let blocks = stripped.blocks[...]
        var plain = blocks.startIndex
        var root = blocks.startIndex
        while root < blocks.endIndex {
            var end = root + 1
            while end < blocks.endIndex, blocks[end].depth > 0 { end += 1 }
            if let badMedia = blocks[root..<end].first(where: {
                MediaBlock.isMediaLike($0.block.node) && $0.block.fidelity != .modeled
                    && ($0.depth > 0 || end > root + 1)
            }) {
                return NativeUnfamiliarBlock(
                    node: badMedia.block.node, reason: badMedia.depth > 0 ? "nested media" : "nested blocks")
            }
            if MediaBlock.isMediaLike(blocks[root].block.node), end == root + 1 {
                if classicSpelling(blocks[plain..<root]) == nil {
                    return firstClassicRefusal(blocks[plain..<root])
                }
                guard let item = items[blocks[root].handle.itemID], let element = contentElement(of: item),
                    let props = YBlockProjection.props(of: element)
                else {
                    return NativeUnfamiliarBlock(node: blocks[root].block.node, reason: "content")
                }
                if let reason = MediaBlock.unfamiliarReason(
                    node: blocks[root].block.node, props: props, hasContent: hasContent(element))
                {
                    return NativeUnfamiliarBlock(node: blocks[root].block.node, reason: reason)
                }
                if NativeExportMarkdown.media(node: blocks[root].block.node, props: props) == nil {
                    return NativeUnfamiliarBlock(node: blocks[root].block.node, reason: "unsupported URL")
                }
                plain = end
            } else if blocks[root].block.node == "table" {
                if end > root + 1 {
                    return NativeUnfamiliarBlock(node: "table", reason: "nested blocks")
                }
                if classicSpelling(blocks[plain..<root]) == nil {
                    return firstClassicRefusal(blocks[plain..<root])
                }
                guard let item = items[blocks[root].handle.itemID], let grid = tableGrid(of: item) else {
                    return NativeUnfamiliarBlock(node: "table", reason: "unsupported table")
                }
                if NativeExportMarkdown.table(grid, interlinkingOrigin: interlinkingOrigin) == nil {
                    return NativeUnfamiliarBlock(node: "table", reason: "unsupported table")
                }
                plain = end
            } else if blocks[root].block.node == "columnList" {
                if !allowsColumns {
                    return NativeUnfamiliarBlock(node: "columnList", reason: "nested column group")
                }
                if end > root + 1 {
                    return NativeUnfamiliarBlock(node: "columnList", reason: "nested blocks")
                }
                if classicSpelling(blocks[plain..<root]) == nil {
                    return firstClassicRefusal(blocks[plain..<root])
                }
                guard let item = items[blocks[root].handle.itemID], case .type(let list) = item.content else {
                    return NativeUnfamiliarBlock(node: "columnList", reason: "unsupported columns")
                }
                let group = ColumnGroup.read(list, id: blocks[root].id)
                if case .unfamiliar(let reason) = group.familiarity {
                    return NativeUnfamiliarBlock(node: "columnList", reason: reason)
                }
                for column in ColumnGroup.columnTypes(of: list) {
                    var columnItems: [YID: YItem] = [:]
                    for child in YBlockProjection.children(of: column, includeFormats: false) {
                        columnItems[child.id] = child
                    }
                    let snapshots = columnBlocks(column, nativeMarks: false, inlineObjects: true)
                    if let columnStripped = stripFamiliarSources(snapshots[...], containers: containers) {
                        if !columnStripped.blocks.isEmpty,
                            let refusal = firstShadowRefusal(
                                columnStripped.blocks[...], items: columnItems, containers: containers,
                                allowsColumns: false, interlinkingOrigin: interlinkingOrigin)
                        {
                            return refusal
                        }
                    } else if let refusal = firstShadowRefusal(
                        snapshots[...], items: columnItems, containers: containers,
                        allowsColumns: false, interlinkingOrigin: interlinkingOrigin)
                    {
                        return refusal
                    }
                }
                plain = end
            } else if case let subtree = blocks[root..<end],
                needsExport(subtree)
                    || subtree.contains(where: { hasEdgeWhitespace($0.block) || hasInlineObject($0.block) })
            {
                if classicSpelling(blocks[plain..<root]) == nil {
                    return firstClassicRefusal(blocks[plain..<root])
                }
                let requiresExport = needsExport(subtree) || subtree.contains { hasInlineObject($0.block) }
                let exported = exportNodes(subtree).flatMap {
                    NativeExportMarkdown.body($0, interlinkingOrigin: interlinkingOrigin)
                }
                if exported == nil {
                    if let calloutIndex = subtree.indices.first(where: { subtree[$0].block.node == "callout" }) {
                        let depth = subtree[calloutIndex].depth
                        let hasChildren = subtree[(calloutIndex + 1)...].first.map { $0.depth > depth } ?? false
                        return NativeUnfamiliarBlock(
                            node: "callout", reason: hasChildren ? "nested blocks" : "missing emoji")
                    }
                    if let missingOrigin = subtree.first(where: {
                        $0.block.runs.contains {
                            if case .interlink(let docID, _, _, let disabled, _)? = $0.inlineObject {
                                return !disabled && !docID.isEmpty && (interlinkingOrigin?.isEmpty ?? true)
                            }
                            return false
                        }
                    }) {
                        return NativeUnfamiliarBlock(node: missingOrigin.block.node, reason: "interlinkingLink")
                    }
                    if requiresExport {
                        return NativeUnfamiliarBlock(
                            node: subtree.first?.block.node ?? "",
                            reason: end > root + 1 ? "nested blocks" : "unsupported markdown")
                    }
                    if classicSpelling(subtree) == nil, classicSpelling(edgeTrimmed(subtree)) == nil {
                        return firstClassicRefusal(subtree)
                    }
                }
                plain = end
            }
            root = end
        }
        if classicSpelling(blocks[plain...]) == nil {
            return firstClassicRefusal(blocks[plain...])
        }
        return nil
    }

    private static func firstClassicRefusal(_ snapshots: ArraySlice<NativeBlockSnapshot>) -> NativeUnfamiliarBlock {
        for index in snapshots.indices {
            let snapshot = snapshots[index]
            guard let spelled = exportSpelling(snapshots[index...index])?.blocks.first else {
                return NativeUnfamiliarBlock(
                    node: snapshot.block.node,
                    reason: snapshot.block.node == "callout" ? "missing emoji" : "unsupported content")
            }
            if YBlockProjection.projectedMarkdown(
                ProjectedDocument(blocks: [spelled], isFullyRenderable: true, isFullyModeled: false)) == nil
            {
                return NativeUnfamiliarBlock(node: snapshot.block.node, reason: "unsupported markdown")
            }
        }
        return NativeUnfamiliarBlock(node: snapshots.first?.block.node ?? "", reason: "unsupported markdown")
    }
}
