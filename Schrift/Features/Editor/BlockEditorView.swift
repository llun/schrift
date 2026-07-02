import SwiftUI

/// The editable block canvas: each block is an in-place editable row with
/// Notion-style keyboard behavior (Return splits, backspace at start merges).
struct BlockEditorView: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DocsSpacing.space2xs) {
                    TextField("Untitled document", text: Binding(
                        get: { viewModel.title },
                        set: { viewModel.updateTitle($0) }
                    ))
                    .font(DocsFont.title1.weight(.bold))
                    .foregroundStyle(DocsColor.textPrimary)
                    .padding(.bottom, DocsSpacing.spaceSM)

                    ForEach(Array(viewModel.blocks.enumerated()), id: \.element.id) { index, block in
                        BlockEditorRow(viewModel: viewModel, block: block, index: index)
                            .id(block.id)
                    }

                    // Tapping the empty canvas below the last block starts a
                    // new paragraph, like tapping the page in Notion.
                    Color.clear
                        .frame(height: 180)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.appendParagraphAtEnd()
                        }
                        .accessibilityLabel("Add paragraph at end")
                }
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.top, DocsSpacing.spaceSM)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.focusedBlockID) { _, focusedID in
                guard let focusedID else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(focusedID, anchor: .center)
                }
            }
        }
    }
}

private struct BlockEditorRow: View {
    @Bindable var viewModel: EditorViewModel
    let block: EditorBlock
    let index: Int

    var body: some View {
        if case .divider = block.kind {
            Rectangle()
                .fill(DocsColor.borderDefault)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DocsSpacing.spaceXS)
                .contentShape(Rectangle())
                .accessibilityLabel("Divider")
        } else {
            // Every editable kind shares one structural shape (adornment slot
            // + text view with value-varying modifiers): converting the
            // focused block's kind must NOT recreate the UITextView, or the
            // keyboard would drop on every "- "/slash/toolbar conversion.
            HStack(alignment: .top, spacing: hasAdornment ? DocsSpacing.spaceXS : 0) {
                adornment
                textView
                    .padding(isCodePanel ? DocsSpacing.spaceSM : 0)
                    .padding(.leading, isQuote ? DocsSpacing.spaceSM : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isCodePanel ? DocsColor.surfaceSunken : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: isCodePanel ? DocsRadius.md : 0))
                    .overlay(alignment: .leading) {
                        if isQuote {
                            Rectangle()
                                .fill(DocsColor.borderDefault)
                                .frame(width: 3)
                        }
                    }
            }
        }
    }

    private var isCodePanel: Bool {
        switch block.kind {
        case .codeBlock, .unknown:
            return true
        default:
            return false
        }
    }

    private var isQuote: Bool {
        block.kind == .quote
    }

    private var hasAdornment: Bool {
        switch block.kind {
        case .bulletItem, .numberedItem, .checklistItem:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private var adornment: some View {
        switch block.kind {
        case .bulletItem:
            Text("•")
                .font(DocsFont.body)
                .foregroundStyle(DocsColor.textPrimary)

        case .numberedItem:
            Text("\(numberedIndex(of: index, in: viewModel.blocks)).")
                .font(DocsFont.body)
                .monospacedDigit()
                .foregroundStyle(DocsColor.textPrimary)

        case .checklistItem(let checked):
            Button {
                viewModel.toggleChecklist(blockID: block.id)
            } label: {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(DocsFont.body)
                    .foregroundStyle(checked ? DocsColor.brandFill : DocsColor.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(checked ? "Mark as not done" : "Mark as done")

        default:
            EmptyView()
        }
    }

    private var textView: some View {
        BlockTextView(
            text: Binding(
                get: { block.text },
                set: { viewModel.updateText(blockID: block.id, text: $0) }
            ),
            styling: blockTextStyling(for: block.kind),
            isFocused: viewModel.focusedBlockID == block.id,
            cursorRequest: viewModel.cursorRequest?.blockID == block.id ? viewModel.cursorRequest : nil,
            onEvent: { event in
                handle(event)
            },
            onCursorRequestHandled: { token in
                if viewModel.cursorRequest?.token == token {
                    viewModel.cursorRequest = nil
                }
            }
        )
    }

    private func handle(_ event: BlockTextEvent) {
        switch event {
        case .textChanged(let text):
            viewModel.updateText(blockID: block.id, text: text)
        case .insertNewline(let cursorOffset):
            viewModel.splitBlock(blockID: block.id, at: cursorOffset)
        case .deleteAtStart:
            viewModel.mergeBlockWithPrevious(blockID: block.id)
        case .selectionChanged(let range):
            if viewModel.focusedBlockID == block.id {
                viewModel.selection = range
            }
        case .beganEditing:
            if viewModel.focusedBlockID != block.id {
                viewModel.focusedBlockID = block.id
                viewModel.slashQueryText = nil
            }
        case .endedEditing:
            if viewModel.focusedBlockID == block.id {
                viewModel.focusedBlockID = nil
                viewModel.slashQueryText = nil
            }
        }
    }
}
