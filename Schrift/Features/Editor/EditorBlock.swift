import Foundation

enum BlockKind: Equatable, Sendable {
    case heading(level: Int)
    case paragraph
    case bulletItem
    case numberedItem
    case checklistItem(checked: Bool)
    case quote
    case codeBlock(language: String)
    case divider
    /// A standalone `![alt](url)` line with an absolute http(s) URL. `alt` and
    /// `url` are raw `String`s, never re-normalized through `URL`: the backend's
    /// `extract_attachments()` matches the embedded url byte-for-byte, so it must
    /// survive the round trip untouched. `text` stays empty.
    case image(alt: String, url: String)
    /// Markdown the editor doesn't model (tables, nested lists, HTML, relative or
    /// ambiguous images…). The text is preserved verbatim — including newlines —
    /// so a full-overwrite save never destroys content authored elsewhere.
    case unknown
}

struct EditorBlock: Identifiable, Equatable, Sendable {
    let id: UUID
    var kind: BlockKind
    var text: String

    init(id: UUID = UUID(), kind: BlockKind, text: String = "") {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

/// Content equality ignoring block identities.
func blocksContentEqual(_ lhs: [EditorBlock], _ rhs: [EditorBlock]) -> Bool {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.kind == $1.kind && $0.text == $1.text }
}

/// Whether a block's text is read as inline markdown — styled while editing,
/// with its syntax hidden — or kept verbatim.
///
/// This must agree with `InlineMarkdown`, which declines to parse a code
/// block's or an `.unknown` block's text: styling those would show formatting
/// the full-overwrite save would never write. `.divider` and `.image` are leaves
/// with no text at all.
func rendersInlineMarkdown(_ kind: BlockKind) -> Bool {
    switch kind {
    case .codeBlock, .unknown, .divider, .image:
        return false
    case .paragraph, .heading, .bulletItem, .numberedItem, .checklistItem, .quote:
        return true
    }
}

/// 1-based position of the block within its contiguous run of numbered items.
func numberedIndex(of index: Int, in blocks: [EditorBlock]) -> Int {
    var position = 1
    var cursor = index - 1
    while cursor >= 0, case .numberedItem = blocks[cursor].kind {
        position += 1
        cursor -= 1
    }
    return position
}
