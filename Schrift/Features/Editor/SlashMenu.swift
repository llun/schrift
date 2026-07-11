import Foundation

/// What selecting a slash-menu item does: convert the focused block, or run a
/// side effect (the photo picker) that inserts its block later, on success.
enum SlashMenuAction: Equatable, Sendable {
    case convert(BlockKind)
    case insertPhoto
}

struct SlashMenuItem: Equatable, Identifiable {
    let id: String
    /// Stable English label used for search matching (`filteredSlashItems`) and
    /// tests. Never localized/shown: translating it would silently break
    /// `/head`-style filtering for non-English users, since the query the user
    /// types stays in their own language while this string wouldn't track it.
    /// `titleKey` is the localized label actually shown in the menu.
    let title: String
    let titleKey: L10nKey
    let systemImage: String
    let action: SlashMenuAction
    let keywords: [String]
}

let allSlashMenuItems: [SlashMenuItem] = [
    SlashMenuItem(
        id: "paragraph", title: "Text", titleKey: .editor_slash_text, systemImage: "text.alignleft",
        action: .convert(.paragraph),
        keywords: ["text", "plain", "paragraph", "p"]),
    SlashMenuItem(
        id: "heading1", title: "Heading 1", titleKey: .editor_slash_heading1,
        systemImage: "textformat.size.larger",
        action: .convert(.heading(level: 1)),
        keywords: ["h1", "heading", "title"]),
    SlashMenuItem(
        id: "heading2", title: "Heading 2", titleKey: .editor_slash_heading2, systemImage: "textformat.size",
        action: .convert(.heading(level: 2)),
        keywords: ["h2", "heading", "subtitle"]),
    SlashMenuItem(
        id: "heading3", title: "Heading 3", titleKey: .editor_slash_heading3,
        systemImage: "textformat.size.smaller",
        action: .convert(.heading(level: 3)),
        keywords: ["h3", "heading"]),
    SlashMenuItem(
        id: "bullet", title: "Bulleted list", titleKey: .editor_slash_bulleted_list, systemImage: "list.bullet",
        action: .convert(.bulletItem),
        keywords: ["bullet", "list", "ul", "unordered"]),
    SlashMenuItem(
        id: "numbered", title: "Numbered list", titleKey: .editor_slash_numbered_list,
        systemImage: "list.number", action: .convert(.numberedItem),
        keywords: ["numbered", "list", "ol", "ordered"]),
    SlashMenuItem(
        id: "checklist", title: "Checklist", titleKey: .editor_slash_checklist, systemImage: "checklist",
        action: .convert(.checklistItem(checked: false)),
        keywords: ["todo", "task", "check", "checkbox"]),
    SlashMenuItem(
        id: "quote", title: "Quote", titleKey: .editor_slash_quote, systemImage: "text.quote",
        action: .convert(.quote),
        keywords: ["quote", "blockquote", "citation"]),
    SlashMenuItem(
        id: "code", title: "Code block", titleKey: .editor_slash_code_block,
        systemImage: "chevron.left.forwardslash.chevron.right",
        action: .convert(.codeBlock(language: "")), keywords: ["code", "snippet", "fence"]),
    SlashMenuItem(
        id: "divider", title: "Divider", titleKey: .editor_slash_divider, systemImage: "minus",
        action: .convert(.divider),
        keywords: ["divider", "separator", "rule", "hr", "line"]),
    SlashMenuItem(
        id: "photo", title: "Photo", titleKey: .editor_slash_photo, systemImage: "photo", action: .insertPhoto,
        keywords: ["photo", "image", "picture", "img"]),
]

/// Non-nil when the block's text is a slash command in progress ("/" plus the
/// query typed so far). Only paragraphs can host the slash menu.
func slashQuery(text: String, kind: BlockKind) -> String? {
    guard kind == .paragraph, text.hasPrefix("/") else { return nil }
    return String(text.dropFirst())
}

func filteredSlashItems(query: String, items: [SlashMenuItem] = allSlashMenuItems) -> [SlashMenuItem] {
    let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !trimmed.isEmpty else { return items }
    return items.filter { item in
        item.title.lowercased().contains(trimmed)
            || item.keywords.contains { $0.hasPrefix(trimmed) }
    }
}
