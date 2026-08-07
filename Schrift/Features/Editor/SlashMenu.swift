import Foundation

/// What selecting a slash-menu item does: convert the focused block, or run a
/// side effect (a picker) that inserts its block later, on success.
enum SlashMenuAction: Equatable, Sendable {
    case convert(BlockKind)
    case insertPhoto
    case insertAttachment

    /// True for the actions that must reach the server **now** — the only items withheld
    /// offline or on a document that has no server id yet.
    ///
    /// `.insertPhoto` is deliberately *not* one of them any more. A queued photo is stored on
    /// this device as a `schrift-attachment://` placeholder, held off the wire by the save
    /// coordinator's gates, and uploaded by `runAttachmentPass` when there is a network and a
    /// server id — so offering it offline costs nothing. `.insertAttachment` has no equivalent
    /// yet: giving it one means a placeholder shape the parser classifies, a hold that
    /// recognises it, and a replay branch that uploads it. Until that exists, it stays gated.
    var requiresImmediateUpload: Bool {
        switch self {
        case .insertAttachment: return true
        case .insertPhoto, .convert: return false
        }
    }
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
    let icon: MaterialIcon
    let action: SlashMenuAction
    let keywords: [String]
}

let allSlashMenuItems: [SlashMenuItem] = [
    SlashMenuItem(
        id: "paragraph", title: "Text", titleKey: .editor_slash_text, icon: .subject,
        action: .convert(.paragraph),
        keywords: ["text", "plain", "paragraph", "p"]),
    SlashMenuItem(
        id: "heading1", title: "Heading 1", titleKey: .editor_slash_heading1,
        icon: .format_h1,
        action: .convert(.heading(level: 1)),
        keywords: ["h1", "heading", "title"]),
    SlashMenuItem(
        id: "heading2", title: "Heading 2", titleKey: .editor_slash_heading2, icon: .format_h2,
        action: .convert(.heading(level: 2)),
        keywords: ["h2", "heading", "subtitle"]),
    SlashMenuItem(
        id: "heading3", title: "Heading 3", titleKey: .editor_slash_heading3,
        icon: .format_h3,
        action: .convert(.heading(level: 3)),
        keywords: ["h3", "heading"]),
    SlashMenuItem(
        id: "bullet", title: "Bulleted list", titleKey: .editor_slash_bulleted_list, icon: .format_list_bulleted,
        action: .convert(.bulletItem),
        keywords: ["bullet", "list", "ul", "unordered"]),
    SlashMenuItem(
        id: "numbered", title: "Numbered list", titleKey: .editor_slash_numbered_list,
        icon: .format_list_numbered, action: .convert(.numberedItem),
        keywords: ["numbered", "list", "ol", "ordered"]),
    SlashMenuItem(
        id: "checklist", title: "Checklist", titleKey: .editor_slash_checklist, icon: .checklist,
        action: .convert(.checklistItem(checked: false)),
        keywords: ["todo", "task", "check", "checkbox"]),
    SlashMenuItem(
        id: "quote", title: "Quote", titleKey: .editor_slash_quote, icon: .format_quote,
        action: .convert(.quote),
        keywords: ["quote", "blockquote", "citation"]),
    SlashMenuItem(
        id: "code", title: "Code block", titleKey: .editor_slash_code_block,
        icon: .data_object,
        action: .convert(.codeBlock(language: "")), keywords: ["code", "snippet", "fence"]),
    SlashMenuItem(
        id: "divider", title: "Divider", titleKey: .editor_slash_divider, icon: .horizontal_rule,
        action: .convert(.divider),
        keywords: ["divider", "separator", "rule", "hr", "line"]),
    SlashMenuItem(
        id: "photo", title: "Photo", titleKey: .editor_slash_photo, icon: .image, action: .insertPhoto,
        keywords: ["photo", "image", "picture", "img"]),
    SlashMenuItem(
        id: "file", title: "File", titleKey: .editor_slash_file, icon: .description, action: .insertAttachment,
        keywords: ["file", "attachment", "pdf", "doc", "document", "upload"]),
]

/// Non-nil when the block's text is a slash command in progress ("/" plus the
/// query typed so far). Only paragraphs can host the slash menu.
func slashQuery(text: String, kind: BlockKind) -> String? {
    guard kind == .paragraph, text.hasPrefix("/") else { return nil }
    return String(text.dropFirst())
}

/// Offline drops only what has nowhere to go. **File** still POSTs a multipart attachment
/// with no queue behind it, so offered offline it would open the picker, read whatever the
/// user chose, and only then fail — and on a document with no server id the POST would
/// address a client-minted uuid and 404. **Photo is no longer withheld**: a photo picked
/// offline is stored on the device and uploaded by the attachment replay, exactly as an
/// offline text edit is queued and pushed.
///
/// That asymmetry is the whole reason `requiresImmediateUpload` exists rather than a blanket
/// "does this upload" test — see it for what giving File the same treatment would take.
func filteredSlashItems(
    query: String, isOffline: Bool = false, isLocalDocument: Bool = false,
    items: [SlashMenuItem] = allSlashMenuItems
) -> [SlashMenuItem] {
    let available =
        isOffline || isLocalDocument ? items.filter { !$0.action.requiresImmediateUpload } : items
    let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !trimmed.isEmpty else { return available }
    return available.filter { item in
        item.title.lowercased().contains(trimmed)
            || item.keywords.contains { $0.hasPrefix(trimmed) }
    }
}
