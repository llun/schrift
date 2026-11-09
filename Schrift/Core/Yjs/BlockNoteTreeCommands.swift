import Foundation

/// BlockNote 0.56's Tab and Shift-Tab (`nestBlock` / `unnestBlock`, its
/// versions of prosemirror-schema-list's `sinkListItem` / `liftListItem`), for
/// one block. Yjs cannot reparent an integrated node, so each is a validated
/// clone and delete in one transaction, as y-prosemirror's own replace steps
/// are: every raw value, mark and child of a moved block is copied
/// (`snapshot`/`insertCopy`) before anything is written, and the copies are
/// new items. Identity is **not** preserved: the string ids survive, but a
/// peer's concurrent edit inside a moved block lands in the deleted original.
/// Depth bounds and block-type rules are the caller's.
extension BlockNoteWriter {
    /// `sinkListItem`: the block becomes the last child of its previous
    /// sibling, in that sibling's nested group or a new one. Its own children
    /// move with it. The first block of a group throws `noPreviousBlock`.
    @discardableResult
    func sinkListItem(block: String) throws -> Data {
        try sinkListItem(in: try find(block))
    }

    @discardableResult
    func sinkListItem(in target: Target) throws -> Data {
        let siblings = children(target.group)
        guard let index = siblings.firstIndex(where: { $0 === target.item }), index > 0 else {
            throw Error.noPreviousBlock(target.id)
        }
        guard case .type(let previous) = siblings[index - 1].content,
            previous.typeRef == .xmlElement(nodeName: "blockContainer")
        else { throw Error.malformedBlock(target.id) }
        // ProseMirror's `nestedBefore`: the sibling's last child is its group.
        let last = children(previous).last
        var nested: YType?
        if let last, case .type(let type) = last.content, type.typeRef == .xmlElement(nodeName: "blockGroup") {
            nested = type
        }
        let copy = try snapshot(target.container, block: target.id, depth: 0)
        return try transaction { tx in
            let group: YType
            if let nested {
                group = nested
            } else {
                group = YType(typeRef: .xmlElement(nodeName: "blockGroup"))
                guard try YWrite.insertAfter(tx, into: previous, after: last, [.type(group)]) != nil else {
                    throw Error.malformedBlock(target.id)
                }
            }
            try insertCopy(tx, copy, into: group, after: children(group).last)
            target.item.delete(tx)
        }
    }

    /// `liftListItem` (`liftToOuterList`): the block becomes the sibling after
    /// its parent; the siblings that followed it become its last children,
    /// after any it already had. A parent group left empty is removed. A root
    /// block throws `unsupportedBlockType` (BlockNote cannot unnest it).
    @discardableResult
    func liftListItem(block: String) throws -> Data {
        try liftListItem(in: try find(block))
    }

    @discardableResult
    func liftListItem(in target: Target) throws -> Data {
        guard let groupItem = target.group.item, let parent = groupItem.parentType,
            parent.typeRef == .xmlElement(nodeName: "blockContainer"), let parentItem = parent.item,
            let outer = parentItem.parentType, outer.typeRef == .xmlElement(nodeName: "blockGroup")
        else { throw Error.unsupportedBlockType(target.node) }
        let siblings = children(target.group)
        guard let index = siblings.firstIndex(where: { $0 === target.item }) else {
            throw Error.malformedBlock(target.id)
        }
        let following = Array(siblings[(index + 1)...])
        let copy = try snapshot(target.container, block: target.id, depth: 0)
        let followingCopies = try following.map { item -> Copy in
            guard case .type(let container) = item.content else { throw Error.malformedBlock(target.id) }
            return try snapshot(container, block: target.id, depth: 0)
        }
        return try transaction { tx in
            let lifted = try insertCopy(tx, copy, into: outer, after: parentItem)
            if !followingCopies.isEmpty {
                guard case .type(let container) = lifted.content else { throw Error.malformedBlock(target.id) }
                let last = children(container).last
                let group: YType
                if let last, case .type(let type) = last.content, type.typeRef == .xmlElement(nodeName: "blockGroup") {
                    group = type
                } else {
                    group = YType(typeRef: .xmlElement(nodeName: "blockGroup"))
                    guard try YWrite.insertAfter(tx, into: container, after: last, [.type(group)]) != nil else {
                        throw Error.malformedBlock(target.id)
                    }
                }
                var left = children(group).last
                for copy in followingCopies { left = try insertCopy(tx, copy, into: group, after: left) }
            }
            for item in following { item.delete(tx) }
            target.item.delete(tx)
            if children(target.group).isEmpty { groupItem.delete(tx) }
        }
    }
}
