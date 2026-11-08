/// One endpoint in a surface's selection. Offsets are block-relative UTF-16
/// units. Negative `assoc` sticks to the character before the boundary; zero
/// or positive sticks to the character after it (including end-of-text).
/// A capture inside a surrogate pair is rejected rather than silently snapped.
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
    private let isElementAnchor: Bool

    init(_ position: EditorPosition, index: BlockIndex) throws {
        guard index.isCanonical, let entry = index.entries[position.blockID],
            entry.isProjectable, position.offset >= 0
        else { throw DocumentEngineError.invalidPosition }
        blockID = position.blockID
        if let text = entry.textType {
            guard UInt(position.offset) <= text.length else { throw DocumentEngineError.invalidPosition }
            let units = entry.runs.flatMap { Array($0.text.utf16) }
            if position.offset > 0, position.offset < units.count,
                UTF16.isLeadSurrogate(units[position.offset - 1]), UTF16.isTrailSurrogate(units[position.offset])
            {
                throw DocumentEngineError.invalidPosition
            }
            relative = try YRelativePosition.fromTypeIndex(text, index: UInt(position.offset), assoc: position.assoc)
            isElementAnchor = false
        } else {
            // An empty text-capable element has no XmlText yet. Anchor on the
            // element itself without authoring anything: the writer creates its
            // text on commit. Affinity then chooses start/end of that new text.
            guard position.offset == 0, entry.isSimpleContainer, let element = entry.element,
                element.length == 0, case .xmlElement(let node)? = element.typeRef,
                BlockNoteWriter.propSchemas[node] != nil
            else { throw DocumentEngineError.invalidPosition }
            relative = try YRelativePosition.fromTypeIndex(element, index: 0, assoc: position.assoc)
            isElementAnchor = true
        }
    }

    /// Identity is essential: a type change, a new container under the same id,
    /// or a block becoming opaque must not retarget an old caret or composition.
    func resolve(in doc: YDoc, index: BlockIndex) -> EditorPosition? {
        guard index.isCanonical, let entry = index.entries[blockID], entry.isProjectable,
            let absolute = try? relative.resolve(in: doc), !entry.containerItem.deleted
        else { return nil }
        let offset: Int
        if isElementAnchor {
            guard let element = entry.element, absolute.type === element, !(element.item?.deleted ?? true) else {
                return nil
            }
            if let text = entry.textType, !(text.item?.deleted ?? true), let length = Int(exactly: text.length) {
                offset = absolute.assoc < 0 ? 0 : length
            } else {
                guard element.length == 0 else { return nil }
                offset = 0
            }
        } else {
            guard let text = entry.textType, absolute.type === text, !(text.item?.deleted ?? true),
                let index = Int(exactly: absolute.index)
            else { return nil }
            offset = index
        }
        return EditorPosition(blockID: blockID, offset: offset, assoc: absolute.assoc)
    }
}

/// A same-block replacement range captured before composition. Both endpoints
/// resolve independently against the current replica, so a deleted or replaced
/// target resolves to nil instead of redirecting into a new text under the same
/// block id. A collapsed range keeps the insertion affinity; a non-empty range
/// keeps text a peer inserts at either boundary outside the replaced span.
struct RelativeEditorRange {
    let blockID: String
    let start: RelativeEditorPosition
    let end: RelativeEditorPosition

    init(blockID: String, range: Range<Int>, assoc: Int = -1, index: BlockIndex) throws {
        guard range.lowerBound >= 0, range.upperBound >= range.lowerBound else {
            throw DocumentEngineError.invalidPosition
        }
        self.blockID = blockID
        if range.isEmpty {
            let position = EditorPosition(blockID: blockID, offset: range.lowerBound, assoc: assoc)
            start = try RelativeEditorPosition(position, index: index)
            end = start
        } else {
            // The start follows text inserted at it and the end stays before
            // text inserted at it: a peer's boundary insertion is not part of
            // what the user selected, so it survives the replacement.
            start = try RelativeEditorPosition(
                EditorPosition(blockID: blockID, offset: range.lowerBound, assoc: 0), index: index)
            end = try RelativeEditorPosition(
                EditorPosition(blockID: blockID, offset: range.upperBound, assoc: -1), index: index)
        }
    }

    func resolve(in doc: YDoc, index: BlockIndex) -> Range<Int>? {
        guard let start = start.resolve(in: doc, index: index),
            let end = end.resolve(in: doc, index: index),
            start.blockID == end.blockID
        else { return nil }
        // A peer deleting the whole selected span can resolve the endpoints
        // crossed; the replacement then collapses to an insertion at the start.
        return start.offset..<max(start.offset, end.offset)
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
