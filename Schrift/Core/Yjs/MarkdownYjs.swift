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
    static func encode(markdown: String, clientID: UInt32 = UInt32.random(in: 1...UInt32.max)) -> Data {
        BlockNoteYjs.encode(blockNoteBlocks(from: markdown), clientID: clientID)
    }

    /// Base64 for the `content` field of `PATCH documents/{id}/content/`.
    static func base64(markdown: String, clientID: UInt32 = UInt32.random(in: 1...UInt32.max)) -> String {
        encode(markdown: markdown, clientID: clientID).base64EncodedString()
    }

    static func blockNoteBlocks(from markdown: String) -> [BlockNoteBlock] {
        blockNoteBlocks(from: parseEditorBlocks(markdown))
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
