import Foundation

/// BlockNote 0.56's media blocks (`image`, `video`, `audio`, `file`) and Docs'
/// `pdf` and transient `uploadLoader` (PR13a): their props in schema order,
/// when the native editor reads one, and what it may write to one.
///
/// A media block has no inline content; everything it holds is props. The
/// native projection models a **familiar** one (no content, every known prop
/// of a readable type), so a document holding media types; unknown props are
/// preserved untouched (a prop edit never writes them). `uploadLoader` is
/// another client's upload in progress: read and shown, never edited, polled
/// or replaced (the web client that wrote it finishes it).
enum MediaBlock {
    /// The media blocks the native editor authors.
    static let nodes: Set<String> = ["image", "video", "audio", "file", "pdf"]
    static let uploadLoader = "uploadLoader"

    /// Every block this file reads: the media blocks and `uploadLoader`.
    static func isMediaLike(_ node: String) -> Bool { nodes.contains(node) || node == uploadLoader }

    /// Props in schema order, the order y-prosemirror sets a new element's
    /// attributes, with their defaults (BlockNote 0.56's `propSchema`s and
    /// Docs' server `pdf`/`uploadLoader` specs).
    static let schemas: [String: [(key: String, value: YAnyValue)]] = {
        let alignment: (key: String, value: YAnyValue) = ("textAlignment", .string("left"))
        let background: (key: String, value: YAnyValue) = ("backgroundColor", .string("default"))
        let name: (key: String, value: YAnyValue) = ("name", .string(""))
        let url: (key: String, value: YAnyValue) = ("url", .string(""))
        let caption: (key: String, value: YAnyValue) = ("caption", .string(""))
        let preview: (key: String, value: YAnyValue) = ("showPreview", .bool(true))
        let width: (key: String, value: YAnyValue) = ("previewWidth", .undefined)
        let visual = [alignment, background, name, url, caption, preview, width]
        return [
            "image": visual, "video": visual,
            "audio": [background, name, url, caption, preview],
            "file": [background, name, url, caption],
            "pdf": [background, caption, name, width, preview, alignment, url],
            "uploadLoader": [
                ("information", .string("")), ("type", .string("loading")), ("blockUploadName", .string("")),
                ("blockUploadShowPreview", .bool(true)), ("blockUploadType", .string("")),
                ("blockUploadUrl", .string("")), ("blockUploadCaption", .string("")),
                ("blockUploadTextAlignment", .string("left")),
            ],
        ]
    }()

    /// The props a native edit may write, per block (a subset of its schema).
    static let editableKeys: Set<String> = ["name", "caption", "url", "previewWidth", "textAlignment", "showPreview"]
    static let alignments: Set<String> = ["left", "center", "right", "justify"]
    static let maxURL = 2048
    static let maxName = 1024
    static let maxCaption = 4096
    static let widths: ClosedRange<Double> = 1...10_000

    /// Why a media block is not one the native editor reads; nil when it is
    /// familiar. Unknown props do not count: they are preserved, never written.
    static func unfamiliarReason(node: String, props: [ProjectedProp], hasContent: Bool) -> String? {
        guard let schema = schemas[node] else { return "node" }
        if hasContent { return "content" }
        for prop in props {
            guard let field = schema.first(where: { $0.key == prop.key }) else { continue }
            switch (field.value, prop.value) {
            case (.string, .string), (.bool, .bool): continue
            case (.undefined, .undefined): continue
            case (.undefined, _) where number(prop.value) != nil: continue
            default: return "prop:\(prop.key)"
            }
        }
        return nil
    }

    /// A stored value as a string (absent: the default).
    static func string(_ key: String, in props: [ProjectedProp]) -> String {
        if case .string(let value)? = props.last(where: { $0.key == key })?.value { return value }
        return ""
    }

    /// `showPreview` (absent: true, BlockNote's default).
    static func showsPreview(_ props: [ProjectedProp]) -> Bool {
        props.last { $0.key == "showPreview" }?.value != .bool(false)
    }

    /// A JS number (lib0 writes one as an int, a float32 or a float64).
    static func number(_ value: YAnyValue?) -> Double? { value.flatMap(TableGrid.number) }

    /// What an upload started from (PR13a): the block's kind and url then.
    /// A block deleted, retyped or given another url since refuses the commit.
    struct Slot: Codable, Equatable, Sendable {
        var node: String
        var url: String
    }

    /// Whether a native edit may write `prop` to a `node` block: a key of its
    /// schema the editor edits, with a value it can safely store.
    static func isValidEdit(_ prop: ProjectedProp, on node: String) -> Bool {
        guard nodes.contains(node), editableKeys.contains(prop.key),
            schemas[node]?.contains(where: { $0.key == prop.key }) == true
        else { return false }
        switch (prop.key, prop.value) {
        // A pdf's url must be one the export spells (review V2): else the block has no shadow.
        case ("url", .string(let url)):
            return url.isEmpty || isAuthoredURL(url) && (node != "pdf" || NativeExportMarkdown.isSafePDFURL(url))
        case ("name", .string(let name)): return isPlainText(name, limit: maxName)
        case ("caption", .string(let caption)): return isPlainText(caption, limit: maxCaption)
        case ("previewWidth", .undefined): return true
        case ("previewWidth", let value): return number(value).map(widths.contains) == true
        case ("textAlignment", .string(let alignment)): return alignments.contains(alignment)
        case ("showPreview", .bool): return true
        default: return false
        }
    }

    /// A URL the native editor writes: absolute http(s) with a host, no
    /// userinfo, no whitespace or control characters, at most `maxURL` UTF-16
    /// units. Web-authored URLs are preserved whatever they hold; this is
    /// only what a native edit may store (never `javascript:`, a local path
    /// or a placeholder).
    static func isAuthoredURL(_ url: String) -> Bool {
        // Only RFC 3986 characters, each `%` a hex escape: Foundation's parser
        // may percent-encode anything else, and the string stored is the raw
        // one, so what is checked must be what is written (a non-ASCII host
        // must be typed as punycode).
        guard url.utf16.count <= maxURL, url.unicodeScalars.allSatisfy(uriCharacters.contains),
            !url.contains(/%(?![0-9A-Fa-f]{2})/),
            let components = URLComponents(string: url), let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https", let host = components.host, !host.isEmpty,
            components.user == nil, components.password == nil
        else { return false }
        return true
    }

    /// RFC 3986's unreserved and reserved characters and `%`.
    private static let uriCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")

    /// `previewWidth` as the inspector shows it: a whole number of points
    /// when the stored number is one a native edit could write, else nil
    /// (a peer's 1e20 or -1e19 is preserved, never converted).
    static func displayWidth(_ props: [ProjectedProp]) -> Int? {
        guard let width = number(props.last(where: { $0.key == "previewWidth" })?.value), widths.contains(width)
        else { return nil }
        return Int(width.rounded())
    }

    /// Whether a pasted media block (an untrusted payload) may be inserted:
    /// familiar, and every prop a native edit would also write (an http(s) or
    /// empty url, bounded name and caption, a width in range), so a paste can
    /// neither store what the inspector refuses nor leave a block without a
    /// shadow (a pdf with a non-http(s) url).
    static func isPastable(node: String, props: [ProjectedProp], hasContent: Bool) -> Bool {
        guard nodes.contains(node), unfamiliarReason(node: node, props: props, hasContent: hasContent) == nil,
            // Spelled before insertion (review V2): a paste never leaves a block without a shadow.
            NativeExportMarkdown.media(node: node, props: props) != nil
        else { return false }
        return props.allSatisfy { prop in
            switch prop.key {
            case _ where editableKeys.contains(prop.key): isValidEdit(prop, on: node)
            case "backgroundColor": prop.value.isPlainString
            default: true
            }
        }
    }

    /// A pasted url in the form a native edit stores (review V3): a web block
    /// may hold an IRI (`https://images.example/été.png`, a non-ASCII host),
    /// which is percent-encoded and punycoded here; whitespace, controls and
    /// anything that is not then an `isAuthoredURL` stay refused. Empty stays empty.
    static func pastedURL(_ url: String) -> String? {
        guard !url.isEmpty else { return url }
        if isAuthoredURL(url) { return url }
        guard
            !url.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
            }),
            let canonical = URL(string: url, encodingInvalidCharacters: true)?.absoluteString,
            isAuthoredURL(canonical)
        else { return nil }
        return canonical
    }

    /// `text` for display: at most `limit` scalars, with an ellipsis when
    /// cut (a peer may store megabytes, or one character of a million
    /// combining marks, so this never counts characters).
    static func clipped(_ text: String, limit: Int = 300) -> String {
        guard text.unicodeScalars.count > limit else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit))) + "…"
    }

    /// A name or caption: bounded, no control characters (a line break
    /// included: both are one line on the web).
    private static func isPlainText(_ text: String, limit: Int) -> Bool {
        text.utf16.count <= limit && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Blocks without editable content (BlockNote's `content: "none"`): the
    /// slash menu's cursor walks past them (`setSelectionToNextContentEditableBlock`).
    static let contentless: Set<String> = nodes.union([uploadLoader, "divider", "pageBreak", "columnList"])
}

extension YAnyValue {
    fileprivate var isPlainString: Bool {
        if case .string(let value) = self { return value.utf16.count <= MediaBlock.maxName }
        return false
    }
}

// MARK: - Writes

extension BlockNoteWriter {
    /// The slash menu's media insertion (`insertOrUpdateBlockForSlashMenu`,
    /// PR13a), the "/query" already removed: `replacing` makes the paragraph
    /// `item` the block in place (same container and id), otherwise a new
    /// container `blockID` goes after it. Then, when no following sibling
    /// takes text, an empty paragraph `paragraphID` goes after the
    /// document's last root block (`setSelectionToNextContentEditableBlock`),
    /// as on the web even from a column. One transaction.
    @discardableResult
    func insertMedia(
        _ node: String, at item: YItem, in group: YType, replacing: Bool, blockID: String, paragraphID: String?
    ) throws -> Data {
        guard let schema = MediaBlock.schemas[node], MediaBlock.nodes.contains(node),
            case .type(let container) = item.content
        else { throw Error.unsupportedBlockType(node) }
        let element = children(container).first
        return try transaction { tx in
            let media: YItem
            if replacing {
                guard let element, case .type(let paragraph) = element.content else {
                    throw Error.malformedBlock(blockID)
                }
                // BlockNote's `updateBlock` keeps the props both types share.
                let existing = YBlockProjection.props(of: paragraph) ?? []
                let props = schema.map { field in
                    (key: field.key, value: existing.last { $0.key == field.key }?.value ?? field.value)
                }
                element.delete(tx)
                _ = try insertCopy(tx, .element(node, props, []), into: container, after: nil)
                media = item
            } else {
                let copy = Copy.element("blockContainer", [("id", .string(blockID))], [.element(node, schema, [])])
                media = try insertCopy(tx, copy, into: group, after: item)
            }
            guard let paragraphID else { return }
            guard let root = doc.share[BlockNoteYjs.fragmentField], let rootGroupItem = children(root).first,
                case .type(let rootGroup) = rootGroupItem.content
            else { throw Error.malformedBlock(blockID) }
            let last = children(rootGroup).last
            let paragraph = Copy.element(
                "blockContainer", [("id", .string(paragraphID))],
                [.element("paragraph", schemas["paragraph"] ?? [], [])])
            _ = try insertCopy(tx, paragraph, into: rootGroup, after: last ?? media)
        }
    }

    /// Whether the slash insertion needs its trailing paragraph: no sibling
    /// after `item` in `group` takes text (BlockNote's cursor walk).
    func needsTrailingParagraph(after item: YItem, in group: YType) -> Bool {
        var next = item.right
        while let current = next {
            defer { next = current.right }
            guard !current.deleted, case .type(let type) = current.content else { continue }
            let node: String
            if case .xmlElement("columnList")? = type.typeRef {
                node = "columnList"
            } else if let first = children(type).first, case .type(let element) = first.content,
                case .xmlElement(let name)? = element.typeRef
            {
                node = name
            } else {
                return false
            }
            if !MediaBlock.contentless.contains(node) { return false }
        }
        return true
    }

    /// BlockNote's `updateBlock` with props on a media block (PR13a): each
    /// prop that differs is set; then, as y-prosemirror's `updateYFragment`
    /// does, every schema prop whose value is `undefined` is removed (an
    /// unset `previewWidth`). Unknown props stay (the web would drop them;
    /// the native editor never deletes what it does not model).
    @discardableResult
    func setMediaProps(in target: Target, props: [(key: String, value: YAnyValue)]) throws -> Data {
        guard let schema = MediaBlock.schemas[target.node], MediaBlock.nodes.contains(target.node),
            props.allSatisfy({ prop in schema.contains { $0.key == prop.key } }),
            let stored = YBlockProjection.props(of: target.element)
        else { throw Error.unsupportedBlockType(target.node) }
        return try transaction { tx in
            for field in schema {
                let current = stored.last { $0.key == field.key }?.value
                let value = props.last { $0.key == field.key }?.value ?? current ?? field.value
                if value == .undefined {
                    if current != nil, let entry = target.element.map[field.key], !entry.deleted { entry.delete(tx) }
                } else if value != current {
                    try YWrite.mapSet(tx, on: target.element, key: field.key, .any([value]))
                }
            }
        }
    }
}
