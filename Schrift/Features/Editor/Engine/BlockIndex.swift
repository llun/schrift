import Foundation

/// Block id ↔ container / content element / text child, built once from the
/// replica and then maintained **incrementally** from the transaction's changed
/// types. Nothing here walks the document per edit: a text change touches one
/// `XmlText`, and resolving it to its block is a walk up the parent chain, not
/// a walk across the document.
///
/// Only the root `blockGroup`'s containers are indexed, mirroring
/// `YBlockProjection`: a block with nested children projects opaque, so its
/// descendants are not blocks the engine can address. A change inside such a
/// subtree resolves to the outermost container, which is the block the surface
/// knows.
struct BlockIndex {
    struct Entry {
        let id: String
        let containerItem: YItem
        let container: YType
        let element: YType?
        /// The element's single `XmlText` child, when the element has exactly
        /// one child and it is text. `nil` for inline nodes, several text
        /// children, or a leaf — shapes the `.text` fast path must not address.
        let textType: YType?
        /// True when the element has exactly one child, an `XmlText`.
        let isSimpleText: Bool
        /// True when the container has a nested `blockGroup` child.
        let hasNestedChildren: Bool
    }

    private(set) var entries: [String: Entry] = [:]
    /// Block ids in document order.
    private(set) var order: [String] = []
    /// Block id → its position in `order`, so a patch can iterate touched ids
    /// in document order without scanning the whole list.
    private(set) var position: [String: Int] = [:]
    /// The ordered block ids the root `blockGroup` held when the index last saw
    /// it. Nested groups are not tracked: a change inside one escalates to a
    /// `.replaceBlock` of its top-level block, so there is nothing to diff.
    private(set) var groupOrder: [ObjectIdentifier: [String]] = [:]
    /// The root group's item, so a replacement (same id, new object) is visible.
    private(set) var rootGroupItem: YItem?
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

    /// The block id a changed type belongs to: the outermost `blockContainer`
    /// on its parent chain. `nil` for a change at the root or a group.
    func blockID(for type: YType) -> String? {
        var current: YType? = type
        var outermost: YType?
        while let candidate = current {
            if candidate.typeRef == .xmlElement(nodeName: "blockContainer"), Self.blockID(of: candidate) != nil {
                outermost = candidate
            }
            current = candidate.item?.parentType
        }
        guard let outermost else { return nil }
        return Self.blockID(of: outermost)
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
        entries[id] = Self.entry(id: id, item: entry.containerItem)
    }

    /// Points an id at a new container item — a container replaced in place
    /// keeps its id but is a different object, and the entry must follow it.
    mutating func setContainer(_ id: String, item: YItem) {
        entries[id] = Self.entry(id: id, item: item)
    }

    /// Re-reads the whole index. Only structural changes pay for this: a
    /// split/join/insert/remove is rare, a keystroke is not.
    mutating func rebuild() {
        entries = [:]
        order = []
        position = [:]
        groupOrder = [:]
        rootGroupItem = nil
        root = doc.share[BlockNoteYjs.fragmentField]
        guard let root, let group = Self.rootGroup(in: root) else { return }
        rootGroupItem = group.item
        let containers = containers(in: group)
        groupOrder[ObjectIdentifier(group)] = containers.map(\.id)
        for (index, container) in containers.enumerated() {
            entries[container.id] = Self.entry(id: container.id, item: container.item)
            order.append(container.id)
            position[container.id] = index
        }
    }

    mutating func setGroupOrder(_ group: YType, _ ids: [String]) {
        groupOrder[ObjectIdentifier(group)] = ids
    }

    // MARK: - Reading the replica

    private static func rootGroup(in root: YType) -> YType? {
        var item = root.start
        while let current = item {
            defer { item = current.right }
            guard !current.deleted, case .type(let type) = current.content else { continue }
            if type.typeRef == .xmlElement(nodeName: "blockGroup") { return type }
        }
        return nil
    }

    private static func entry(id: String, item: YItem) -> Entry {
        guard case .type(let container) = item.content else {
            return Entry(
                id: id, containerItem: item, container: YType(), element: nil, textType: nil,
                isSimpleText: false, hasNestedChildren: false)
        }
        var element: YType?
        var hasNestedChildren = false
        var child = container.start
        while let current = child {
            defer { child = current.right }
            guard !current.deleted, case .type(let type) = current.content else { continue }
            if type.typeRef == .xmlElement(nodeName: "blockGroup") {
                hasNestedChildren = true
            } else if element == nil, case .xmlElement = type.typeRef {
                element = type
            }
        }
        // The `.text` fast path needs the element to be exactly one XmlText:
        // no inline nodes, no sibling text children whose offsets would need
        // translating.
        var textType: YType?
        var elementChildCount = 0
        var elementChildIsText = false
        var textChild = element?.start
        while let current = textChild {
            defer { textChild = current.right }
            guard !current.deleted, case .type(let type) = current.content else { continue }
            elementChildCount += 1
            if type.typeRef == .xmlText {
                textType = type
                elementChildIsText = true
            }
        }
        let isSimpleText = elementChildCount == 1 && elementChildIsText
        return Entry(
            id: id, containerItem: item, container: container, element: element,
            textType: isSimpleText ? textType : nil, isSimpleText: isSimpleText,
            hasNestedChildren: hasNestedChildren)
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
