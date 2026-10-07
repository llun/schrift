import Foundation

// MARK: - Formatting-bar families

/// A family of block kinds one formatting-bar button stands for: a tap applies the
/// family's remembered default, a long press offers every member, and a pick applies
/// that member and becomes the new default. Defaults are local app preferences
/// (`schrift.` prefix), never a document or server value.
protocol FormattingBarFormat: CaseIterable, Hashable, RawRepresentable, Sendable
where RawValue == String, AllCases == [Self] {
    /// `@AppStorage` key for the remembered default.
    static var preferenceKey: String { get }
    /// What a fresh install, or a stored value this build doesn't know, falls back to.
    static var fallback: Self { get }
    /// The member a block already is, if any — keyed on the kind, not its state.
    init?(blockKind: BlockKind)
    /// The kind a block becomes.
    var blockKind: BlockKind { get }
    var icon: MaterialIcon { get }
    var labelKey: L10nKey { get }
}

extension FormattingBarFormat {
    /// Resolves the stored preference, tolerating a missing or unknown raw value.
    static func stored(_ rawValue: String) -> Self {
        Self(rawValue: rawValue) ?? fallback
    }
}

// MARK: - List format

/// The three list kinds the formatting bar's single list button stands for.
///
/// The bar used to spend two of its 44pt slots on a bulleted and a checklist button,
/// and offered no numbered list at all. One button now applies the user's
/// **default** list kind on tap; a long press offers all three, and picking one both
/// applies it and makes it the new default. The default is a local app preference
/// (`schrift.` prefix), never a document or server value.
enum ListFormat: String, FormattingBarFormat {
    case bulleted
    case numbered
    case checklist

    static let preferenceKey = "schrift.editor.defaultListFormat"

    /// The bulleted list the bar's first list button always was.
    static let fallback: ListFormat = .bulleted

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

/// The kind a block becomes when the user *taps* the list button with `format` as the
/// default: a block already in that list kind goes back to a paragraph, anything else
/// becomes that kind. Keyed on the list kind, not the exact `BlockKind` — `convertBlock`'s
/// own toggle compares exactly, so a *checked* item tapped with Checklist as the default
/// would merely be unchecked and stay a list.
func blockKindAfterTapping<Format: FormattingBarFormat>(_ format: Format, current: BlockKind) -> BlockKind {
    Format(blockKind: current) == format ? .paragraph : format.blockKind
}

/// The kind a block should become when the user *picks* `format` from the long-press
/// choices, or nil when it already is that list kind.
///
/// Distinct from a tap on the list button (`blockKindAfterTapping`), which turns a block
/// already in that list kind back into a paragraph. A pick is a
/// choice, not a toggle: choosing "Checklist" for a checklist item must not strip the
/// list, and must not reset a checked item to unchecked.
func blockKindAfterChoosing<Format: FormattingBarFormat>(_ format: Format, current: BlockKind) -> BlockKind? {
    Format(blockKind: current) == format ? nil : format.blockKind
}

// MARK: - Quote format

/// The quote/code pair that shares the formatting bar's second family button, on the same
/// tap/long-press terms as `ListFormat`. A code block matches whatever its language, so
/// picking Code for a fenced `swift` block keeps the language, and a tap removes it.
enum QuoteFormat: String, FormattingBarFormat {
    case quote
    case code

    static let preferenceKey = "schrift.editor.defaultQuoteFormat"

    /// Quote: the first of the two buttons this one replaced.
    static let fallback: QuoteFormat = .quote

    init?(blockKind: BlockKind) {
        switch blockKind {
        case .quote: self = .quote
        case .codeBlock: self = .code
        default: return nil
        }
    }

    var blockKind: BlockKind {
        switch self {
        case .quote: .quote
        case .code: .codeBlock(language: "")
        }
    }

    var icon: MaterialIcon {
        switch self {
        case .quote: .format_quote
        case .code: .data_object
        }
    }

    var labelKey: L10nKey {
        switch self {
        case .quote: .editor_format_quote
        case .code: .editor_format_code_block
        }
    }
}
