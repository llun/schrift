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
/// non-XML Yjs type, XmlText attributes or pending structs. It never writes
/// the destination; the engine re-validates before arming.
enum BlockNoteSubtreePayload {
    /// The private pasteboard type. Plain text always rides beside it.
    static let pasteboardType = "dev.llun.schrift.blocknote-subtrees"
    static let maxBytes = 2 << 20
    /// The plain clipboard's line bound (`NativeClipboard.maxPasteLines`).
    static let maxBlocks = 2_000

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
        "interlinkingLinkInline", "math",
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
        do {
            try doc.applyUpdate(YUpdateDecoder.decode(data))
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
        return copies
    }

    /// Checks that `copies` are whole BlockNote containers within the bounds.
    /// Returns the block count and the deepest block level (0: the copies).
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
                guard case .element(let node, _, let children) = copy else { continue }
                guard inlineNodes.contains(node) else { throw Error.malformed }
                try inline(children)
            }
        }
        guard !copies.isEmpty else { throw Error.malformed }
        for copy in copies { try container(copy, depth: 0) }
        return (blocks, deepest)
    }
}

extension BlockNoteWriter.Copy {
    /// The `blockContainer`s in this copy, in preorder.
    var containerCount: Int {
        guard case .element(let node, _, let children) = self else { return 0 }
        return (node == "blockContainer" ? 1 : 0) + children.reduce(0) { $0 + $1.containerCount }
    }

    /// This copy with every `blockContainer`'s `id` replaced by the next of
    /// `ids`, in preorder (prop order kept). Throws when `ids` runs out.
    func replacingIDs(_ ids: inout ArraySlice<String>) throws -> Self {
        guard case .element(let node, var props, let children) = self else { return self }
        if node == "blockContainer" {
            guard let id = ids.popFirst(), let at = props.firstIndex(where: { $0.key == "id" }) else {
                throw BlockNoteSubtreePayload.Error.malformed
            }
            props[at].value = .string(id)
        }
        return .element(node, props, try children.map { try $0.replacingIDs(&ids) })
    }
}
