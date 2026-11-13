import Foundation

/// The native editor's lossless transfer payload (PR06d): copied block
/// subtrees as the Yjs v1 update of a scratch document whose
/// `document-store` holds one `blockGroup` of them. Every raw value, mark,
/// child and unknown attribute survives because the bytes are Yjs's own
/// encoding of `BlockNoteWriter.Copy` (`snapshot`/`insertCopy`), never a
/// second model.
///
/// **Decoding is a trust boundary.** The pasteboard is shared with every app,
/// so `decode` bounds the bytes, the block count and the nesting depth, and
/// refuses anything a BlockNote document cannot hold: a node outside
/// `contentNodes`/`inlineNodes`, a container without a string id or with
/// anything but one content element and one optional non-empty group, a
/// non-XML Yjs type, XmlText attributes or pending structs. It counts the
/// decoded structs before integrating any (`maxStructs`), so 2 MiB of tiny
/// structs cannot stall the main actor. It then sanitizes what any app could
/// plant (`sanitized`): a link mark whose href `sanitizedLinkURL` would not
/// write unchanged, an embed, or an unknown mark carrying a URL is dropped,
/// and a URL prop (`urlProps`) that is not http(s) refuses the payload. It
/// never writes the destination; the engine re-validates before arming.
enum BlockNoteSubtreePayload {
    /// The private pasteboard type. Plain text always rides beside it.
    static let pasteboardType = "dev.llun.schrift.blocknote-subtrees"
    static let maxBytes = 2 << 20
    /// The plain clipboard's line bound (`NativeClipboard.maxPasteLines`).
    static let maxBlocks = 2_000
    /// Structs and delete ranges counted from the decoded update before it is
    /// integrated: ample for `maxBlocks` ordinary blocks (a paragraph is about
    /// eight), far below the million a 2 MiB update of tiny structs can hold.
    static let maxStructs = 50 * maxBlocks

    enum Error: Swift.Error, Equatable {
        case tooLarge
        case malformed
    }

    /// Block content nodes of the Docs schema (BlockNote 0.56 defaults plus
    /// Docs' callout, math, diagram, PDF and page break). Columns are not
    /// container content and are refused.
    static let contentNodes: Set<String> = [
        "paragraph", "heading", "bulletListItem", "numberedListItem", "checkListItem", "toggleListItem",
        "codeBlock", "quote", "callout", "divider", "pageBreak", "image", "video", "audio", "file", "pdf", "table",
        "mathBlock", "diagram",
    ]

    /// Nodes inside a content element: table structure and inline nodes.
    static let inlineNodes: Set<String> = [
        "tableRow", "tableCell", "tableHeader", "tableParagraph", "hardBreak", "userMentionInline",
        "interlinkingLinkInline", "mentionSearchInline", "math",
    ]

    /// The update bytes for `copies`, each a whole `blockContainer`.
    static func encode(_ copies: [BlockNoteWriter.Copy]) throws -> Data {
        _ = try validate(copies)
        let doc = YDoc(clientID: 1, gc: false)
        defer { doc.destroy() }
        let writer = BlockNoteWriter(doc: doc)
        let root = doc.get(BlockNoteYjs.fragmentField)
        let data = try writer.transaction { tx in
            let group = YType(typeRef: .xmlElement(nodeName: "blockGroup"))
            guard try YWrite.insertAfter(tx, into: root, after: nil, [.type(group)]) != nil else {
                throw Error.malformed
            }
            var left: YItem?
            for copy in copies { left = try writer.insertCopy(tx, copy, into: group, after: left) }
        }
        guard data.count <= maxBytes else { throw Error.tooLarge }
        return data
    }

    /// The validated subtrees of an untrusted payload.
    static func decode(_ data: Data) throws -> [BlockNoteWriter.Copy] {
        guard data.count <= maxBytes else { throw Error.tooLarge }
        let doc = YDoc(clientID: 1, gc: false)
        defer { doc.destroy() }
        let update: YUpdate
        do {
            update = try YUpdateDecoder.decode(data)
        } catch {
            throw Error.malformed
        }
        let structs =
            update.blocks.reduce(0) { $0 + $1.structs.count } + update.deleteSet.reduce(0) { $0 + $1.ranges.count }
        guard structs <= maxStructs else { throw Error.tooLarge }
        do {
            try doc.applyUpdate(update)
        } catch {
            throw Error.malformed
        }
        let writer = BlockNoteWriter(doc: doc)
        guard doc.store.pendingStructs == nil, doc.store.pendingDs == nil, doc.share.count == 1,
            let root = doc.share[BlockNoteYjs.fragmentField], root.map.values.allSatisfy(\.deleted)
        else { throw Error.malformed }
        let top = writer.children(root)
        guard top.count == 1, case .type(let group) = top[0].content,
            group.typeRef == .xmlElement(nodeName: "blockGroup")
        else { throw Error.malformed }
        let copies: [BlockNoteWriter.Copy]
        do {
            copies = try writer.children(group).map { item in
                guard case .type(let container) = item.content else { throw Error.malformed }
                return try writer.snapshot(container, block: "payload", depth: 0)
            }
        } catch let error as Error {
            throw error
        } catch {
            throw Error.malformed
        }
        _ = try validate(copies)
        return try copies.map(sanitized)
    }

    /// Mark keys BlockNote 0.56 and Docs write; other keys survive a paste
    /// only when their value carries no URL.
    static let knownMarks: Set<String> = [
        "bold", "italic", "underline", "strike", "code", "link", "textColor", "backgroundColor",
    ]

    /// Props that name a resource (media and file blocks): a pasted one must
    /// be empty or http(s) with a host.
    static let urlProps: Set<String> = ["url", "previewUrl", "src", "href"]

    /// A pasted subtree without what another app could plant in it. Drops a
    /// link mark whose href `sanitizedLinkURL` would not write unchanged (its
    /// text stays), an unknown mark carrying a URL, and embeds; refuses a
    /// non-http(s) URL prop.
    static func sanitized(_ copy: BlockNoteWriter.Copy) throws -> BlockNoteWriter.Copy {
        switch copy {
        case .text(let values):
            return .text(
                values.compactMap { value in
                    guard case .run(var run) = value else { return nil }
                    run.marks = run.marks.filter(isSafeMark)
                    return .run(run)
                })
        case .element(let node, let props, let children):
            for prop in props where urlProps.contains(prop.key) {
                guard case .string(let url) = prop.value, url.isEmpty || isWebURL(url) else { throw Error.malformed }
            }
            return .element(node, props, try children.map(sanitized))
        }
    }

    private static func isSafeMark(_ mark: (key: String, valueJSON: String)) -> Bool {
        if mark.key == "link" {
            guard let href = YBlockProjection.linkHref(from: mark.valueJSON) else { return false }
            return sanitizedLinkURL(href) == href
        }
        return knownMarks.contains(mark.key) || !carriesURL(mark.valueJSON)
    }

    /// Whether any string in a mark's JSON value parses with a URL scheme (an
    /// unreadable value counts).
    private static func carriesURL(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        else { return true }
        func walk(_ value: Any) -> Bool {
            switch value {
            case let string as String: URL(string: string)?.scheme != nil
            case let array as [Any]: array.contains(where: walk)
            case let object as [String: Any]: object.values.contains(where: walk)
            default: false
            }
        }
        return walk(value)
    }

    private static func isWebURL(_ string: String) -> Bool {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme)
        else { return false }
        return !(url.host ?? "").isEmpty
    }

    /// Checks that `copies` are whole BlockNote containers within the bounds.
    /// Returns the block count and the deepest block level (0: the copies).
    private static func hasID(_ props: [(key: String, value: YAnyValue)]) -> Bool {
        props.contains { if case .string(let id) = $0.value { $0.key == "id" && !id.isEmpty } else { false } }
    }

    static func validate(_ copies: [BlockNoteWriter.Copy]) throws -> (blocks: Int, depth: Int) {
        var blocks = 0
        var deepest = 0
        func container(_ copy: BlockNoteWriter.Copy, depth: Int) throws {
            guard case .element("blockContainer", let props, let children) = copy,
                depth <= BlockNoteWriter.maxNestingDepth,
                props.contains(where: {
                    if case .string(let id) = $0.value { $0.key == "id" && !id.isEmpty } else { false }
                }),
                (1...2).contains(children.count), case .element(let node, _, let content) = children[0],
                contentNodes.contains(node)
            else { throw Error.malformed }
            blocks += 1
            deepest = max(deepest, depth)
            guard blocks <= maxBlocks else { throw Error.tooLarge }
            if node == "codeBlock" {
                for item in content {
                    if case .element = item { throw Error.malformed }
                }
            }
            try inline(content)
            if children.count == 2 {
                guard case .element("blockGroup", let groupProps, let kids) = children[1], groupProps.isEmpty,
                    !kids.isEmpty
                else { throw Error.malformed }
                for kid in kids { try container(kid, depth: depth + 1) }
            }
        }
        func inline(_ copies: [BlockNoteWriter.Copy]) throws {
            for copy in copies {
                guard case .element(let node, let props, let children) = copy else { continue }
                guard inlineNodes.contains(node) else { throw Error.malformed }
                if NativeInlineObject.nodeNames.contains(node) {
                    let projected = props.map { ProjectedProp(key: $0.key, value: $0.value) }
                    guard NativeInlineObject.read(node: node, props: projected, hasChildren: !children.isEmpty) != nil
                    else { throw Error.malformed }
                }
                try inline(children)
            }
        }
        // A root column group (PR12b): its columns hold containers, each one
        // of its ids counted with the blocks (they get fresh ones too).
        func columnList(_ props: [(key: String, value: YAnyValue)], _ columns: [BlockNoteWriter.Copy]) throws {
            guard hasID(props), (2...ColumnGroup.maxColumns).contains(columns.count) else { throw Error.malformed }
            blocks += 1
            for column in columns {
                guard case .element("column", let columnProps, let kids) = column, hasID(columnProps), !kids.isEmpty,
                    // A width `ColumnGroup.read` refuses would leave an unfamiliar group with no
                    // shadow, so every save would fail (PR12b review): absent, or positive and finite.
                    columnProps.allSatisfy({ $0.key != "width" || (TableGrid.number($0.value) ?? 0) > 0 })
                else { throw Error.malformed }
                blocks += 1
                guard blocks <= maxBlocks else { throw Error.tooLarge }
                for kid in kids { try container(kid, depth: 0) }
            }
        }
        guard !copies.isEmpty else { throw Error.malformed }
        for copy in copies {
            if case .element("columnList", let props, let columns) = copy {
                try columnList(props, columns)
            } else {
                try container(copy, depth: 0)
            }
        }
        return (blocks, deepest)
    }
}

extension BlockNoteSubtreePayload {
    /// A paste's media blocks (PR13a): each url canonicalised to what a native
    /// edit stores (`MediaBlock.pastedURL`: a web IRI percent-encoded and
    /// punycoded, review V3), then each block must be one a native edit could
    /// write (`MediaBlock.isPastable`), so a payload never stores a
    /// `javascript:`/`data:` url, an unbounded name or a block the shadow cannot
    /// spell. Only pasting asks this: copy and delete keep any block as it is.
    static func validatingMedia(_ copies: [BlockNoteWriter.Copy]) throws -> [BlockNoteWriter.Copy] {
        try copies.map { copy in
            guard case .element(let node, var props, let children) = copy else { return copy }
            guard MediaBlock.isMediaLike(node) else { return .element(node, props, try validatingMedia(children)) }
            for index in props.indices where props[index].key == "url" {
                guard case .string(let url) = props[index].value, let pasted = MediaBlock.pastedURL(url) else {
                    throw Error.malformed
                }
                props[index].value = .string(pasted)
            }
            guard
                MediaBlock.isPastable(
                    node: node, props: props.map { ProjectedProp(key: $0.key, value: $0.value) },
                    hasContent: !children.isEmpty)
            else { throw Error.malformed }
            return .element(node, props, children)
        }
    }
}

extension BlockNoteWriter.Copy {
    /// The `blockContainer`s in this copy, in preorder.
    var containerCount: Int {
        guard case .element(let node, _, let children) = self else { return 0 }
        return (node == "blockContainer" ? 1 : 0) + children.reduce(0) { $0 + $1.containerCount }
    }

    /// The ids a copy carries: its containers', and a column group's and its
    /// columns' (PR12b).
    var idCount: Int {
        guard case .element(let node, _, let children) = self else { return 0 }
        return (Self.carriesID(node) ? 1 : 0) + children.reduce(0) { $0 + $1.idCount }
    }

    private static func carriesID(_ node: String) -> Bool {
        node == "blockContainer" || node == "columnList" || node == "column"
    }

    /// This copy with every `blockContainer`'s (and column group's and
    /// column's) `id` replaced by the next of `ids`, in preorder (prop order
    /// kept). Throws when `ids` runs out.
    func replacingIDs(_ ids: inout ArraySlice<String>) throws -> Self {
        guard case .element(let node, var props, let children) = self else { return self }
        if Self.carriesID(node) {
            guard let id = ids.popFirst(), let at = props.firstIndex(where: { $0.key == "id" }) else {
                throw BlockNoteSubtreePayload.Error.malformed
            }
            props[at].value = .string(id)
        }
        return .element(node, props, try children.map { try $0.replacingIDs(&ids) })
    }
}

/// The native editor's lossless inline-slice payload for partial selections
/// containing inline objects (`NativeInlineObject`), encoded as one `blockGroup`
/// of `paragraph` containers under the same Yjs trust bounds as
/// `BlockNoteSubtreePayload`.
enum BlockNoteInlinePayload {
    static let pasteboardType = "dev.llun.schrift.blocknote-inline"

    static func encode(_ lines: [[BlockNoteWriter.Copy]]) throws -> Data {
        guard !lines.isEmpty, lines.count <= BlockNoteSubtreePayload.maxBlocks else {
            throw BlockNoteSubtreePayload.Error.malformed
        }
        let blocks = try lines.enumerated().map { index, copies in
            try validateInline(copies)
            return BlockNoteWriter.Copy.element(
                "blockContainer", [("id", .string("inline-\(index)"))],
                [.element("paragraph", [], copies)])
        }
        return try BlockNoteSubtreePayload.encode(blocks)
    }

    static func decode(_ data: Data) throws -> [[BlockNoteWriter.Copy]] {
        let blocks = try BlockNoteSubtreePayload.decode(data)
        return try blocks.map { block in
            guard case .element("blockContainer", _, let children) = block, children.count == 1,
                case .element("paragraph", _, let content) = children[0]
            else { throw BlockNoteSubtreePayload.Error.malformed }
            try validateInline(content)
            return content
        }
    }

    private static func validateInline(_ copies: [BlockNoteWriter.Copy]) throws {
        for copy in copies {
            switch copy {
            case .text: continue
            case .element(let node, let props, let children):
                let projected = props.map { ProjectedProp(key: $0.key, value: $0.value) }
                guard NativeInlineObject.read(node: node, props: projected, hasChildren: !children.isEmpty) != nil
                else {
                    throw BlockNoteSubtreePayload.Error.malformed
                }
            }
        }
    }
}
