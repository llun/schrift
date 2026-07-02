import Foundation

struct SlashMenuItem: Equatable, Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let kind: BlockKind
    let keywords: [String]
}

let allSlashMenuItems: [SlashMenuItem] = [
    SlashMenuItem(id: "paragraph", title: "Text", systemImage: "text.alignleft", kind: .paragraph, keywords: ["text", "plain", "paragraph", "p"]),
    SlashMenuItem(id: "heading1", title: "Heading 1", systemImage: "textformat.size.larger", kind: .heading(level: 1), keywords: ["h1", "heading", "title"]),
    SlashMenuItem(id: "heading2", title: "Heading 2", systemImage: "textformat.size", kind: .heading(level: 2), keywords: ["h2", "heading", "subtitle"]),
    SlashMenuItem(id: "heading3", title: "Heading 3", systemImage: "textformat.size.smaller", kind: .heading(level: 3), keywords: ["h3", "heading"]),
    SlashMenuItem(id: "bullet", title: "Bulleted list", systemImage: "list.bullet", kind: .bulletItem, keywords: ["bullet", "list", "ul", "unordered"]),
    SlashMenuItem(id: "numbered", title: "Numbered list", systemImage: "list.number", kind: .numberedItem, keywords: ["numbered", "list", "ol", "ordered"]),
    SlashMenuItem(id: "checklist", title: "Checklist", systemImage: "checklist", kind: .checklistItem(checked: false), keywords: ["todo", "task", "check", "checkbox"]),
    SlashMenuItem(id: "quote", title: "Quote", systemImage: "text.quote", kind: .quote, keywords: ["quote", "blockquote", "citation"]),
    SlashMenuItem(id: "code", title: "Code block", systemImage: "chevron.left.forwardslash.chevron.right", kind: .codeBlock(language: ""), keywords: ["code", "snippet", "fence"]),
    SlashMenuItem(id: "divider", title: "Divider", systemImage: "minus", kind: .divider, keywords: ["divider", "separator", "rule", "hr", "line"]),
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
