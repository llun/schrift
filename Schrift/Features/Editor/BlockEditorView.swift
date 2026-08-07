import SwiftUI

/// The editable block canvas: each block is an in-place editable row with
/// Notion-style keyboard behavior (Return splits, backspace at start merges).
struct BlockEditorView: View {
    @Bindable var viewModel: EditorViewModel
    /// Threaded to reach the image leaf's off-origin load gate
    /// (`imageLoadPolicy`) and the attachment leaf's card; every other row kind
    /// ignores it.
    let serverOrigin: String
    /// Chrome for the attachment leaf: editing offline must say "Available when
    /// online" over an uncached attachment rather than spin on a request that
    /// cannot succeed. Every other row kind ignores it.
    var isOffline: Bool = false

    @Environment(LocalizationStore.self) private var loc

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DocsSpacing.space2xs) {
                    TextField(
                        loc[.common_untitled],
                        text: Binding(
                            get: { viewModel.title },
                            set: { viewModel.updateTitle($0) }
                        )
                    )
                    .font(DocsFont.title1.weight(.bold))
                    .foregroundStyle(DocsColor.textPrimary)
                    .padding(.bottom, DocsSpacing.spaceSM)

                    ForEach(Array(viewModel.blocks.enumerated()), id: \.element.id) { index, block in
                        BlockEditorRow(
                            viewModel: viewModel, block: block, index: index, serverOrigin: serverOrigin,
                            isOffline: isOffline
                        )
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
                        .accessibilityLabel(loc[.editor_add_paragraph_a11y])
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
    let serverOrigin: String
    let isOffline: Bool

    @Environment(LocalizationStore.self) private var loc
    /// Passed into `blockTextStyling` rather than left to the ambient trait
    /// collection.
    ///
    /// A SwiftUI `Text` resolves its scaling lazily at draw time, but
    /// `blockTextStyling` bakes a concrete `UIFont` into the `UITextView` when
    /// the body runs. Reading the size here is what makes this row depend on it:
    /// without that, changing the text size while a document was open left the
    /// block text at its old size until some unrelated edit happened to re-run
    /// the body — on the one screen users spend the most time reading.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if case .divider = block.kind {
            Rectangle()
                .fill(DocsColor.borderDefault)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DocsSpacing.spaceXS)
                .contentShape(Rectangle())
                .accessibilityLabel(loc[.editor_divider_a11y])
        } else if case .image(let alt, let url) = block.kind {
            // An image is a non-editable leaf, like a divider: it has no text
            // view. Backspace at the start of the following block deletes it as
            // a unit (see EditorViewModel.mergeBlockWithPrevious).
            imageLeaf(alt: alt, url: url)
        } else if case .attachment(let name, let url) = block.kind {
            // Same leaf contract as an image: no text view, deletes as a unit,
            // never converted, never receives inline markers. The card is the
            // same one the reading surface draws, so an attachment looks and
            // behaves identically in both modes.
            attachmentLeaf(name: name, url: url)
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
                MaterialSymbol(checked ? .check_box : .check_box_outline_blank, size: 17)
                    .foregroundStyle(checked ? DocsColor.brandFill : DocsColor.textTertiary)
                    // Grow the hit rect, then give the growth back to the layout.
                    // A plain `.frame(44)` would work for the target but this is
                    // the adornment of a `.top`-aligned row, so the taller box
                    // would centre the glyph below the first line of text it is
                    // meant to sit beside. The pair leaves the glyph exactly
                    // where it was and roughly doubles what you can hit.
                    .padding(DocsSpacing.spaceXS)
                    .contentShape(Rectangle())
                    .padding(-DocsSpacing.spaceXS)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(checked ? loc[.editor_checklist_not_done_a11y] : loc[.editor_checklist_done_a11y])

        default:
            EmptyView()
        }
    }

    @ViewBuilder private func attachmentLeaf(name: String, url: String) -> some View {
        if let display = parseAttachmentLink("[\(name)](\(url))", serverOrigin: serverOrigin) {
            AttachmentCardView(display: display, isOffline: isOffline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        } else {
            // A url that no longer belongs to this server (a document opened
            // after switching servers) falls back to link text rather than a
            // card that could never load — the same rendering the reading
            // surface uses, so the two agree.
            Text(markdownInlineText("[\(name)](\(url))"))
                .font(DocsFont.body)
                .foregroundStyle(DocsColor.textPrimary)
        }
    }

    @ViewBuilder private func imageLeaf(alt: String, url: String) -> some View {
        // Branched ahead of `MarkdownImageView`: a queued photo has no fetchable URL, and the
        // fail-closed `imageLoadPolicy` would otherwise render it as an "external image"
        // tap-to-load card whose host is a UUID.
        if let display = viewModel.pendingAttachmentDisplay(forPlaceholderURL: url) {
            PendingAttachmentImageView(
                alt: alt, display: display,
                onRetry: { viewModel.retryPendingAttachment(placeholderURL: url) },
                onRemove: { viewModel.removePendingAttachment(blockID: block.id) }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let imageURL = URL(string: url) {
            MarkdownImageView(alt: alt, url: imageURL, serverOrigin: serverOrigin)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        } else {
            Text("![\(alt)](\(url))")
                .font(DocsFont.code)
                .foregroundStyle(DocsColor.textPrimary)
        }
    }

    private var textView: some View {
        BlockTextView(
            text: Binding(
                get: { block.text },
                set: { viewModel.updateText(blockID: block.id, text: $0) }
            ),
            styling: blockTextStyling(for: block.kind, dynamicTypeSize: dynamicTypeSize),
            isFocused: viewModel.focusedBlockID == block.id,
            cursorRequest: viewModel.cursorRequest?.blockID == block.id ? viewModel.cursorRequest : nil,
            onEvent: { event in
                handle(event)
            },
            onCursorRequestHandled: { token in
                if viewModel.cursorRequest?.token == token {
                    viewModel.cursorRequest = nil
                }
            },
            editLinkTitle: loc[.editor_link_edit_title],
            removeLinkTitle: loc[.editor_link_remove]
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
        case .editLink(let span):
            viewModel.beginLinkEditing(blockID: block.id, span: span)
        case .removeLink(let span):
            viewModel.removeLink(blockID: block.id, span: span)
        }
    }
}
