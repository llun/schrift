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
        let node: String
        let textTypes: [YType]
    }

    private(set) var entries: [String: Entry] = [:]
    /// Block ids in document order.
    private(set) var order: [String] = []
    /// The ordered block ids each `blockGroup` held when the index last saw it.
    private(set) var groupOrder: [ObjectIdentifier: [String]] = [:]
    private let root: YType?

    init(doc: YDoc) {
        root = doc.share[BlockNoteYjs.fragmentField]
        rebuild()
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
            return Entry(id: id, containerItem: item, container: YType(), element: nil, node: "", textTypes: [])
        }
        var element: YType?
        var node = ""
        var textTypes: [YType] = []
        var child = container.start
        while let current = child {
            defer { child = current.right }
            guard !current.deleted, case .type(let type) = current.content else { continue }
            if element == nil, case .xmlElement(let name)? = type.typeRef {
                element = type
                node = name
            } else if type.typeRef == .xmlText {
                textTypes.append(type)
            }
        }
        return Entry(
            id: id, containerItem: item, container: container, element: element, node: node, textTypes: textTypes)
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
