import Foundation

// MARK: - HTML DOM

/// A tolerant, bounded HTML tree shared by table clipboard parsing and general
/// HTML block pasting. Raw-text elements (`script`, `style`, `title`,
/// `textarea`, `template`) keep no content, void elements never nest, cells,
/// rows, list items and paragraphs carry implied end tags, and an end tag
/// closes up to its open element (or is ignored). Bounded by
/// `TableClipboard.maxNodes` and `TableClipboard.maxDepth`: returns `nil` past
/// either, so a hostile paste cannot exhaust memory or the stack.
final class HTMLNode {
    let name: String  // lowercased tag; "#text" for text
    var attributes: [String: String] = [:]
    var text = ""
    var children: [HTMLNode] = []
    weak var parent: HTMLNode?

    init(name: String) { self.name = name }

    static let void: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr",
    ]
    static let rawText: Set<String> = ["script", "style", "title", "textarea", "template"]

    private static let closesParagraph: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "blockquote", "pre", "hr", "table", "div",
        "section", "article", "header", "footer", "nav", "aside", "main", "figure", "dl", "form",
    ]

    /// ASCII whitespace scalars (HTML's collapsible whitespace set). Checking
    /// scalars rather than Swift `Character`s handles CRLF (`\r\n`), which is a
    /// single extended grapheme cluster in Swift.
    static func isASCIIWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar == "\u{0C}"
    }

    static func parse(_ html: String, blockImpliedEndTags: Bool = false) -> HTMLNode? {
        let root = HTMLNode(name: "#document")
        var stack = [root]
        var nodes = 0
        let scalars = Array(html.unicodeScalars)
        var index = 0
        var text = ""
        func flush() {
            guard !text.isEmpty else { return }
            let node = HTMLNode(name: "#text")
            node.text = decode(text)
            node.parent = stack.last
            stack.last!.children.append(node)
            text = ""
            nodes += 1
        }
        func close(_ name: String) {
            guard let position = stack.lastIndex(where: { $0.name == name }), position > 0 else { return }
            stack.removeSubrange(position...)
        }
        while index < scalars.count {
            guard nodes <= TableClipboard.maxNodes else { return nil }
            let scalar = scalars[index]
            guard scalar == "<" else {
                text.unicodeScalars.append(scalar)
                index += 1
                continue
            }
            // A comment, doctype or processing instruction: skipped.
            if index + 1 < scalars.count, scalars[index + 1] == "!" || scalars[index + 1] == "?" {
                flush()
                let isComment =
                    index + 3 < scalars.count && scalars[index + 2] == "-" && scalars[index + 3] == "-"
                var end = index + 2
                if isComment {
                    while end + 2 < scalars.count,
                        !(scalars[end] == "-" && scalars[end + 1] == "-" && scalars[end + 2] == ">")
                    {
                        end += 1
                    }
                    index = min(scalars.count, end + 3)
                } else {
                    while end < scalars.count, scalars[end] != ">" { end += 1 }
                    index = min(scalars.count, end + 1)
                }
                continue
            }
            let closing = index + 1 < scalars.count && scalars[index + 1] == "/"
            var cursor = index + (closing ? 2 : 1)
            var name = ""
            while cursor < scalars.count,
                scalars[cursor].properties.isAlphabetic || ("0"..."9").contains(scalars[cursor])
            {
                name.unicodeScalars.append(scalars[cursor])
                cursor += 1
            }
            guard !name.isEmpty else {
                text.unicodeScalars.append(scalar)
                index += 1
                continue
            }
            flush()
            name = name.lowercased()
            // Attributes up to the tag's end.
            var attributes: [String: String] = [:]
            var selfClosing = false
            while cursor < scalars.count, scalars[cursor] != ">" {
                let current = scalars[cursor]
                if current == "/" {
                    selfClosing = true
                    cursor += 1
                    continue
                }
                if current.properties.isWhitespace {
                    cursor += 1
                    continue
                }
                var key = ""
                while cursor < scalars.count, !scalars[cursor].properties.isWhitespace, scalars[cursor] != "=",
                    scalars[cursor] != ">", scalars[cursor] != "/"
                {
                    key.unicodeScalars.append(scalars[cursor])
                    cursor += 1
                }
                while cursor < scalars.count, scalars[cursor].properties.isWhitespace { cursor += 1 }
                var value = ""
                if cursor < scalars.count, scalars[cursor] == "=" {
                    cursor += 1
                    while cursor < scalars.count, scalars[cursor].properties.isWhitespace { cursor += 1 }
                    if cursor < scalars.count, scalars[cursor] == "\"" || scalars[cursor] == "'" {
                        let quote = scalars[cursor]
                        cursor += 1
                        while cursor < scalars.count, scalars[cursor] != quote {
                            value.unicodeScalars.append(scalars[cursor])
                            cursor += 1
                        }
                        cursor += 1
                    } else {
                        while cursor < scalars.count, !scalars[cursor].properties.isWhitespace, scalars[cursor] != ">" {
                            value.unicodeScalars.append(scalars[cursor])
                            cursor += 1
                        }
                    }
                }
                if !key.isEmpty, attributes[key.lowercased()] == nil, attributes.count < 64 {
                    attributes[key.lowercased()] = decode(value)
                }
            }
            index = min(scalars.count, cursor + 1)
            if closing {
                if name == "br" {
                    // `</br>` is a break, as browsers read it.
                    let node = HTMLNode(name: "br")
                    node.parent = stack.last
                    stack.last!.children.append(node)
                    nodes += 1
                } else {
                    close(name)
                }
                continue
            }
            // Implied end tags: a cell closes the open cell, a row the open
            // row; table mode only closes an open paragraph on `<p>`, while
            // block-paste mode also closes `<li>` on `<li>` and `<p>` on block tags.
            switch name {
            case "td", "th":
                if let open = stack.lastIndex(where: { ["td", "th", "tr", "table"].contains($0.name) }),
                    ["td", "th"].contains(stack[open].name)
                {
                    stack.removeSubrange(open...)
                }
            case "tr":
                if let open = stack.lastIndex(where: { ["tr", "table"].contains($0.name) }), stack[open].name == "tr" {
                    stack.removeSubrange(open...)
                }
            case "li" where blockImpliedEndTags:
                if let open = stack.lastIndex(where: { ["li", "ul", "ol"].contains($0.name) }), stack[open].name == "li"
                {
                    stack.removeSubrange(open...)
                }
            case "a" where blockImpliedEndTags:
                if let open = stack.lastIndex(where: {
                    $0.name == "a" || $0.name == "td" || $0.name == "th" || $0.name == "li"
                        || Self.closesParagraph.contains($0.name)
                }),
                    stack[open].name == "a"
                {
                    // Only the open link stops being a parent; formatting and containers opened inside it stay open.
                    stack.remove(at: open)
                }
            case "p" where !blockImpliedEndTags:
                if let open = stack.lastIndex(where: { ["p", "td", "th", "table", "div"].contains($0.name) }),
                    stack[open].name == "p"
                {
                    stack.removeSubrange(open...)
                }
            default:
                if blockImpliedEndTags, Self.closesParagraph.contains(name),
                    let open = stack.lastIndex(where: {
                        ["p", "td", "th", "table", "div", "li", "blockquote"].contains($0.name)
                    }),
                    stack[open].name == "p"
                {
                    stack.removeSubrange(open...)
                }
            }
            let node = HTMLNode(name: name)
            node.attributes = attributes
            node.parent = stack.last
            stack.last!.children.append(node)
            nodes += 1
            if rawText.contains(name) {
                // Skip to the matching end tag; the content is not markup.
                let end = Array("</\(name)".unicodeScalars)
                var probe = index
                while probe < scalars.count {
                    if scalars[probe] == "<", probe + end.count <= scalars.count,
                        String(String.UnicodeScalarView(scalars[probe..<(probe + end.count)])).lowercased()
                            == String(String.UnicodeScalarView(end))
                    {
                        break
                    }
                    probe += 1
                }
                while probe < scalars.count, scalars[probe] != ">" { probe += 1 }
                index = min(scalars.count, probe + 1)
                continue
            }
            if !selfClosing, !void.contains(name) {
                guard stack.count < TableClipboard.maxDepth else { return nil }
                stack.append(node)
            }
        }
        flush()
        return nodes <= TableClipboard.maxNodes ? root : nil
    }

    /// Character references: the common named ones and numeric ones.
    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "copy": "©", "reg": "®",
            "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
            "bull": "•", "trade": "™", "euro": "€", "middot": "·", "times": "×",
        ]
        var out = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semicolon = after.prefix(12).firstIndex(of: ";") {
                let entity = after[..<semicolon]
                var decoded: String?
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    decoded = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
                } else if entity.hasPrefix("#") {
                    decoded = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
                } else {
                    decoded = named[String(entity)]
                }
                if let decoded, decoded != "\u{0}" {
                    out += decoded
                    rest = after[after.index(after: semicolon)...]
                    continue
                }
            }
            out += "&"
            rest = after
        }
        return out + rest
    }

    /// The `style` attribute's declarations, by lowercased property.
    var style: [String: String] {
        guard let style = attributes["style"] else { return [:] }
        var out: [String: String] = [:]
        for declaration in style.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            out[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = parts[1].trimmingCharacters(
                in: .whitespaces)
        }
        return out
    }

    /// The document's one top-level table, when nothing but whitespace (and
    /// head content) lies outside it; else nil (not cells).
    func onlyTable() -> HTMLNode? {
        var tables: [HTMLNode] = []
        var outside = false
        func walk(_ node: HTMLNode) {
            for child in node.children {
                if child.name == "table" {
                    tables.append(child)
                } else if child.name == "#text" {
                    if child.text.unicodeScalars.contains(where: { !HTMLNode.isASCIIWhitespace($0) }) { outside = true }
                } else if !HTMLNode.rawText.contains(child.name), child.name != "head" {
                    walk(child)
                }
            }
        }
        walk(self)
        return tables.count == 1 && !outside ? tables[0] : nil
    }

    /// The table's rows (through `thead`, `tbody`, `tfoot`), not a nested table's.
    func rows() -> [HTMLNode] {
        var out: [HTMLNode] = []
        func walk(_ node: HTMLNode) {
            for child in node.children {
                switch child.name {
                case "tr": out.append(child)
                case "thead", "tbody", "tfoot": walk(child)
                default: break
                }
            }
        }
        walk(self)
        return out
    }
}

// MARK: - Shared HTML inline marks & cell flattener

/// `parseTableContent`: a cell's content parsed as blocks, then every inline
/// node concatenated into one paragraph, with ProseMirror's whitespace
/// collapsing and the schema's mark parse rules. `addedMarks(for:current:)` is
/// also shared by `BlockNoteHTMLParser` so inline mark mapping lives in one place.
enum InlineFlattener {
    static let blocks: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "ul", "ol", "blockquote", "pre", "table", "tr", "td",
        "th", "thead", "tbody", "tfoot", "section", "article", "header", "footer", "figure", "dl", "dt", "dd", "hr",
    ]
    static let ignored: Set<String> = ["img", "video", "audio", "iframe", "svg", "object", "input", "select", "button"]

    static func runs(_ cell: HTMLNode, paletteColorsOnly: Bool = false) -> [InlineRun] {
        var runs: [InlineRun] = []
        var paragraphOpen = false
        var lastWasSpaceOrBreak = true
        func append(_ text: String, _ marks: [(key: String, valueJSON: String)]) {
            if let last = runs.last, InlineRun("", marks: last.marks) == InlineRun("", marks: marks) {
                runs[runs.count - 1].text += text
            } else {
                runs.append(InlineRun(text, marks: marks))
            }
        }
        func endParagraph() {
            if paragraphOpen, let last = runs.indices.last, runs[last].text.hasSuffix(" ") {
                runs[last].text.removeLast()
                if runs[last].text.isEmpty { runs.removeLast() }
            }
            paragraphOpen = false
            lastWasSpaceOrBreak = true
        }
        func walk(_ node: HTMLNode, _ marks: [(key: String, valueJSON: String)]) {
            for child in node.children {
                if child.name == "#text" {
                    var scalars = String.UnicodeScalarView()
                    var inSpace = false
                    for scalar in child.text.unicodeScalars {
                        if scalar.value == 0xFFFC { continue }
                        if HTMLNode.isASCIIWhitespace(scalar) {
                            inSpace = true
                        } else {
                            if inSpace { scalars.append(" ") }
                            inSpace = false
                            scalars.append(scalar)
                        }
                    }
                    if inSpace { scalars.append(" ") }
                    var text = String(scalars)
                    if text == " ", !paragraphOpen { continue }
                    if text.hasPrefix(" "), lastWasSpaceOrBreak { text.removeFirst() }
                    guard !text.isEmpty else { continue }
                    paragraphOpen = true
                    append(text, marks)
                    lastWasSpaceOrBreak = text.hasSuffix(" ")
                } else if child.name == "br" {
                    paragraphOpen = true
                    if let last = runs.indices.last, runs[last].text.hasSuffix(" ") {
                        runs[last].text.removeLast()
                        if runs[last].text.isEmpty { runs.removeLast() }
                    }
                    append("\n", [])
                    lastWasSpaceOrBreak = true
                } else if ignored.contains(child.name) || HTMLNode.rawText.contains(child.name) {
                    continue
                } else if blocks.contains(child.name) {
                    endParagraph()
                    walk(child, marks)
                    endParagraph()
                } else {
                    walk(child, marks + addedMarks(for: child, current: marks, paletteColorsOnly: paletteColorsOnly))
                }
            }
        }
        walk(cell, [])
        endParagraph()
        return runs
    }

    /// The marks an inline element adds (TipTap's and BlockNote's `parseHTML`
    /// rules); a mark already in force is not added twice. When
    /// `paletteColorsOnly` is true (general block paste), only BlockNote
    /// palette colour names on `data-style-type` spans are kept; table
    /// clipboard parsing keeps any `data-value` (up to 64 chars) as before.
    static func addedMarks(
        for element: HTMLNode, current: [(key: String, valueJSON: String)], paletteColorsOnly: Bool = false
    ) -> [(key: String, valueJSON: String)] {
        var out: [(key: String, valueJSON: String)] = []
        func add(_ key: String, _ value: String = "{}") {
            if !current.contains(where: { $0.key == key }), !out.contains(where: { $0.key == key }) {
                out.append((key, value))
            }
        }
        let style = element.style
        switch element.name {
        case "strong": add("bold")
        case "b" where style["font-weight"]?.lowercased() != "normal": add("bold")
        case "em": add("italic")
        case "i" where style["font-style"]?.lowercased() != "normal": add("italic")
        case "u": add("underline")
        case "s", "del", "strike": add("strike")
        case "code": add("code")
        case "a":
            if let href = element.attributes["href"],
                href.utf16.count <= MediaBlock.maxURL,
                sanitizedLinkURL(href) == href
            {
                add("link", NativeMark.linkValue(href))
            }
        case "span":
            if let type = element.attributes["data-style-type"], type == "textColor" || type == "backgroundColor",
                let value = element.attributes["data-value"]
            {
                if paletteColorsOnly {
                    let trimmed = value.trimmingCharacters(in: .whitespaces)
                    if NativeMark.colors.contains(trimmed) {
                        add(type, NativeMark.colorValue(trimmed))
                    }
                } else {
                    add(type, NativeMark.colorValue(String(value.prefix(64))))
                }
            }
        default: break
        }
        if let weight = style["font-weight"]?.lowercased(),
            weight == "bold" || weight == "bolder" || (Int(weight).map { $0 >= 500 } ?? false)
        {
            add("bold")
        }
        if style["font-style"]?.lowercased() == "italic" { add("italic") }
        if let decoration = style["text-decoration"]?.lowercased() ?? style["text-decoration-line"]?.lowercased() {
            if decoration.contains("underline") { add("underline") }
            if decoration.contains("line-through") { add("strike") }
        }
        return out
    }
}
