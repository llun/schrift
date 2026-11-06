/// One endpoint in a surface's selection. Offsets are block-relative UTF-16
/// units. Negative `assoc` sticks to the character before the boundary; zero
/// or positive sticks to the character after it (including end-of-text).
struct EditorPosition: Equatable {
    var blockID: String
    var offset: Int
    var assoc: Int = -1
}

/// Endpoints retain their direction; anchor may follow head, including across
/// blocks. A collapsed selection has equal endpoints.
struct EditorSelection: Equatable {
    var anchor: EditorPosition
    var head: EditorPosition
}

/// Only locally captured positions enter the engine. Never resolve a peer's
/// arbitrary root name here: `YRelativePosition.resolve` can create that root.
struct RelativeEditorPosition {
    let blockID: String
    let relative: YRelativePosition

    init(_ position: EditorPosition, index: BlockIndex) throws {
        guard index.isCanonical, let entry = index.entries[position.blockID],
            entry.isProjectable, let text = entry.textType,
            position.offset >= 0, UInt(position.offset) <= text.length
        else { throw DocumentEngineError.invalidPosition }
        blockID = position.blockID
        relative = try YRelativePosition.fromTypeIndex(text, index: UInt(position.offset), assoc: position.assoc)
    }

    /// Identity is essential: a type change, a new container under the same id,
    /// or a block becoming opaque must not retarget an old caret or composition.
    func resolve(in doc: YDoc, index: BlockIndex) -> EditorPosition? {
        guard index.isCanonical, let entry = index.entries[blockID], entry.isProjectable,
            let text = entry.textType, let absolute = try? relative.resolve(in: doc),
            absolute.type === text, !entry.containerItem.deleted, !(text.item?.deleted ?? true),
            let offset = Int(exactly: absolute.index)
        else { return nil }
        return EditorPosition(blockID: blockID, offset: offset, assoc: absolute.assoc)
    }
}

struct RelativeEditorSelection {
    let anchor: RelativeEditorPosition
    let head: RelativeEditorPosition

    init(_ selection: EditorSelection, index: BlockIndex) throws {
        anchor = try RelativeEditorPosition(selection.anchor, index: index)
        head = try RelativeEditorPosition(selection.head, index: index)
    }

    func resolve(in doc: YDoc, index: BlockIndex) -> EditorSelection? {
        guard let anchor = anchor.resolve(in: doc, index: index),
            let head = head.resolve(in: doc, index: index)
        else { return nil }
        return EditorSelection(anchor: anchor, head: head)
    }
}
