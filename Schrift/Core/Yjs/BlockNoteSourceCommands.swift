import Foundation

/// BlockNote 0.56's plain-content source blocks (`mathBlock` and `diagram`):
/// neither has props (`propSchema: {}`) and each holds at most one plain,
/// unmarked `YXmlText` child (`content: "plain"`).
///
/// The native projection models a **familiar** source block (empty props,
/// zero or one plain unmarked `YXmlText` child, no embeds or child elements),
/// so a document holding math or diagrams is editable; unfamiliar shapes stay
/// `.opaque` and `markdownShadow` fails closed (`nil`). Never a `codeBlock`,
/// and no `latex`, `source`, or `engine` props are ever invented.
enum SourceBlock {
    static let mathBlock = "mathBlock"
    static let diagram = "diagram"
    static let nodes: Set<String> = [mathBlock, diagram]

    /// Seed text inserted by BlockNote's `getDiagramSlashMenuItems`.
    static let defaultDiagramSource = "graph TD\n    A[Start] --> B[Stop]"

    /// Maximum UTF-16 code units accepted on paste (`NativeClipboard.maxPasteUTF16`).
    static let maxSourceUTF16 = 200_000

    static func isSource(_ node: String) -> Bool {
        nodes.contains(node)
    }

    /// Why a `mathBlock`/`diagram` element is unfamiliar; `nil` when familiar.
    static func unfamiliarReason(node: String, props: [ProjectedProp], element: YType) -> String? {
        guard nodes.contains(node) else { return "node" }
        guard props.isEmpty else { return "props" }
        let items = YBlockProjection.children(of: element, includeFormats: true)
        if items.isEmpty { return nil }
        guard items.count == 1, case .type(let text) = items[0].content, text.typeRef == .xmlText else {
            return "content"
        }
        guard text.map.values.allSatisfy(\.deleted) else { return "content" }
        for child in YBlockProjection.children(of: text, includeFormats: true) {
            guard case .string = child.content else { return "marked" }
        }
        return nil
    }

    /// Whether `element` is a familiar `mathBlock` or `diagram`.
    static func isFamiliar(_ element: YType) -> Bool {
        guard case .xmlElement(let node)? = element.typeRef,
            let props = YBlockProjection.props(of: element)
        else { return false }
        return unfamiliarReason(node: node, props: props, element: element) == nil
    }

    /// Reads the plain text of a familiar `mathBlock` or `diagram`, or `nil`
    /// when unfamiliar.
    static func plainText(of element: YType) -> String? {
        guard isFamiliar(element) else { return nil }
        let items = YBlockProjection.children(of: element, includeFormats: true)
        guard let first = items.first, case .type(let text) = first.content else { return "" }
        var result = ""
        for child in YBlockProjection.children(of: text, includeFormats: true) {
            if case .string(let units) = child.content {
                result += String(decoding: units, as: UTF16.self)
            }
        }
        return result
    }

    /// Reads the plain unmarked text of a familiar `mathBlock`, `diagram`, or
    /// `math` element up to `maxUTF16` UTF-16 code units; returns `nil` when
    /// unfamiliar or longer than `maxUTF16`.
    static func boundedPlainText(of element: YType, maxUTF16: Int) -> String? {
        guard case .xmlElement(let node)? = element.typeRef,
            isSource(node) || node == NativeInlineObject.mathNodeName,
            let props = YBlockProjection.props(of: element), props.isEmpty
        else { return nil }
        let items = YBlockProjection.children(of: element, includeFormats: true)
        if items.isEmpty { return "" }
        guard items.count == 1, case .type(let text) = items[0].content, text.typeRef == .xmlText,
            text.map.values.allSatisfy(\.deleted), text.length <= UInt(maxUTF16)
        else { return nil }
        var units: [UInt16] = []
        units.reserveCapacity(Int(text.length))
        for child in YBlockProjection.children(of: text, includeFormats: true) {
            guard case .string(let chunk) = child.content else { return nil }
            if units.count + chunk.count > maxUTF16 { return nil }
            units += chunk
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Reads a display-bounded, single-line, scrubbed summary from a `mathBlock`,
    /// `diagram`, or `math` element without materializing multi-megabyte strings.
    static func clippedDisplayText(of element: YType, limit: Int = NativeInlineObject.defaultDisplayLimit) -> String {
        guard limit > 0 else { return "" }
        let items = YBlockProjection.children(of: element, includeFormats: false)
        guard let first = items.first, case .type(let text) = first.content, text.typeRef == .xmlText else {
            return ""
        }
        let maxReadUnits = max(limit * 8, 2_048)
        var units: [UInt16] = []
        units.reserveCapacity(min(Int(text.length), maxReadUnits))
        var truncatedEarly = false
        for child in YBlockProjection.children(of: text, includeFormats: false) {
            guard case .string(let chunk) = child.content else { continue }
            let remaining = maxReadUnits - units.count
            if chunk.count > remaining {
                units += chunk.prefix(remaining)
                if let last = units.last, UTF16.isLeadSurrogate(last) { units.removeLast() }
                truncatedEarly = true
                break
            }
            units += chunk
        }
        let clipped = NativeInlineObject.clippedDisplayText(String(decoding: units, as: UTF16.self), limit: limit)
        if truncatedEarly, !clipped.hasSuffix("…") {
            return clipped + "…"
        }
        return clipped
    }

    static func maxEditableUTF16(for node: String) -> Int {
        node == NativeInlineObject.mathNodeName ? NativeInlineObject.maxMathUTF16 : maxSourceUTF16
    }

    static func isEditableSource(_ text: String, node: String) -> Bool {
        text.utf16.count <= maxEditableUTF16(for: node) && !text.unicodeScalars.contains("\u{FFFC}")
    }

    /// Extracts plain unmarked text from copied children of a `mathBlock`,
    /// `diagram`, or `math` element; `nil` when any child is an element,
    /// embed, marked run, or multiple text nodes.
    static func plainText(of copies: [BlockNoteWriter.Copy]) -> String? {
        if copies.isEmpty { return "" }
        guard copies.count == 1, case .text(let values) = copies[0] else { return nil }
        var text = ""
        for value in values {
            guard case .run(let run) = value, run.marks.isEmpty else { return nil }
            text += run.text
        }
        return text
    }

    /// Whether `text` is valid plain input for `node` (`mathBlock`, `diagram`,
    /// or inline `math`): no `U+FFFC`, no newlines except `\n` in `mathBlock`/
    /// `diagram`, and no control scalars other than `\n` and `\t` (inline `math`
    /// matches `NativeInlineObject.isPastableText`, also rejecting `\t` and bidi
    /// overrides).
    static func isValidReplacement(_ text: String, node: String) -> Bool {
        if node == NativeInlineObject.mathNodeName {
            return NativeInlineObject.isPastableText(text, limit: Int.max)
        }
        return !text.unicodeScalars.contains { scalar in
            if scalar.value == 0xFFFC { return true }
            if CharacterSet.newlines.contains(scalar) {
                return !(isSource(node) && scalar == "\n")
            }
            if scalar.value == 0x09 { return false }
            // Check Unicode Cc (.control) rather than Foundation's CharacterSet.controlCharacters,
            // which also includes Cf (.format) scalars like U+200D (ZWJ in emoji sequences).
            return scalar.properties.generalCategory == .control
        }
    }

    /// Whether an untrusted pasted `mathBlock` or `diagram` may be inserted:
    /// empty props, plain unmarked text within bounds, no `U+FFFC`, and no
    /// control scalars other than `\n` and `\t`.
    static func isPastable(node: String, props: [ProjectedProp], children: [BlockNoteWriter.Copy]) -> Bool {
        guard nodes.contains(node), props.isEmpty, let source = plainText(of: children) else { return false }
        guard source.utf16.count <= maxSourceUTF16 else { return false }
        return isValidReplacement(source, node: node)
    }
}

/// Identifies which source surface kind is open (`mathBlock`, `diagram`, or inline `math`).
enum NativeSourceKind: Equatable, Hashable, Sendable {
    case mathBlock
    case diagram
    case inlineMath

    var nodeName: String {
        switch self {
        case .mathBlock: SourceBlock.mathBlock
        case .diagram: SourceBlock.diagram
        case .inlineMath: NativeInlineObject.mathNodeName
        }
    }

    var maxUTF16: Int {
        switch self {
        case .mathBlock, .diagram: SourceBlock.maxSourceUTF16
        case .inlineMath: NativeInlineObject.maxMathUTF16
        }
    }
}

/// Identifies a source surface target: a top-level/nested/column source block
/// (`mathBlock`/`diagram`) or an inline `<math>` element inside a block.
enum SourceTarget: Equatable, Hashable, Sendable {
    case block(id: String)
    case inlineMath(blockID: String, itemID: YID)

    /// Separates the owning block/paragraph id from the source element's item
    /// id (`client.clock`) in scoped source surface block ids (PR14).
    static let separator = "\u{2}"

    var ownerID: String {
        switch self {
        case .block(let id), .inlineMath(let id, _): id
        }
    }

    func syntheticID(elementItemID: YID) -> String {
        "\(ownerID)\(Self.separator)\(elementItemID.client).\(elementItemID.clock)"
    }

    static func isSourceID(_ id: String) -> Bool {
        id.unicodeScalars.contains("\u{2}")
    }

    static func ownerID(of id: String) -> String? {
        guard let range = id.range(of: separator) else { return nil }
        return String(id[..<range.lowerBound])
    }
}

// MARK: - Writes

extension BlockNoteWriter {
    /// Slash-menu insertion of `mathBlock` or `diagram` (`insertOrUpdateBlockForSlashMenu`):
    /// `replacing` converts an empty paragraph in place (preserving its
    /// container ID and any nested group, stripping paragraph props to `{}`);
    /// otherwise inserts a new `blockContainer` with `blockID` after `item`.
    /// Unlike media blocks, never inserts a trailing paragraph.
    @discardableResult
    func insertSourceBlock(
        _ node: String, at item: YItem, in group: YType, replacing: Bool, blockID: String
    ) throws -> Data {
        guard SourceBlock.isSource(node), case .type(let container) = item.content else {
            throw Error.unsupportedBlockType(node)
        }
        let initialChildren: [Copy] =
            node == SourceBlock.diagram ? [.text([.run(InlineRun(SourceBlock.defaultDiagramSource))])] : []
        let element = children(container).first
        return try transaction { tx in
            if replacing {
                guard let element else { throw Error.malformedBlock(blockID) }
                element.delete(tx)
                _ = try insertCopy(tx, .element(node, [], initialChildren), into: container, after: nil)
            } else {
                let copy = Copy.element(
                    "blockContainer", [("id", .string(blockID))], [.element(node, [], initialChildren)])
                _ = try insertCopy(tx, copy, into: group, after: item)
            }
        }
    }

    /// Slash-menu insertion of inline `<math>` followed by a trailing space
    /// (`[{ type: "math", content: source }, " "]`).
    @discardableResult
    func insertInlineMath(
        in target: Target, replacing range: Range<Int>, source: String = "", trailingSpace: Bool = true
    ) throws -> Data {
        guard target.node != "codeBlock" else { throw Error.unsupportedBlockType(target.node) }
        var copies: [Copy] = [
            .element(NativeInlineObject.mathNodeName, [], NativeInlineObject.math(source: source).canonicalChildren)
        ]
        if trailingSpace {
            copies.append(.text([.run(InlineRun(" "))]))
        }
        return try replaceRangeWithCopies(in: target, range: range, copies: copies)
    }

    /// Ensures a plain `XmlText` child exists inside `element` (`mathBlock`,
    /// `diagram`, or `math`) when writing non-empty source text.
    func ensurePlainText(_ tx: YTransaction, in element: YType, block: String) throws -> YType {
        let existing = children(element)
        if existing.isEmpty {
            let text = YType(typeRef: .xmlText)
            guard try YWrite.insertAfter(tx, into: element, after: nil, [.type(text)]) != nil else {
                throw Error.malformedBlock(block)
            }
            return text
        }
        guard existing.count == 1, case .type(let text) = existing[0].content, text.typeRef == .xmlText else {
            throw Error.malformedBlock(block)
        }
        return text
    }

    /// Plain-content edit inside `mathBlock`, `diagram`, or inline `math`.
    /// Never writes marks or invents props; creates the `XmlText` child lazily
    /// on the first non-empty write (`ensurePlainText`).
    @discardableResult
    func replaceSourceText(in element: YType, range: Range<Int>, with text: String, block: String) throws -> Data {
        guard case .xmlElement(let node)? = element.typeRef,
            SourceBlock.isSource(node) || node == NativeInlineObject.mathNodeName
        else { throw Error.unsupportedBlockType(block) }
        let existing = children(element)
        let textType: YType?
        if existing.isEmpty {
            textType = nil
        } else if existing.count == 1, case .type(let existingText) = existing[0].content,
            existingText.typeRef == .xmlText
        {
            textType = existingText
        } else {
            throw Error.malformedBlock(block)
        }
        var units: [UInt16] = []
        if let textType {
            for child in children(textType) {
                switch child.content {
                case .string(let string): units += string
                default: throw Error.malformedBlock(block)
                }
            }
        }
        let total = units.count
        let clampedStart = min(max(0, range.lowerBound), total)
        let clampedEnd = min(max(clampedStart, range.upperBound), total)
        func snapSource(_ offset: Int, forward: Bool) -> Int {
            guard offset > 0, offset < total else { return offset }
            let splits = UTF16.isTrailSurrogate(units[offset]) && UTF16.isLeadSurrogate(units[offset - 1])
            return splits ? offset + (forward ? 1 : -1) : offset
        }
        let lower = snapSource(clampedStart, forward: false)
        let upper = clampedStart == clampedEnd ? lower : snapSource(clampedEnd, forward: true)
        return try transaction { tx in
            if let textType, lower < upper {
                try textType.delete(UInt(lower), UInt(upper - lower))
            }
            guard !text.isEmpty else { return }
            let destination = try ensurePlainText(tx, in: element, block: block)
            try destination.insert(UInt(lower), text, [:])
        }
    }
}
