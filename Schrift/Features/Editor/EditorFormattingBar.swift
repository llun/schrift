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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DocsSpacing.space3xs) {
                IconButton(systemImage: "plus", label: "Add block", variant: .ghost, color: .brand) {
                    if isMarkdownMode {
                        viewModel.insertAtCursor("\n")
                    } else {
                        viewModel.insertBlock(after: viewModel.focusedBlockID, kind: .paragraph)
                    }
                }
                IconButton(systemImage: "bold", label: "Bold", variant: .ghost, color: .neutral, isDisabled: !hasTarget) {
                    viewModel.applyInlineMarker("**")
                }
                IconButton(systemImage: "italic", label: "Italic", variant: .ghost, color: .neutral, isDisabled: !hasTarget) {
                    viewModel.applyInlineMarker("_")
                }
                IconButton(systemImage: "chevron.left.forwardslash.chevron.right", label: "Inline code", variant: .ghost, color: .neutral, isDisabled: !hasTarget) {
                    viewModel.applyInlineMarker("`")
                }
                IconButton(systemImage: "list.bullet", label: "Bulleted list", variant: .ghost, color: .neutral, isDisabled: !hasTarget) {
                    if isMarkdownMode {
                        viewModel.insertAtCursor("\n- ")
                    } else {
                        viewModel.convertFocusedBlock(to: .bulletItem)
                    }
                }
                IconButton(systemImage: "checklist", label: "Checklist", variant: .ghost, color: .neutral, isDisabled: !hasTarget) {
                    if isMarkdownMode {
                        viewModel.insertAtCursor("\n- [ ] ")
                    } else {
                        viewModel.convertFocusedBlock(to: .checklistItem(checked: false))
                    }
                }
                IconButton(systemImage: "list.number", label: "Numbered list", variant: .ghost, color: .neutral, isDisabled: !hasTarget) {
                    if isMarkdownMode {
                        viewModel.insertAtCursor("\n1. ")
                    } else {
                        viewModel.convertFocusedBlock(to: .numberedItem)
                    }
                }
                IconButton(systemImage: "text.quote", label: "Quote", variant: .ghost, color: .neutral, isDisabled: !hasTarget) {
                    if isMarkdownMode {
                        viewModel.insertAtCursor("\n> ")
                    } else {
                        viewModel.convertFocusedBlock(to: .quote)
                    }
                }
                IconButton(systemImage: "curlybraces", label: "Code block", variant: .ghost, color: .neutral, isDisabled: !hasTarget) {
                    if isMarkdownMode {
                        viewModel.insertAtCursor("\n```\n\n```\n")
                    } else {
                        viewModel.convertFocusedBlock(to: .codeBlock(language: ""))
                    }
                }
                IconButton(systemImage: "minus", label: "Divider", variant: .ghost, color: .neutral, isDisabled: !hasTarget && !isMarkdownMode) {
                    if isMarkdownMode {
                        viewModel.insertAtCursor("\n---\n")
                    } else {
                        viewModel.insertDividerBelowFocused()
                    }
                }
            }
            .padding(.horizontal, DocsSpacing.spaceXS)
            .padding(.vertical, DocsSpacing.space3xs)
        }
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(DocsColor.borderDefault, lineWidth: 1)
        )
        .clipShape(Capsule())
        .shadow(color: DocsColor.textPrimary.opacity(0.12), radius: 12, x: 0, y: 4)
    }
}
