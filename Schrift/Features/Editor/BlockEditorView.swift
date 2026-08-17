import SwiftUI

/// The editable block canvas: each block is an in-place editable row with
/// Notion-style keyboard behavior (Return splits, backspace at start merges).
///
/// Its geometry — gutter, inter-block gap, header, and the gap under the header
/// — comes from `EditorBlockMetrics`, the same table `readingSurface` lays out
/// with, so entering edit mode places a caret rather than re-flowing the page.
/// The document header is injected rather than built here: it is the *same*
/// view on both surfaces, and only its status slot differs.
struct BlockEditorView<Header: View>: View {
    @Bindable var viewModel: EditorViewModel
    /// Threaded to reach the image leaf's off-origin load gate
    /// (`imageLoadPolicy`) and the attachment leaf's card; every other row kind
    /// ignores it.
    let serverOrigin: String
    /// Chrome for the attachment leaf: editing offline must say "Available when
    /// online" over an uncached attachment rather than spin on a request that
    /// cannot succeed. Every other row kind ignores it.
    var isOffline: Bool = false
    /// Carries the reading surface's scroll anchor in, and this canvas's back
    /// out. See `EditorScrollAnchorStore` for why it is not observable.
    let scrollAnchor: EditorScrollAnchorStore
    @ViewBuilder var header: () -> Header

    @Environment(LocalizationStore.self) private var loc
    @State private var scrollPosition = ScrollPosition()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: EditorBlockMetrics.blockSpacing) {
                    header()
                        // The stack already contributes `blockSpacing`; this
                        // tops it up to the header-to-body gap the reading
                        // surface leaves, rather than restating that gap.
                        .padding(.bottom, EditorBlockMetrics.headerToBodySpacing - EditorBlockMetrics.blockSpacing)
                        .id(EditorScrollTarget.header)

                    ForEach(Array(viewModel.blocks.enumerated()), id: \.element.id) { index, block in
                        BlockEditorRow(
                            viewModel: viewModel, block: block, index: index, serverOrigin: serverOrigin,
                            isOffline: isOffline
                        )
                        .id(EditorScrollTarget.block(block.id))
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
                        .id(EditorScrollTarget.trailer)
                }
                .padding(.horizontal, EditorBlockMetrics.gutter)
                .padding(.top, DocsSpacing.spaceSM)
            }
            .scrollPosition($scrollPosition)
            // Record continuously so `Done` hands the reading surface back the
            // place the user was editing, not the top of the page.
            // `contentOffset.y` is measured from the scroll view's bounds origin,
            // which sits at `-contentInsets.top` when scrolled to the top, while
            // `scrollTo(y:)` positions relative to the content's own top edge.
            // Recording the distance scrolled *from the content top* is what makes
            // the two agree; without it every handoff lands one safe-area inset
            // out (~110pt on this device, in both directions).
            .onScrollGeometryChange(for: CGFloat.self) {
                $0.contentOffset.y + $0.contentInsets.top
            } action: { _, offset in
                scrollAnchor.noteScrolled(to: offset)
            }
            .onAppear {
                guard let offsetY = scrollAnchor.consumePendingOffset() else { return }
                // Applied repeatedly, and that is not superstition. This canvas
                // is a `LazyVStack`: when `onAppear` runs it has realized only
                // the first screenful, so its content is short and the scroll
                // **clamps** to the little that exists — measured at ~108pt shy
                // of the target on a two-screen document. Each pass realizes the
                // rows the previous one scrolled past, so the reachable offset
                // grows until it covers the target. The reading surface needs
                // none of this: it is a plain `VStack`, laid out in full.
                //
                // Bounded rather than looped-until-equal: a document shorter
                // than the requested offset would never converge.
                scrollPosition.scrollTo(y: offsetY)
                Task { @MainActor in
                    for _ in 0..<4 {
                        await Task.yield()
                        scrollPosition.scrollTo(y: offsetY)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.focusedBlockID) { _, focusedID in
                guard let focusedID else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(EditorScrollTarget.block(focusedID), anchor: .center)
                }
            }
        }
    }
}

/// One editable row.
///
/// Internal rather than private so `EditorSurfaceParityTests` can host the
/// **real** row and measure it against the `MarkdownBlockView` it replaces. That
/// end-to-end comparison is the only thing that catches a per-kind divergence in
/// what a block actually occupies — a shared style table proves the two read the
/// same values, not that the two frameworks then lay them out the same way.
struct BlockEditorRow: View {
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
                .padding(.vertical, EditorBlockMetrics.dividerVerticalPadding)
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
            // `editorBlockDecoration` preserves that property — it varies only
            // padding/background/overlay values, never which view is decorated.
            //
            // Both the spacing and the decoration come from `EditorBlockStyle`,
            // the table `MarkdownBlockView` reads, so this row and the reading
            // row it replaces occupy the same space.
            HStack(
                alignment: .top,
                spacing: blockHasAdornment(block.kind) ? EditorBlockMetrics.adornmentSpacing : 0
            ) {
                EditorBlockAdornment(
                    kind: block.kind, numberedIndex: numberedIndex(of: index, in: viewModel.blocks),
                    onToggleChecklist: { viewModel.toggleChecklist(blockID: block.id) })
                textView
                    .editorBlockDecoration(blockDecoration(for: block.kind, text: block.text))
            }
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
            styling: blockTextStyling(for: block, dynamicTypeSize: dynamicTypeSize),
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
