import Foundation

/// Block id ↔ container / content element / text children, built once from the
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
        /// The `XmlText` children of the block's **content element** — the only
        /// text a `.text` patch may address. Text anywhere else (a nested
        /// block's content, a nested group) is not this block's text.
        let textTypes: [YType]
    }

    private(set) var entries: [String: Entry] = [:]
    /// Block ids in document order.
    private(set) var order: [String] = []
    /// The ordered block ids the root `blockGroup` held when the index last saw
    /// it. Nested groups are not tracked: a change inside one escalates to a
    /// `.replaceBlock` of its top-level block, so there is nothing to diff.
    private(set) var groupOrder: [ObjectIdentifier: [String]] = [:]
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

    /// Re-reads the whole index. Only structural changes pay for this: a
    /// split/join/insert/remove is rare, a keystroke is not.
    mutating func rebuild() {
        entries = [:]
        order = []
        groupOrder = [:]
        root = doc.share[BlockNoteYjs.fragmentField]
        guard let root, let group = Self.rootGroup(in: root) else { return }
        let containers = containers(in: group)
        groupOrder[ObjectIdentifier(group)] = containers.map(\.id)
        for (id, item) in containers {
            entries[id] = Self.entry(id: id, item: item)
            order.append(id)
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
            return Entry(id: id, containerItem: item, container: YType(), element: nil, textTypes: [])
        }
        var element: YType?
        var child = container.start
        while let current = child {
            defer { child = current.right }
            guard !current.deleted, case .type(let type) = current.content else { continue }
            if element == nil, case .xmlElement = type.typeRef {
                element = type
                break
            }
        }
        // Text lives inside the content element, not beside it.
        var textTypes: [YType] = []
        var textChild = element?.start
        while let current = textChild {
            defer { textChild = current.right }
            guard !current.deleted, case .type(let type) = current.content else { continue }
            if type.typeRef == .xmlText { textTypes.append(type) }
        }
        return Entry(id: id, containerItem: item, container: container, element: element, textTypes: textTypes)
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
