import Foundation

/// A BlockNote 0.56 column group (`@blocknote/xl-multi-column`) read from the
/// replica (PR12a): a `columnList` sitting directly in a `blockGroup` (no
/// `blockContainer`), carrying its own `id`, holding `column` elements
/// (attributes `id` and `width`, BlockNote's default 1) that hold
/// `blockContainer`s directly (no `blockGroup`). Read-only: the native editor
/// writes a column's blocks through their own BlockNote ids, never through
/// this value.
///
/// **Familiar or not.** Only a group every part of which is understood is
/// `familiar`: at least two `column` children (the schema's `min: 2`), each
/// with a readable id and attributes and a width that is absent or a
/// positive finite number, each holding at least one container with a
/// readable, non-empty id unique in the group; no column group inside a
/// column (BlockNote excludes it); no deeper than the projection's depth
/// bound; at most `maxColumns` columns and `maxBlocks` blocks, counted before
/// anything is allocated per block. Anything else (the transient shapes
/// BlockNote's `fixLayoutBlocks` repairs on the web: an empty column, a group
/// of one) is `unfamiliar`: the group stays opaque, so nothing authors it and
/// its bytes stay as written.
struct ColumnGroup: Equatable, Sendable {
    struct Column: Equatable, Sendable {
        /// The column's BlockNote id.
        let id: String
        let itemID: YID
        /// `width` as stored: nil when unset (BlockNote's default, 1).
        var width: Double?
        /// The column's top-level block ids, in order.
        var blockIDs: [String]
    }

    enum Familiarity: Equatable, Sendable {
        case familiar
        case unfamiliar(String)
    }

    /// The group's own BlockNote id.
    var id: String
    var columns: [Column] = []
    /// Every block of the group, nested ones included.
    var blockCount = 0
    var familiarity: Familiarity = .familiar

    var isFamiliar: Bool { familiarity == .familiar }

    /// Columns the native editor opens (one text view each).
    static let maxColumns = 16
    /// Blocks the native editor indexes for one group.
    static let maxBlocks = 2_000

    /// Reads `list` (a `columnList` element). Total and never-trapping; the
    /// walk stops at the first refusal.
    static func read(_ list: YType, id: String) -> ColumnGroup {
        var group = ColumnGroup(id: id)
        func refuse(_ reason: String) -> ColumnGroup {
            group.familiarity = .unfamiliar(reason)
            return group
        }
        guard list.typeRef == .xmlElement(nodeName: "columnList") else { return refuse("not a column group") }
        guard YBlockProjection.props(of: list) != nil else { return refuse("unreadable group attribute") }
        var seen: Set<String> = []
        var seenColumns: Set<String> = []
        for columnItem in YBlockProjection.children(of: list, includeFormats: false) {
            guard group.columns.count < maxColumns else { return refuse("too many columns") }
            guard case .type(let column) = columnItem.content, column.typeRef == .xmlElement(nodeName: "column"),
                let columnID = BlockIndex.blockID(of: column), !columnID.isEmpty,
                let props = YBlockProjection.props(of: column)
            else { return refuse("unreadable column") }
            guard seenColumns.insert(columnID).inserted else { return refuse("duplicate column id") }
            var width: Double?
            if let value = props.first(where: { $0.key == "width" })?.value {
                guard let number = TableGrid.number(value), number > 0 else { return refuse("unreadable width") }
                width = number
            }
            var blockIDs: [String] = []
            for item in YBlockProjection.children(of: column, includeFormats: false) {
                guard case .type(let container) = item.content else { return refuse("unexpected column child") }
                if let reason = count(container, depth: 0, seen: &seen, group: &group) { return refuse(reason) }
                // `count` accepted it: a container with a readable id.
                if let blockID = BlockIndex.blockID(of: container) { blockIDs.append(blockID) }
            }
            guard !blockIDs.isEmpty else { return refuse("empty column") }
            group.columns.append(Column(id: columnID, itemID: columnItem.id, width: width, blockIDs: blockIDs))
        }
        guard group.columns.count >= 2 else { return refuse("fewer than two columns") }
        return group
    }

    /// Counts `container` and its descendants into `group`, or says why the
    /// group is unfamiliar.
    private static func count(_ container: YType, depth: Int, seen: inout Set<String>, group: inout ColumnGroup)
        -> String?
    {
        if container.typeRef == .xmlElement(nodeName: "columnList") { return "nested column group" }
        guard container.typeRef == .xmlElement(nodeName: "blockContainer") else { return "unexpected column child" }
        guard let blockID = BlockIndex.blockID(of: container), !blockID.isEmpty,
            !blockID.unicodeScalars.contains("\u{1}")
        else { return "missing block id" }
        guard seen.insert(blockID).inserted else { return "duplicate block id" }
        group.blockCount += 1
        guard group.blockCount <= maxBlocks else { return "large group" }
        for child in YBlockProjection.children(of: container, includeFormats: false) {
            guard case .type(let type) = child.content else { continue }
            if type.typeRef == .xmlElement(nodeName: "columnList") { return "nested column group" }
            guard type.typeRef == .xmlElement(nodeName: "blockGroup") else { continue }
            guard depth < NativeBlockProjection.maxDepth else { return "nesting" }
            for nested in YBlockProjection.children(of: type, includeFormats: false) {
                guard case .type(let inner) = nested.content else { return "unexpected column child" }
                if let reason = count(inner, depth: depth + 1, seen: &seen, group: &group) { return reason }
            }
        }
        return nil
    }

    /// Every familiar root column group of `doc` with each column's blocks
    /// (the reader's copy, PR12a). Unfamiliar groups are left out: the reader
    /// shows only their card.
    static func groups(in doc: YDoc) -> [String: (group: ColumnGroup, blocks: [[BlockSnapshot]])] {
        guard let root = doc.share[BlockNoteYjs.fragmentField],
            let groupItem = YBlockProjection.children(of: root, includeFormats: false).first,
            case .type(let rootGroup) = groupItem.content
        else { return [:] }
        var groups: [String: (group: ColumnGroup, blocks: [[BlockSnapshot]])] = [:]
        for item in YBlockProjection.children(of: rootGroup, includeFormats: false) {
            guard case .type(let list) = item.content, list.typeRef == .xmlElement(nodeName: "columnList"),
                let id = BlockIndex.blockID(of: list)
            else { continue }
            let group = read(list, id: id)
            guard group.isFamiliar else { continue }
            groups[id] = (
                group,
                columnTypes(of: list).map { NativeBlockProjection.columnBlocks($0).map(BlockSnapshot.init) }
            )
        }
        return groups
    }

    /// Every column id of `doc`'s root groups (PR12b: a new id must not reuse one).
    static func columnIDs(in doc: YDoc) -> Set<String> {
        guard let root = doc.share[BlockNoteYjs.fragmentField],
            case .type(let rootGroup)? = YBlockProjection.children(of: root, includeFormats: false).first?.content
        else { return [] }
        var ids: Set<String> = []
        for item in YBlockProjection.children(of: rootGroup, includeFormats: false) {
            guard case .type(let list) = item.content, list.typeRef == .xmlElement(nodeName: "columnList") else {
                continue
            }
            for column in columnTypes(of: list) { if let id = BlockIndex.blockID(of: column) { ids.insert(id) } }
        }
        return ids
    }

    /// The `column` elements of `list`, in order (no familiarity check).
    static func columnTypes(of list: YType) -> [YType] {
        YBlockProjection.children(of: list, includeFormats: false).compactMap { item in
            guard case .type(let column) = item.content, column.typeRef == .xmlElement(nodeName: "column") else {
                return nil
            }
            return column
        }
    }
}
