import Foundation

// Converts the editor's markdown into a base64 Yjs update that the docs backend
// stores as document content. Reuses the editor's own line-based block parser
// (`parseEditorBlocks`) so the block classification matches what the editor
// shows, then maps each block to its BlockNote node and encodes to Yjs.

enum MarkdownYjs {
    private static let baseProps: [(key: String, value: YAnyValue)] = [
        ("backgroundColor", .string("default")),
        ("textColor", .string("default")),
        ("textAlignment", .string("left")),
    ]

    /// Full pipeline: markdown → BlockNote blocks → Yjs update `Data`. The
    /// clientID identifies the authoring client; a fresh random one per save is
    /// fine because the content endpoint is a full overwrite.
    /// `serverOrigin` is **not** defaulted: it decides whether a standalone
    /// attachment link is written as a BlockNote `file` node or as a paragraph
    /// carrying a link, and that changes the bytes this produces. A boundary
    /// that moves saved bytes should be impossible to cross by forgetting an
    /// argument.
    static func encode(
        markdown: String, serverOrigin: String, clientID: UInt32 = UInt32.random(in: 1...UInt32.max)
    ) -> Data {
        BlockNoteYjs.encode(blockNoteBlocks(from: markdown, serverOrigin: serverOrigin), clientID: clientID)
    }

    /// Base64 for the `content` field of `PATCH documents/{id}/content/`.
    static func base64(
        markdown: String, serverOrigin: String, clientID: UInt32 = UInt32.random(in: 1...UInt32.max)
    ) -> String {
        encode(markdown: markdown, serverOrigin: serverOrigin, clientID: clientID).base64EncodedString()
    }

    static func blockNoteBlocks(from markdown: String, serverOrigin: String) -> [BlockNoteBlock] {
        blockNoteBlocks(from: parseEditorBlocks(markdown, serverOrigin: serverOrigin))
    }

    /// The id-stable core: maps already-parsed editor blocks straight to BlockNote
    /// blocks, so each block keeps its `EditorBlock.id` (`.uuidString.lowercased()`)
    /// as its BlockNote id. The live write path (C2c) relies on this stability —
    /// re-parsing `currentMarkdown()` would mint fresh ids each call, so survivors
    /// would never match across two edits and every keystroke would rebuild the
    /// whole document. `.unknown` blocks still mint fresh ids (they map to N
    /// paragraphs), but a document with an `.unknown` block is never
    /// write-eligible (its projection is not `isFullyModeled`), so it stays
    /// read-live and this coarseness is unreachable in the write path.
    static func blockNoteBlocks(from blocks: [EditorBlock]) -> [BlockNoteBlock] {
        let mapped = blocks.flatMap(map)
        // BlockNote documents must contain at least one block.
        return mapped.isEmpty ? [emptyParagraph()] : mapped
    }

    private static func emptyParagraph() -> BlockNoteBlock {
        BlockNoteBlock(node: "paragraph", props: baseProps, runs: [], id: UUID().uuidString.lowercased())
    }

    private static func map(_ block: EditorBlock) -> [BlockNoteBlock] {
        let id = block.id.uuidString.lowercased()
        switch block.kind {
        case .heading(let level):
            return [
                BlockNoteBlock(
                    node: "heading",
                    props: baseProps + [("level", .int(level)), ("isToggleable", .bool(false))],
                    runs: InlineMarkdown.parse(block.text), id: id)
            ]
        case .paragraph:
            return [
                BlockNoteBlock(
                    node: "paragraph", props: baseProps,
                    runs: InlineMarkdown.parse(block.text), id: id)
            ]
        case .bulletItem:
            return [
                BlockNoteBlock(
                    node: "bulletListItem", props: baseProps,
                    runs: InlineMarkdown.parse(block.text), id: id)
            ]
        case .numberedItem:
            return [
                BlockNoteBlock(
                    node: "numberedListItem", props: baseProps + [("start", .null)],
                    runs: InlineMarkdown.parse(block.text), id: id)
            ]
        case .checklistItem(let checked):
            return [
                BlockNoteBlock(
                    node: "checkListItem", props: baseProps + [("checked", .bool(checked))],
                    runs: InlineMarkdown.parse(block.text), id: id)
            ]
        case .quote:
            return [
                BlockNoteBlock(
                    node: "quote",
                    props: [("backgroundColor", .string("default")), ("textColor", .string("default"))],
                    runs: InlineMarkdown.parse(block.text), id: id)
            ]
        case .codeBlock(let language):
            let lang = language.isEmpty ? "text" : language
            let runs = block.text.isEmpty ? [] : [InlineRun(block.text)]
            return [BlockNoteBlock(node: "codeBlock", props: [("language", .string(lang))], runs: runs, id: id)]
        case .divider:
            return [BlockNoteBlock(node: "divider", props: [], runs: [], id: id)]
        case .image(let alt, let url):
            // Leaf node: no text child. Props mirror BlockNote 0.51.4's image
            // propSchema (note: no `textColor`, and `previewWidth` is emitted as
            // `undefined`, matching the real library). The markdown alt maps to
            // `name` — BlockNote renders the `<img>` alt from `name` — so the
            // read→edit→save round trip is stable; caption editing is out of scope.
            return [
                BlockNoteBlock(
                    node: "image",
                    props: [
                        ("textAlignment", .string("left")),
                        ("backgroundColor", .string("default")),
                        ("name", .string(alt)),
                        ("url", .string(url)),
                        ("caption", .string("")),
                        ("showPreview", .bool(true)),
                        ("previewWidth", .undefined),
                    ],
                    runs: [], id: id)
            ]
        case .attachment(let name, let url):
            // A leaf `file` node — BlockNote's stock download chip — for **every**
            // attachment type, PDFs included. docs' own `pdf` node is deliberately
            // never written: its `showPreview` defaults to true, and a `pdf` block
            // with preview on exports to *nothing* through the server's markdown
            // exporter (BlockNote's serializer has no `<iframe>` handler), so the
            // app would stop seeing the block and the next full-overwrite save
            // would destroy it. A chip the web renders is the safe parity point.
            //
            // Prop order is the 0.51.4 `file` propSchema and is fixed by the
            // golden fixture, not by this list: there is no `textAlignment`, no
            // `textColor`, no `showPreview` and no `previewWidth`.
            return [
                BlockNoteBlock(
                    node: "file",
                    props: [
                        ("backgroundColor", .string("default")),
                        ("name", .string(name)),
                        ("url", .string(url)),
                        ("caption", .string("")),
                    ],
                    runs: [], id: id)
            ]
        case .unknown:
            // Content the editor can't model (tables, HTML, nested lists). Preserve
            // the text verbatim as one paragraph per non-empty line so a save never
            // drops it, even though the richer structure can't be reproduced.
            return block.text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.isEmpty }
                .map {
                    BlockNoteBlock(
                        node: "paragraph", props: baseProps, runs: [InlineRun($0)], id: UUID().uuidString.lowercased())
                }
        }
    }
}
