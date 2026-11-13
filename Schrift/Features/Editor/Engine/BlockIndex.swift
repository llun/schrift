import Foundation

/// Block id ↔ container / content element / text child, built once from the
/// replica and then maintained **incrementally** from the transaction's changed
/// types. Nothing here walks the document per edit: a text change touches one
/// `XmlText`, and resolving it to its block is a walk up the parent chain, not
/// a walk across the document.
///
/// Every block of the tree is indexed in preorder (PR06a), mirroring
/// `NativeBlockProjection`: a container whose children are its content element
/// and one nested `blockGroup` is indexed, then its group's blocks one level
/// deeper. A change resolves to the innermost container on its parent chain.
struct BlockIndex {
    struct Entry {
        let id: String
        let containerItem: YItem
        let container: YType
        let element: YType?
        /// The element's single `XmlText` child, when `isSimpleText`. `nil` for
        /// inline nodes, several text children, or a leaf — shapes the `.text`
        /// fast path must not address.
        let textType: YType?
        /// True when the container's countable children are its content
        /// element, optionally followed by one nested `blockGroup` — the
        /// shapes `NativeBlockProjection` reads props and runs from.
        let isSimpleContainer: Bool
        /// True when the container is simple and the element's only countable
        /// child is an `XmlText`.
        let isSimpleText: Bool
        /// True when the container is simple and holds at least one familiar
        /// `NativeInlineObject` leaf (`isSimpleText` stays false).
        let hasInlineObjects: Bool
        /// True when, at the time the entry was built, the projection read this
        /// block's props and text as-is: a simple container, readable props,
        /// and — when the element is a sole `XmlText` — only strings and marks
        /// with readable links. Otherwise the projection dropped content the
        /// surface's copy therefore lacks, and a fast-path
        /// patch computed from the replica could not be applied to it.
        let isProjectable: Bool
        /// The sole text's runs when the entry was built — the surface's copy,
        /// which a `.text` patch is checked against. `[]` unless `isSimpleText`.
        let runs: [InlineRun]
        /// 0 for a root block, one more per nested group.
        let depth: Int
        /// The block whose nested group holds this one; nil at the root.
        let parentID: String?
        /// The `blockGroup` holding this container.
        let group: YType
        /// The container's own nested `blockGroup`, when it has children.
        let nestedGroup: YType?
        let handle: NativeBlockHandle
    }

    /// One per index (one per engine): handles from another replica never match.
    let generation = UUID()

    private(set) var entries: [String: Entry] = [:]
    /// Block ids in document order.
    private(set) var order: [String] = []
    /// Block id → its position in `order`, so a patch can iterate touched ids
    /// in document order without scanning the whole list.
    private(set) var position: [String: Int] = [:]
    /// The ordered block ids each `blockGroup` held when the index last saw it.
    private(set) var groupOrder: [ObjectIdentifier: [String]] = [:]
    /// The root group's item, so a replacement (same id, new object) is visible.
    private(set) var rootGroupItem: YItem?
    /// False when the replica has a shape the id-keyed index cannot mirror:
    /// a root with more than one child, a group child that is not a container
    /// with a readable id, or two containers sharing an id. The projection
    /// still renders those (as `""`-id or repeated blocks), so while this is
    /// false every transaction resets the surface instead of diffing.
    private(set) var isCanonical = true
    private let doc: YDoc
    /// Re-resolved on every rebuild: an engine created on an empty document
    /// must start patching once the owner seeds the root.
    private var root: YType?
    /// Tables the native table editor opened (PR11a), by block id: their
    /// paragraph ids in grid order (cell by cell, paragraph by paragraph).
    /// Each is an entry (`entries`) addressed like a block's text, but never
    /// in `order`: the document surface does not show them. Empty when the
    /// table is gone or no longer familiar; re-read on every rebuild.
    private(set) var openTables: [String: [String]] = [:]
    /// A table paragraph's element → its id, for `blockID(for:)`.
    private var paragraphIDs: [ObjectIdentifier: String] = [:]
    /// Column groups the native column editor opened (PR12a), by group id:
    /// their column ids in order. Every block of every column is an entry
    /// (`entries`), addressed like any block, but never in `order`: the
    /// document surface shows the group as one block. Empty when the group is
    /// gone or no longer familiar; re-read on every rebuild.
    private(set) var openGroups: [String: [String]] = [:]
    /// An open column's blocks, by column id, in preorder.
    private(set) var columnOrders: [String: [String]] = [:]
    /// An open column's block → its column id.
    private(set) var columnOf: [String: String] = [:]
    /// An open column's block → its place in its column's order.
    private var columnPosition: [String: Int] = [:]

    init(doc: YDoc) {
        self.doc = doc
        root = doc.share[BlockNoteYjs.fragmentField]
        rebuild()
    }

    /// Re-reads the fragment root when it was absent at init (an engine created
    /// on an empty document). Returns true when the root just appeared, so the
    /// builder can treat the whole block list as new. Cheap: one map lookup, and
    /// only while nil.
    mutating func resolveRoot() -> Bool {
        guard root == nil else { return false }
        root = doc.share[BlockNoteYjs.fragmentField]
        return root != nil
    }

    /// The root `blockGroup`, if the fragment has one.
    func rootGroupType() -> YType? {
        guard let root else { return nil }
        return Self.rootGroup(in: root)
    }

    /// Whether `type` is the root `blockGroup` — the only group whose child
    /// list is the document's block list.
    func isRootGroup(_ type: YType) -> Bool {
        guard let root, let item = type.item else { return false }
        return item.parentType === root
    }

    /// The block id a changed type belongs to: the innermost indexed
    /// `blockContainer` on its parent chain. A change inside a subtree the
    /// index does not descend into (an opaque or too-deep block's) belongs to
    /// that nearest indexed ancestor, which the surface shows. `nil` for a
    /// change at the root or the root group.
    func blockID(for type: YType) -> String? {
        var current: YType? = type
        while let candidate = current {
            // An open table's paragraph is its own text target (PR11a).
            if candidate.typeRef == .xmlElement(nodeName: "tableParagraph"),
                let id = paragraphIDs[ObjectIdentifier(candidate)], entries[id]?.element === candidate
            {
                return id
            }
            if candidate.typeRef == .xmlElement(nodeName: "blockContainer")
                || candidate.typeRef == .xmlElement(nodeName: "columnList"),
                let id = Self.blockID(of: candidate), entries[id]?.container === candidate
            {
                return id
            }
            current = candidate.item?.parentType
        }
        return nil
    }

    /// The containers of a group, in list order, with their readable ids. A
    /// column group (PR12a) is one of them: an atomic block of its group.
    func containers(in group: YType) -> [(id: String, item: YItem)] {
        var out: [(id: String, item: YItem)] = []
        var item = group.start
        while let current = item {
            defer { item = current.right }
            guard !current.deleted, case .type(let type) = current.content,
                type.typeRef == .xmlElement(nodeName: "blockContainer")
                    || type.typeRef == .xmlElement(nodeName: "columnList"),
                let id = Self.blockID(of: type)
            else { continue }
            out.append((id, current))
        }
        return out
    }

    /// Re-reads one block after a change. O(block), never O(document).
    mutating func refresh(_ id: String) {
        guard let entry = entries[id] else { return }
        if isTableParagraph(id) {
            entries[id] = Self.paragraphEntry(
                id: id, item: entry.containerItem, group: entry.group, handle: entry.handle)
            return
        }
        entries[id] = makeEntry(id: id, item: entry.containerItem, depth: entry.depth, parentID: entry.parentID)
    }

    // MARK: - Open column groups (PR12a)

    /// Whether `id` is a column group of this index.
    func isColumnGroup(_ id: String) -> Bool {
        entries[id]?.container.typeRef == .xmlElement(nodeName: "columnList")
    }

    /// Indexes every block of every column of group `id`. False (and nothing
    /// indexed) unless it is a block of this index holding a familiar group
    /// none of whose block ids the document already uses.
    @discardableResult
    mutating func openColumns(_ id: String) -> Bool {
        closeColumns(id)
        openGroups[id] = []
        return indexColumns(id)
    }

    mutating func closeColumns(_ id: String) {
        for column in openGroups.removeValue(forKey: id) ?? [] {
            for block in columnOrders.removeValue(forKey: column) ?? [] {
                entries.removeValue(forKey: block)
                columnOf.removeValue(forKey: block)
                columnPosition.removeValue(forKey: block)
            }
        }
    }

    /// Re-reads an open group's blocks after a change inside it.
    mutating func reindexColumns(_ id: String) {
        guard openGroups[id] != nil else { return }
        openColumns(id)
    }

    /// The ordered block list `id` belongs to: its open column's, else the
    /// document's. The engine's order rules (join, range, marks, moves) use
    /// it, so a column's blocks never meet another column's or the document's.
    func list(of id: String) -> [String] {
        guard let column = columnOf[id] else { return order }
        return columnOrders[column] ?? []
    }

    /// Whether `a` and `b` are in one list (the document's, or one column's).
    func sameList(_ a: String, _ b: String) -> Bool { columnOf[a] == columnOf[b] }

    /// `id`'s place in `list(of: id)`.
    func listPosition(of id: String) -> Int? {
        columnOf[id] == nil ? position[id] : columnPosition[id]
    }

    @discardableResult
    private mutating func indexColumns(_ id: String) -> Bool {
        guard let entry = entries[id], columnOf[id] == nil,
            entry.container.typeRef == .xmlElement(nodeName: "columnList"),
            ColumnGroup.read(entry.container, id: id).isFamiliar
        else { return false }
        var columns: [String] = []
        var indexed: [String] = []
        var collides = false
        for column in ColumnGroup.columnTypes(of: entry.container) {
            guard let columnID = Self.blockID(of: column) else { continue }
            var ids: [String] = []
            func index(_ group: YType, depth: Int, parentID: String?) {
                let containers = containers(in: group)
                groupOrder[ObjectIdentifier(group)] = containers.map(\.id)
                for container in containers {
                    guard entries[container.id] == nil else {
                        collides = true
                        continue
                    }
                    let entry = makeEntry(id: container.id, item: container.item, depth: depth, parentID: parentID)
                    entries[container.id] = entry
                    indexed.append(container.id)
                    columnOf[container.id] = columnID
                    columnPosition[container.id] = ids.count
                    ids.append(container.id)
                    if let nested = entry.nestedGroup { index(nested, depth: depth + 1, parentID: container.id) }
                }
            }
            index(column, depth: 0, parentID: nil)
            columns.append(columnID)
            columnOrders[columnID] = ids
        }
        openGroups[id] = columns
        // A block id the document already uses addresses no column block.
        if collides {
            closeColumns(id)
            openGroups[id] = []
            return false
        }
        return true
    }

    // MARK: - Open tables (PR11a)

    /// Indexes every paragraph of table `id` as a text target. False (and
    /// nothing indexed) unless it is a block of this index holding a
    /// familiar table: an unfamiliar one is preserved, never addressed.
    @discardableResult
    mutating func openTable(_ id: String) -> Bool {
        closeTable(id)
        openTables[id] = []
        return indexTable(id)
    }

    /// Whether `id` is an open table's paragraph: membership, never the
    /// spelling (a block id could hold the same separator).
    func isTableParagraph(_ id: String) -> Bool {
        guard let table = TableGrid.tableID(ofParagraph: id) else { return false }
        return openTables[table]?.contains(id) == true
    }

    mutating func closeTable(_ id: String) {
        for paragraph in openTables.removeValue(forKey: id) ?? [] {
            if let element = entries.removeValue(forKey: paragraph)?.element {
                paragraphIDs.removeValue(forKey: ObjectIdentifier(element))
            }
        }
    }

    /// Re-reads an open table's paragraphs after a change inside it.
    mutating func reindexTable(_ id: String) {
        guard openTables[id] != nil else { return }
        openTable(id)
    }

    @discardableResult
    private mutating func indexTable(_ id: String) -> Bool {
        guard let entry = entries[id], !isTableParagraph(id), let element = entry.element,
            element.typeRef == .xmlElement(nodeName: "table")
        else { return false }
        let grid = TableGrid.read(element)
        guard grid.isFamiliar else { return false }
        var ids: [String] = []
        for row in YBlockProjection.children(of: element, includeFormats: false) {
            guard case .type(let rowType) = row.content else { continue }
            for cell in YBlockProjection.children(of: rowType, includeFormats: false) {
                guard case .type(let cellType) = cell.content else { continue }
                for paragraph in YBlockProjection.children(of: cellType, includeFormats: false) {
                    guard case .type(let paragraphType) = paragraph.content else { continue }
                    let paragraphID = TableGrid.paragraphID(table: id, item: paragraph.id)
                    let handle = NativeBlockHandle(generation: generation, itemID: paragraph.id, stringID: paragraphID)
                    entries[paragraphID] = Self.paragraphEntry(
                        id: paragraphID, item: paragraph, group: cellType, handle: handle)
                    paragraphIDs[ObjectIdentifier(paragraphType)] = paragraphID
                    ids.append(paragraphID)
                }
            }
        }
        openTables[id] = ids
        return true
    }

    /// A table paragraph as a root-level text block: its element is its own
    /// container, and it is projectable when it is one plain `XmlText` (or
    /// empty), the shape typing addresses.
    private static func paragraphEntry(id: String, item: YItem, group: YType, handle: NativeBlockHandle) -> Entry {
        guard case .type(let paragraph) = item.content else {
            return Entry(
                id: id, containerItem: item, container: YType(), element: nil, textType: nil,
                isSimpleContainer: false, isSimpleText: false, hasInlineObjects: false, isProjectable: false, runs: [],
                depth: 0, parentID: nil, group: group, nestedGroup: nil, handle: handle)
        }
        let children = countableChildren(of: paragraph)
        var textType: YType?
        if children.count == 1, case .type(let type) = children[0].content, type.typeRef == .xmlText {
            textType = type
        }
        let propsOK = YBlockProjection.props(of: paragraph) != nil
        let hasInlineObjects: Bool
        let isProjectable: Bool
        let runs: [InlineRun]
        if let textType {
            hasInlineObjects = false
            isProjectable = propsOK && projectsAsText(textType)
            runs = isProjectable ? (YBlockProjection.textRuns(textType) ?? []) : []
        } else if children.isEmpty {
            hasInlineObjects = false
            isProjectable = propsOK
            runs = []
        } else if propsOK, let tableRuns = TableGrid.paragraphRuns(paragraph) {
            isProjectable = true
            hasInlineObjects = tableRuns.contains { $0.inlineObject != nil }
            runs = tableRuns
        } else {
            hasInlineObjects = false
            isProjectable = false
            runs = []
        }
        return Entry(
            id: id, containerItem: item, container: paragraph, element: paragraph, textType: textType,
            isSimpleContainer: true, isSimpleText: textType != nil, hasInlineObjects: hasInlineObjects,
            isProjectable: isProjectable, runs: runs, depth: 0, parentID: nil, group: group, nestedGroup: nil,
            handle: handle)
    }

    /// Re-reads the whole index, including each block's text for
    /// `isProjectable`. Only a group or container structure change or a reset
    /// pays for this: a split/join/insert/remove/move is rare, a keystroke is not.
    mutating func rebuild() {
        entries = [:]
        order = []
        position = [:]
        groupOrder = [:]
        rootGroupItem = nil
        isCanonical = true
        root = doc.share[BlockNoteYjs.fragmentField]
        let tables = Array(openTables.keys)
        paragraphIDs = [:]
        openTables = [:]
        let groups = Array(openGroups.keys)
        openGroups = [:]
        columnOrders = [:]
        columnOf = [:]
        columnPosition = [:]
        // Open tables and column groups survive a rebuild, re-read (or
        // emptied) from the new tree. Groups first: a column's table is one
        // of their blocks.
        defer {
            for group in groups {
                openGroups[group] = []
                if isCanonical { indexColumns(group) }
            }
            for table in tables {
                openTables[table] = []
                // A shape the index cannot mirror addresses no cell.
                if isCanonical { indexTable(table) }
            }
        }
        guard let root else { return }
        let rootChildren = Self.countableChildren(of: root)
        guard let group = Self.rootGroup(in: root) else {
            isCanonical = rootChildren.isEmpty
            return
        }
        isCanonical = rootChildren.count == 1
        rootGroupItem = group.item
        index(group, depth: 0, parentID: nil)
    }

    /// Preorder, with `NativeBlockProjection`'s descent rule and depth bound.
    private mutating func index(_ group: YType, depth: Int, parentID: String?) {
        if !Self.isCanonical(group: group) { isCanonical = false }
        let containers = containers(in: group)
        groupOrder[ObjectIdentifier(group)] = containers.map(\.id)
        for container in containers {
            guard entries[container.id] == nil else {
                isCanonical = false
                continue
            }
            let entry = makeEntry(id: container.id, item: container.item, depth: depth, parentID: parentID)
            entries[container.id] = entry
            position[container.id] = order.count
            order.append(container.id)
            if let nested = entry.nestedGroup { index(nested, depth: depth + 1, parentID: container.id) }
        }
    }

    // MARK: - Reading the replica

    /// True when every countable child of `group` is a container with a
    /// readable, non-empty id, and no id repeats in it. (`rebuild` also
    /// refuses an id repeated across groups.)
    static func isCanonical(group: YType) -> Bool {
        var seen: Set<String> = []
        for child in countableChildren(of: group) {
            // A column group (PR12a) is an atomic block of its group, by its own id.
            guard case .type(let type) = child.content,
                type.typeRef == .xmlElement(nodeName: "blockContainer")
                    || type.typeRef == .xmlElement(nodeName: "columnList"),
                let id = blockID(of: type), !id.isEmpty, seen.insert(id).inserted,
                // U+0001 is the cell paragraph ids' separator (PR11a): a block
                // spelling one could pose as a table paragraph.
                !id.unicodeScalars.contains("\u{1}")
            else { return false }
        }
        return true
    }

    private static func rootGroup(in root: YType) -> YType? {
        var item = root.start
        while let current = item {
            defer { item = current.right }
            guard !current.deleted, case .type(let type) = current.content else { continue }
            if type.typeRef == .xmlElement(nodeName: "blockGroup") { return type }
        }
        return nil
    }

    private func makeEntry(id: String, item: YItem, depth: Int, parentID: String?) -> Entry {
        let handle = NativeBlockHandle(generation: generation, itemID: item.id, stringID: id)
        let group = item.parentType ?? YType()
        guard case .type(let container) = item.content else {
            return Entry(
                id: id, containerItem: item, container: YType(), element: nil, textType: nil,
                isSimpleContainer: false, isSimpleText: false, hasInlineObjects: false, isProjectable: false, runs: [],
                depth: depth, parentID: parentID, group: group, nestedGroup: nil, handle: handle)
        }
        // A column group (PR12a): its own element, atomic, no text of its own.
        if container.typeRef == .xmlElement(nodeName: "columnList") {
            return Entry(
                id: id, containerItem: item, container: container, element: container, textType: nil,
                isSimpleContainer: false, isSimpleText: false, hasInlineObjects: false, isProjectable: false, runs: [],
                depth: depth, parentID: parentID, group: group, nestedGroup: nil, handle: handle)
        }
        // Counted the way `YBlockProjection` counts children (countable items
        // only), so the fast paths accept exactly the shapes it projects. A
        // block at the projection's depth bound with children is opaque there.
        let containerChildren = Self.countableChildren(of: container)
        let nestedGroup =
            depth < NativeBlockProjection.maxDepth ? NativeBlockProjection.nestedGroup(of: container) : nil
        var element: YType?
        if let first = containerChildren.first, case .type(let type) = first.content,
            type.typeRef != .xmlElement(nodeName: "blockGroup"), case .xmlElement = type.typeRef
        {
            element = type
        }
        let isSimpleContainer = element != nil && (containerChildren.count == 1 || nestedGroup != nil)
        var textType: YType?
        var elementChildren: [YItem] = []
        if isSimpleContainer, let element {
            elementChildren = Self.countableChildren(of: element)
            if elementChildren.count == 1, case .type(let type) = elementChildren[0].content,
                type.typeRef == .xmlText
            {
                textType = type
            }
        }
        let hasInlineObjects: Bool
        let isProjectable: Bool
        let runs: [InlineRun]
        if let textType {
            hasInlineObjects = false
            isProjectable =
                isSimpleContainer && element.map { YBlockProjection.props(of: $0) != nil } == true
                && Self.projectsAsText(textType)
            runs = isProjectable ? (YBlockProjection.textRuns(textType) ?? []) : []
        } else if isSimpleContainer, let element {
            if elementChildren.isEmpty {
                hasInlineObjects = false
                isProjectable = YBlockProjection.props(of: element) != nil
                runs = []
            } else if case .xmlElement(let node)? = element.typeRef,
                BlockNoteWriter.nativePropSchemas[node] != nil, node != "codeBlock"
            {
                let projected = YBlockProjection.projectBlock(item, nativeMarks: true, nestedChildren: true)
                isProjectable = !projected.fidelity.isOpaque
                hasInlineObjects = isProjectable && projected.runs.contains { $0.inlineObject != nil }
                runs = isProjectable ? projected.runs : []
            } else if case .xmlElement("codeBlock")? = element.typeRef {
                hasInlineObjects = false
                isProjectable = false
                runs = []
            } else {
                hasInlineObjects = false
                isProjectable = YBlockProjection.props(of: element) != nil
                runs = []
            }
        } else {
            hasInlineObjects = false
            isProjectable = false
            runs = []
        }
        return Entry(
            id: id, containerItem: item, container: container, element: element, textType: textType,
            isSimpleContainer: isSimpleContainer, isSimpleText: textType != nil, hasInlineObjects: hasInlineObjects,
            isProjectable: isProjectable, runs: runs, depth: depth, parentID: parentID, group: group,
            nestedGroup: nestedGroup, handle: handle)
    }

    /// True when the projection reads this text as runs unchanged: only strings
    /// and formats, and every link readable. An embed or a bad link makes the
    /// block opaque. Any mark key is fine: the engine projects with
    /// `nativeMarks`, which keeps every mark, known or not.
    static func projectsAsText(_ text: YType) -> Bool {
        var item = text.start
        while let current = item {
            defer { item = current.right }
            guard !current.deleted else { continue }
            switch current.content {
            case .string: continue
            case .format(let key, let valueJSON):
                guard valueJSON != "null" else { continue }
                if key == "link", YBlockProjection.linkHref(from: valueJSON) == nil { return false }
            default: return false
            }
        }
        return true
    }

    private static func countableChildren(of type: YType) -> [YItem] {
        var out: [YItem] = []
        var item = type.start
        while let current = item {
            defer { item = current.right }
            if !current.deleted, current.countable { out.append(current) }
        }
        return out
    }

    /// The container's `id` map entry, read the way `YBlockProjection` reads it.
    static func blockID(of container: YType) -> String? {
        guard let item = container.map["id"], !item.deleted,
            case .any(let values) = item.content, values.count == 1,
            case .string(let id) = values[0]
        else { return nil }
        return id
    }
}
