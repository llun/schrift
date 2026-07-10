import SwiftUI

/// Floating formatting toolbar shown above the keyboard while editing.
///
/// In blocks mode the actions target the focused block (convert type, wrap
/// the selection in inline markers); in markdown-source mode they operate at
/// the caret. Never a blind append: everything is selection-aware.
struct EditorFormattingBar: View {
    @Bindable var viewModel: EditorViewModel

    private var isMarkdownMode: Bool { viewModel.mode == .markdown }
    private var hasTarget: Bool { isMarkdownMode || viewModel.focusedBlockID != nil }

    var body: some View {
        // A fixed pill of evenly-spaced actions (matching the reference accessory
        // bar): add + the core block/inline formatters. Numbered list, inline
        // code and divider remain reachable via their Markdown shortcuts.
        HStack(spacing: DocsSpacing.space4xs) {
            barButton(icon: "plus", label: "Add block", brand: true, disabled: false) {
                if isMarkdownMode {
                    viewModel.insertAtCursor("\n")
                } else {
                    viewModel.insertBlock(after: viewModel.focusedBlockID, kind: .paragraph)
                }
            }
            barButton(icon: "bold", label: "Bold") {
                viewModel.applyInlineMarker("**")
            }
            // `_`, and `*` would be wrong. `InlineMarkdown` honors CommonMark's
            // flanking rule for underscores, so `_x_` is emphasis that survives a
            // save while `snake_case` stays literal — and it is what BlockNote
            // itself writes. Wrapping a selected **bold** word in `*` would produce
            // `***word***`, which this scanner reads as bold(`*word`) + literal.
            barButton(icon: "italic", label: "Italic") {
                viewModel.applyInlineMarker("_")
            }
            // Blocks mode only: a markdown-source caret has no link span to
            // retarget, and the sheet's whole job is to hide the syntax.
            barButton(
                icon: "link", label: "Link",
                disabled: isMarkdownMode || !viewModel.canEditLink
            ) {
                viewModel.beginLinkEditing()
            }
            barButton(icon: "list.bullet", label: "Bulleted list") {
                if isMarkdownMode {
                    viewModel.insertAtCursor("\n- ")
                } else {
                    viewModel.convertFocusedBlock(to: .bulletItem)
                }
            }
            barButton(icon: "checklist", label: "Checklist") {
                if isMarkdownMode {
                    viewModel.insertAtCursor("\n- [ ] ")
                } else {
                    viewModel.convertFocusedBlock(to: .checklistItem(checked: false))
                }
            }
            barButton(icon: "text.quote", label: "Quote") {
                if isMarkdownMode {
                    viewModel.insertAtCursor("\n> ")
                } else {
                    viewModel.convertFocusedBlock(to: .quote)
                }
            }
            barButton(icon: "curlybraces", label: "Code block") {
                if isMarkdownMode {
                    viewModel.insertAtCursor("\n```\n\n```\n")
                } else {
                    viewModel.convertFocusedBlock(to: .codeBlock(language: ""))
                }
            }
            // Stays disabled while an upload is in flight (and before content has
            // loaded): the view model would decline anyway, so don't invite the tap.
            barButton(
                icon: "photo", label: "Insert photo",
                disabled: !hasTarget || !viewModel.canInsertPhoto
            ) {
                viewModel.requestPhotoInsertion()
            }
        }
        .padding(.horizontal, DocsSpacing.space2xs)
        .padding(.vertical, DocsSpacing.space3xs)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(DocsColor.borderDefault, lineWidth: 1)
        )
        .clipShape(Capsule())
        .shadow(color: DocsColor.textPrimary.opacity(0.12), radius: 12, x: 0, y: 4)
    }

    @ViewBuilder
    private func barButton(
        icon: String, label: String, brand: Bool = false, disabled: Bool? = nil, action: @escaping () -> Void
    ) -> some View {
        IconButton(
            systemImage: icon,
            label: label,
            variant: .ghost,
            color: brand ? .brand : .neutral,
            size: .small,
            isDisabled: disabled ?? !hasTarget,
            // The buttons divide the bar's width rather than each claiming 44pt.
            // `IconButton`'s default minimum does not compress, so nine of them
            // demanded 424pt — wider than any iPhone's content column — and the
            // overflow propagated out through `safeAreaInset` to the editor's
            // outer VStack, shifting the nav bar off screen. The 44pt tap height
            // is unchanged, and the buttons stay contiguous.
            minimumTapWidth: 0,
            action: action
        )
        .frame(maxWidth: .infinity)
    }
}
