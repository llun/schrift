import Foundation

// MARK: - List format

/// The three list kinds the formatting bar's single list button stands for.
///
/// The bar used to spend two of its nine 44pt slots on a bulleted and a checklist
/// button, and offered no numbered list at all. One button now applies the user's
/// **default** list kind on tap; a long press offers all three, and picking one both
/// applies it and makes it the new default. The default is a local app preference
/// (`schrift.` prefix), never a document or server value.
enum ListFormat: String, CaseIterable, Sendable {
    case bulleted
    case numbered
    case checklist

    /// `@AppStorage` key for the remembered default.
    static let preferenceKey = "schrift.editor.defaultListFormat"

    /// What a fresh install, or a stored value this build doesn't know, falls back to —
    /// the bulleted list the bar's first list button always was.
    static let fallback: ListFormat = .bulleted

    /// Resolves the stored preference, tolerating a missing or unknown raw value.
    static func stored(_ rawValue: String) -> ListFormat {
        ListFormat(rawValue: rawValue) ?? fallback
    }

    /// The format a block already has, if it is a list item. A checklist item matches
    /// whether or not it is checked: the format is the list kind, not its state.
    init?(blockKind: BlockKind) {
        switch blockKind {
        case .bulletItem: self = .bulleted
        case .numberedItem: self = .numbered
        case .checklistItem: self = .checklist
        default: return nil
        }
    }

    /// The kind a block becomes. A new checklist item always starts unchecked.
    var blockKind: BlockKind {
        switch self {
        case .bulleted: .bulletItem
        case .numbered: .numberedItem
        case .checklist: .checklistItem(checked: false)
        }
    }

    var icon: MaterialIcon {
        switch self {
        case .bulleted: .format_list_bulleted
        case .numbered: .format_list_numbered
        case .checklist: .checklist
        }
    }

    var labelKey: L10nKey {
        switch self {
        case .bulleted: .editor_format_bulleted_list
        case .numbered: .editor_slash_numbered_list
        case .checklist: .editor_format_checklist
        }
    }
}

/// The kind a block should become when the user *picks* `format` from the long-press
/// choices, or nil when it already is that list kind.
///
/// Distinct from a tap on the list button, which goes through `convertBlock`'s toggle
/// (tapping the kind a block already has turns it back into a paragraph). A pick is a
/// choice, not a toggle: choosing "Checklist" for a checklist item must not strip the
/// list, and must not reset a checked item to unchecked.
func blockKindAfterChoosing(_ format: ListFormat, current: BlockKind) -> BlockKind? {
    ListFormat(blockKind: current) == format ? nil : format.blockKind
}
