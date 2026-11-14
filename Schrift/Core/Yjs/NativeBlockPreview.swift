import Foundation

/// A bounded, read-only summary of a block the native editor does not author
/// yet (PR06e): media, tables, columns, math and diagram source, and any
/// unknown or opaque node. It is read from the replica together with the
/// block (`NativeBlockProjection.projectBlock`), so a peer's edit inside a
/// table reaches the surface as the same `.replaceBlock` that already carries
/// the block. Every read is capped (`Limits`): a 10,000-row table costs a walk
/// of its row list, never 10,000 cells of text. Never a write-back source.
enum NativeBlockPreview: Equatable, Sendable {
    /// BlockNote's `image` with its preview shown. `previewWidth` is the
    /// web's displayed width in points, when set.
    case image(url: String, alt: String, previewWidth: Double?)
    /// `video`, `audio`, `file`, `pdf`, an image whose preview is hidden or
    /// that has no url yet, or another client's `uploadLoader` (PR13a).
    case file(node: String, name: String, url: String)
    /// The first `maxRows` × `maxColumns` cells and the full table size.
    case table(cells: [[String]], rowCount: Int, columnCount: Int)
    /// Each of the first `maxColumns` columns: its first `maxColumnLines`
    /// blocks, each one line of text (or its node name when it has none).
    case columns([[ColumnLine]], columnCount: Int)
    /// A math block or a diagram: its first `maxSourceLines` source lines.
    /// No renderer (owner decision); the source is the preview.
    case source(node: String, lines: [String], lineCount: Int)
    /// Anything else, labelled by its node name, with a line of its text.
    case preserved(node: String, summary: String)

    struct ColumnLine: Equatable, Sendable {
        var node: String
        var text: String
    }

    enum Limits {
        static let maxRows = 6
        static let maxColumns = 4
        static let maxColumnLines = 3
        static let maxSourceLines = 4
        /// UTF-16 units kept per cell, line or summary.
        static let maxText = 80
    }

    /// The blocks the native surface renders as text; everything else, and
    /// any opaque block, is a preview (`AttributedDocumentProjection.isPlaceholder`).
    static let proseNodes: Set<String> = [
        "paragraph", "heading", "bulletListItem", "numberedListItem", "checkListItem", "codeBlock", "quote",
        "callout", "divider", "pageBreak", "toggleListItem",
    ]

    static let fileNodes: Set<String> = ["video", "audio", "file", "pdf"]

    /// The preview of `block`, read from its container `item`; nil for a
    /// block the surface renders as text. Total: an unexpected shape is a
    /// `.preserved` preview, never a trap.
    static func read(_ item: YItem, block: ProjectedBlock) -> NativeBlockPreview? {
        guard block.fidelity.isOpaque || !proseNodes.contains(block.node) else { return nil }
        guard case .type(let container) = item.content else { return .preserved(node: block.node, summary: "") }
        // A column list is its own container; any other block's content is
        // its container's first element.
        let element =
            container.typeRef == .xmlElement(nodeName: "columnList")
            ? container
            : YBlockProjection.children(of: container, includeFormats: false).lazy.compactMap { child -> YType? in
                guard case .type(let type) = child.content, case .xmlElement = type.typeRef else { return nil }
                return type
            }.first
        func prop(_ key: String) -> String? {
            if case .string(let value)? = block.props.first(where: { $0.key == key })?.value { return value }
            return nil
        }
        switch block.node {
        case "image" where prop("url")?.isEmpty != false:
            // Nothing to show yet: the web's "add image" placeholder (PR13a).
            return .file(node: "image", name: clipped(prop("name") ?? ""), url: "")
        case MediaBlock.uploadLoader:
            // Another client's upload in progress (PR13a): shown, never acted on.
            return .file(node: block.node, name: clipped(prop("blockUploadName") ?? ""), url: "")
        case "image" where block.props.first(where: { $0.key == "showPreview" })?.value != .bool(false):
            let caption = prop("caption") ?? ""
            return .image(
                url: prop("url") ?? "", alt: clipped(caption.isEmpty ? prop("name") ?? "" : caption),
                previewWidth: number(block.props.first { $0.key == "previewWidth" }?.value))
        case "image":
            return .file(node: "image", name: clipped(prop("name") ?? ""), url: prop("url") ?? "")
        case let node where fileNodes.contains(node):
            return .file(node: node, name: clipped(prop("name") ?? ""), url: prop("url") ?? "")
        case "table":
            guard let element else { return .preserved(node: block.node, summary: "") }
            return table(element)
        case "columnList":
            guard let element else { return .preserved(node: block.node, summary: "") }
            return columns(element)
        case "mathBlock",
            "diagram" where !block.fidelity.isOpaque:
            if let element, SourceBlock.isFamiliar(element) {
                return exactSourcePreview(node: block.node, element: element)
            }
            let summary = element.map { text(of: $0, limit: Limits.maxText) } ?? ""
            return .preserved(
                node: block.node, summary: clipped(summary.replacingOccurrences(of: "\n", with: " ")))
        default:
            let summary = element.map { text(of: $0, limit: Limits.maxText) } ?? ""
            return .preserved(
                node: block.node, summary: clipped(summary.replacingOccurrences(of: "\n", with: " ")))
        }
    }

    private static func table(_ table: YType) -> NativeBlockPreview {
        var cells: [[String]] = []
        var rowCount = 0
        var columnCount = 0
        for row in elements(of: table) {
            let rowCells = elements(of: row)
            columnCount = max(columnCount, rowCells.count)
            if rowCount < Limits.maxRows {
                cells.append(rowCells.prefix(Limits.maxColumns).map { clipped(text(of: $0, limit: Limits.maxText)) })
            }
            rowCount += 1
        }
        return .table(cells: cells, rowCount: rowCount, columnCount: columnCount)
    }

    private static func columns(_ list: YType) -> NativeBlockPreview {
        let columns = elements(of: list)
        let lines = columns.prefix(Limits.maxColumns).map { column in
            elements(of: column).prefix(Limits.maxColumnLines).map { container -> ColumnLine in
                let content = elements(of: container).first
                let node: String
                if case .xmlElement(let name)? = content?.typeRef { node = name } else { node = "" }
                let line = content.map { text(of: $0, limit: Limits.maxText) } ?? ""
                return ColumnLine(node: node, text: clipped(line.replacingOccurrences(of: "\n", with: " ")))
            }
        }
        return .columns(lines, columnCount: columns.count)
    }

    /// Reads exact raw lines from a familiar `mathBlock` or `diagram`, preserving
    /// leading indentation and internal/trailing blank lines. Empty source
    /// returns `lines: [], lineCount: 0`.
    private static func exactSourcePreview(node: String, element: YType) -> NativeBlockPreview {
        let children = YBlockProjection.children(of: element, includeFormats: false)
        guard let first = children.first, case .type(let text) = first.content, text.typeRef == .xmlText else {
            return .source(node: node, lines: [], lineCount: 0)
        }
        var lines: [[UInt16]] = []
        var currentLine: [UInt16] = []
        var lineCount = 1
        var hasAnyUnit = false
        for child in YBlockProjection.children(of: text, includeFormats: false) {
            guard case .string(let units) = child.content else { continue }
            for unit in units where unit != 0xFFFC {
                hasAnyUnit = true
                if unit == 0x0A {
                    if lines.count < Limits.maxSourceLines {
                        lines.append(currentLine)
                        currentLine.removeAll(keepingCapacity: true)
                    }
                    lineCount += 1
                } else if lines.count < Limits.maxSourceLines, currentLine.count < Limits.maxText * 2 {
                    currentLine.append(unit)
                }
            }
        }
        guard hasAnyUnit else {
            return .source(node: node, lines: [], lineCount: 0)
        }
        if lines.count < Limits.maxSourceLines {
            lines.append(currentLine)
        }
        return .source(
            node: node,
            lines: lines.prefix(Limits.maxSourceLines).map { clipped(String(decoding: $0, as: UTF16.self)) },
            lineCount: lineCount)
    }

    /// Element children, in order (text and other content skipped).
    private static func elements(of type: YType) -> [YType] {
        YBlockProjection.children(of: type, includeFormats: false).compactMap { item in
            guard case .type(let child) = item.content, case .xmlElement = child.typeRef else { return nil }
            return child
        }
    }

    /// The visible text under `type`, block elements on their own lines,
    /// stopping once `limit` UTF-16 units are read.
    private static func text(of type: YType, limit: Int) -> String {
        var units: [UInt16] = []
        func walk(_ type: YType, depth: Int) {
            guard depth < 32 else { return }
            for item in YBlockProjection.children(of: type, includeFormats: false) where units.count < limit {
                switch item.content {
                case .string(let string):
                    units += string.filter { $0 != 0xFFFC }.prefix(limit - units.count)
                case .type(let child):
                    if child.typeRef == .xmlText {
                        walk(child, depth: depth + 1)
                    } else if let inline = NativeInlineObject.read(child) {
                        units += inline.clippedVisibleText().utf16.prefix(limit - units.count)
                    } else {
                        let before = units.count
                        walk(child, depth: depth + 1)
                        // Separate block-level siblings ("tableParagraph", nested blocks).
                        if units.count > before, units.count < limit, child.typeRef != .xmlElement(nodeName: "math") {
                            units.append(10)
                        }
                    }
                default: break
                }
            }
        }
        walk(type, depth: 0)
        return String(decoding: units, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// At most `maxText` UTF-16 units, ending on a whole character.
    private static func clipped(_ text: String) -> String {
        guard text.utf16.count > Limits.maxText else { return text }
        var result = ""
        for character in text {
            guard result.utf16.count + character.utf16.count < Limits.maxText else { break }
            result.append(character)
        }
        return result + "…"
    }

    /// BlockNote writes numbers as JS numbers: a varint or a float64.
    private static func number(_ value: YAnyValue?) -> Double? {
        switch value {
        case .int(let value)?: return Double(value)
        case .float64(let data)? where data.count == 8:
            let bits = data.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let value = Double(bitPattern: bits)
            return value.isFinite ? value : nil
        default: return nil
        }
    }
}
