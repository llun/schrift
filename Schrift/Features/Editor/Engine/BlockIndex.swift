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

    /// The block id a changed type belongs to: the innermost `blockContainer`
    /// on its parent chain. `nil` for a change at the root or the root group.
    func blockID(for type: YType) -> String? {
        var current: YType? = type
        while let candidate = current {
            if candidate.typeRef == .xmlElement(nodeName: "blockContainer"), let id = Self.blockID(of: candidate) {
                return id
            }
            current = candidate.item?.parentType
        }
        return nil
    }

    /// The containers of a group, in list order, with their readable ids.
    func containers(in group: YType) -> [(id: String, item: YItem)] {
        var out: [(id: String, item: YItem)] = []
        var item = group.start
        while let current = item {
            defer { item = current.right }
            guard !current.deleted, case .type(let type) = current.content,
                type.typeRef == .xmlElement(nodeName: "blockContainer"),
                let id = Self.blockID(of: type)
            else { continue }
            out.append((id, current))
        }
        return out
    }

    /// Re-reads one block after a change. O(block), never O(document).
    mutating func refresh(_ id: String) {
        guard let entry = entries[id] else { return }
        entries[id] = makeEntry(id: id, item: entry.containerItem, depth: entry.depth, parentID: entry.parentID)
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
            guard case .type(let type) = child.content, type.typeRef == .xmlElement(nodeName: "blockContainer"),
                let id = blockID(of: type), !id.isEmpty, seen.insert(id).inserted
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
                isSimpleContainer: false, isSimpleText: false, isProjectable: false, runs: [], depth: depth,
                parentID: parentID, group: group, nestedGroup: nil, handle: handle)
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
        if isSimpleContainer, let element {
            let elementChildren = Self.countableChildren(of: element)
            if elementChildren.count == 1, case .type(let type) = elementChildren[0].content,
                type.typeRef == .xmlText
            {
                textType = type
            }
        }
        let isProjectable =
            isSimpleContainer && element.map { YBlockProjection.props(of: $0) != nil } == true
            && textType.map(Self.projectsAsText) != false
        return Entry(
            id: id, containerItem: item, container: container, element: element, textType: textType,
            isSimpleContainer: isSimpleContainer, isSimpleText: textType != nil, isProjectable: isProjectable,
            runs: isProjectable ? textType.flatMap(YBlockProjection.textRuns) ?? [] : [], depth: depth,
            parentID: parentID, group: group, nestedGroup: nestedGroup, handle: handle)
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
