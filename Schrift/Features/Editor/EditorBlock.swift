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
    /// Markdown the editor doesn't model (tables, images, nested lists, HTML…).
    /// The text is preserved verbatim — including newlines — so a full-overwrite
    /// save never destroys content authored elsewhere.
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
