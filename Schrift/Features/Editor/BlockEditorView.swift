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
        switch block.kind {
        case .divider:
            Rectangle()
                .fill(DocsColor.borderDefault)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DocsSpacing.spaceXS)
                .contentShape(Rectangle())
                .accessibilityLabel("Divider")

        case .codeBlock, .unknown:
            textView
                .padding(DocsSpacing.spaceSM)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DocsColor.surfaceSunken)
                .clipShape(RoundedRectangle(cornerRadius: DocsRadius.md))

        case .quote:
            textView
                .padding(.leading, DocsSpacing.spaceSM)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(DocsColor.borderDefault)
                        .frame(width: 3)
                }

        case .bulletItem:
            HStack(alignment: .top, spacing: DocsSpacing.spaceXS) {
                Text("•")
                    .font(DocsFont.body)
                    .foregroundStyle(DocsColor.textPrimary)
                textView
            }

        case .numberedItem:
            HStack(alignment: .top, spacing: DocsSpacing.spaceXS) {
                Text("\(numberedIndex(of: index, in: viewModel.blocks)).")
                    .font(DocsFont.body)
                    .monospacedDigit()
                    .foregroundStyle(DocsColor.textPrimary)
                textView
            }

        case .checklistItem(let checked):
            HStack(alignment: .top, spacing: DocsSpacing.spaceXS) {
                Button {
                    viewModel.toggleChecklist(blockID: block.id)
                } label: {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .font(DocsFont.body)
                        .foregroundStyle(checked ? DocsColor.brandFill : DocsColor.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(checked ? "Mark as not done" : "Mark as done")
                textView
            }

        case .heading, .paragraph:
            textView
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var textView: some View {
        BlockTextView(
            text: Binding(
                get: { viewModel.blocks.first(where: { $0.id == block.id })?.text ?? block.text },
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
            }
        }
    }
}
