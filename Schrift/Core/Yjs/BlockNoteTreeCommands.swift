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
            let outer = parentItem.parentType, Self.isBlockList(outer)
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

/// PR06d's subtree commands, the same clone-and-delete rules: BlockNote 0.56's
/// `moveBlocks` (`removeAndInsertBlocks` then `insertBlocks`) for one block
/// and its subtree, `removeBlocks`, and inserting copied subtrees (duplicate,
/// paste, a new empty block). They take the container's item, not a
/// `Target`: a divider, page break or preserved table is not a type this
/// writer edits, yet it can move or go whole. The caller resolves where a
/// block lands and validates every copied block first.
extension BlockNoteWriter {
    /// Moves the block and its subtree after `left` in `group` (nil: first),
    /// as a copy of every raw value; the original goes, and so does a nested
    /// group it leaves empty. Identity is not preserved.
    @discardableResult
    func moveBlock(_ item: YItem, id: String, into group: YType, after left: YItem?) throws -> Data {
        guard !item.deleted, case .type(let container) = item.content else { throw Error.missingBlock(id) }
        let copy = try snapshot(container, block: id, depth: 0)
        return try transaction { tx in
            try insertCopy(tx, copy, into: group, after: left)
            removeBlock(tx, item)
        }
    }

    /// `removeBlocks` for one block and its subtree. A nested group left
    /// empty goes too (ProseMirror's `blockGroup` needs a child); the root
    /// group's last block is the caller's to refuse.
    @discardableResult
    func deleteBlock(_ item: YItem, id: String) throws -> Data {
        guard !item.deleted else { throw Error.missingBlock(id) }
        return try transaction { tx in removeBlock(tx, item) }
    }

    /// Inserts whole `blockContainer` copies after `left` in `group`, in one
    /// transaction; `replacing` (an empty block the copies stand in for, as
    /// ProseMirror's paste into an empty textblock) is removed after them.
    @discardableResult
    func insertBlocks(_ copies: [Copy], into group: YType, after left: YItem?, replacing: YItem? = nil) throws
        -> Data
    {
        try transaction { tx in
            var left = left
            for copy in copies { left = try insertCopy(tx, copy, into: group, after: left) }
            if let replacing { removeBlock(tx, replacing) }
        }
    }

    private func removeBlock(_ tx: YTransaction, _ item: YItem) {
        item.delete(tx)
        if let group = item.parentType, children(group).isEmpty, let groupItem = group.item,
            groupItem.parentType?.typeRef == .xmlElement(nodeName: "blockContainer")
        {
            groupItem.delete(tx)
        }
    }
}
