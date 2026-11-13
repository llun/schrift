/// One endpoint in a surface's selection. Offsets are block-relative UTF-16
/// units. Negative `assoc` sticks to the character before the boundary; zero
/// or positive sticks to the character after it (including end-of-text).
/// A capture inside a surrogate pair is rejected rather than silently snapped.
struct EditorPosition: Equatable, Sendable {
    var blockID: String
    var offset: Int
    var assoc: Int = -1
}

/// Endpoints retain their direction; anchor may follow head, including across
/// blocks. A collapsed selection has equal endpoints.
struct EditorSelection: Equatable, Sendable {
    var anchor: EditorPosition
    var head: EditorPosition
}

/// Only locally captured positions enter the engine. Never resolve a peer's
/// arbitrary root name here: `YRelativePosition.resolve` can create that root.
struct RelativeEditorPosition {
    let blockID: String
    let relative: YRelativePosition
    private enum Anchor {
        /// In a text: the block's own, or one part of a cell paragraph.
        case text
        /// On an empty element, with no text yet.
        case element
        /// Between a cell paragraph's parts (next to a hard break).
        case child
    }
    private let anchor: Anchor

    init(_ position: EditorPosition, index: BlockIndex) throws {
        guard index.isCanonical, let entry = index.entries[position.blockID],
            entry.isProjectable, position.offset >= 0
        else { throw DocumentEngineError.invalidPosition }
        blockID = position.blockID
        let units = entry.runs.flatMap { Array($0.text.utf16) }
        if position.offset > 0, position.offset < units.count,
            UTF16.isLeadSurrogate(units[position.offset - 1]), UTF16.isTrailSurrogate(units[position.offset])
        {
            throw DocumentEngineError.invalidPosition
        }
        if let text = entry.textType {
            guard UInt(position.offset) <= text.length else { throw DocumentEngineError.invalidPosition }
            relative = try YRelativePosition.fromTypeIndex(text, index: UInt(position.offset), assoc: position.assoc)
            anchor = .text
        } else if let element = entry.element, element.length > 0,
            entry.hasInlineObjects
                || (element.typeRef == .xmlElement(nodeName: "tableParagraph")
                    && index.isTableParagraph(position.blockID))
        {
            // A mixed-inline block or cell paragraph: in the text part that
            // holds the offset, else between parts on the element.
            let parts = Self.parts(of: element)
            guard position.offset <= parts.last.map({ $0.start + $0.width }) ?? 0 else {
                throw DocumentEngineError.invalidPosition
            }
            if let part = parts.first(where: {
                $0.type.typeRef == .xmlText && $0.start <= position.offset && position.offset <= $0.start + $0.width
            }) {
                relative = try YRelativePosition.fromTypeIndex(
                    part.type, index: UInt(position.offset - part.start), assoc: position.assoc)
                anchor = .text
            } else {
                let child = parts.filter { $0.start + $0.width <= position.offset }.count
                relative = try YRelativePosition.fromTypeIndex(element, index: UInt(child), assoc: position.assoc)
                anchor = .child
            }
        } else {
            // An empty text-capable element has no XmlText yet. Anchor on the
            // element itself without authoring anything: the writer creates its
            // text on commit. Affinity then chooses start/end of that new text.
            guard position.offset == 0, entry.isSimpleContainer, let element = entry.element,
                element.length == 0, case .xmlElement(let node)? = element.typeRef,
                BlockNoteWriter.nativePropSchemas[node] != nil || node == "tableParagraph"
            else { throw DocumentEngineError.invalidPosition }
            relative = try YRelativePosition.fromTypeIndex(element, index: 0, assoc: position.assoc)
            anchor = .element
        }
    }

    /// A block or cell paragraph's countable children with their UTF-16 starts
    /// (any non-text part — inline chip or hard break — is one unit wide).
    static func parts(of element: YType) -> [(type: YType, start: Int, width: Int)] {
        var parts: [(type: YType, start: Int, width: Int)] = []
        var start = 0
        for item in YBlockProjection.children(of: element, includeFormats: false) {
            guard case .type(let type) = item.content else { continue }
            let width = type.typeRef == .xmlText ? Int(type.length) : 1
            parts.append((type, start, width))
            start += width
        }
        return parts
    }

    /// Identity is essential: a type change, a new container under the same id,
    /// or a block becoming opaque must not retarget an old caret or composition.
    func resolve(in doc: YDoc, index: BlockIndex) -> EditorPosition? {
        guard index.isCanonical, let entry = index.entries[blockID], entry.isProjectable,
            let absolute = try? relative.resolve(in: doc), !entry.containerItem.deleted
        else { return nil }
        let offset: Int
        switch anchor {
        case .element:
            guard let element = entry.element, absolute.type === element, !(element.item?.deleted ?? true) else {
                return nil
            }
            if let text = entry.textType, !(text.item?.deleted ?? true), let length = Int(exactly: text.length) {
                offset = absolute.assoc < 0 ? 0 : length
            } else {
                guard element.length == 0 else { return nil }
                offset = 0
            }
        case .text:
            guard let inText = Int(exactly: absolute.index), !(absolute.type.item?.deleted ?? true) else { return nil }
            if let text = entry.textType, absolute.type === text {
                offset = inText
            } else if entry.isSimpleContainer,
                entry.hasInlineObjects || index.isTableParagraph(blockID),
                let element = entry.element,
                absolute.type.item?.parentType === element,
                let part = Self.parts(of: element).first(where: { $0.type === absolute.type })
            {
                // A text part of a mixed-inline block or cell paragraph.
                offset = part.start + inText
            } else {
                return nil
            }
        case .child:
            guard entry.isSimpleContainer,
                entry.textType != nil || entry.hasInlineObjects || index.isTableParagraph(blockID)
                    || entry.element?.length == 0,
                let element = entry.element, absolute.type === element, let child = Int(exactly: absolute.index)
            else { return nil }
            offset = Self.parts(of: element).prefix(child).reduce(0) { $0 + $1.width }
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
