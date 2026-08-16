import SwiftUI

struct OptionsSheetView: View {
    @Bindable var viewModel: OptionsViewModel
    let shareURL: URL?
    var onShare: (() -> Void)? = nil
    /// Called once the deletion has been made **or queued**, with `queued: true` for the
    /// latter. The presenter needs the distinction: a completed delete purges every local
    /// copy, while a queued one must leave the draft and the record alone — they are what the
    /// undo restores.
    var onDeleted: ((_ queued: Bool) -> Void)? = nil
    /// Called when the link reached the pasteboard, so the presenter can
    /// confirm it after this sheet closes.
    var onLinkCopied: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(LocalizationStore.self) private var loc
    @State private var isConfirmingDelete = false
    @State private var isPresentingVersionHistory = false
    @State private var versionHistoryViewModel: VersionHistoryViewModel
    @State private var isPresentingMove = false
    @State private var moveViewModel: MoveDocumentViewModel
    private let restoreURL: URL?

    init(
        viewModel: OptionsViewModel,
        client: DocsAPIClient,
        documentID: UUID,
        serverHost: String,
        shareURL: URL?,
        saveCoordinator: DocumentSaveCoordinator? = nil,
        signedInUser: SignedInUserStore = SignedInUserStore(),
        onLinkCopied: (() -> Void)? = nil,
        onShare: (() -> Void)? = nil,
        onDeleted: ((_ queued: Bool) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.shareURL = shareURL
        self.onLinkCopied = onLinkCopied
        self.onShare = onShare
        self.onDeleted = onDeleted
        self.restoreURL = documentShareURL(serverHost: serverHost, documentID: documentID)
        _versionHistoryViewModel = State(
            initialValue: VersionHistoryViewModel(client: client, documentID: documentID))
        // No `row:` — this screen holds an id and a title, not the `Document` a list draws. The
        // move still lands; the destination simply picks the document up on its next fetch
        // rather than being handed a row with an invented `depth`/`path`.
        _moveViewModel = State(
            initialValue: MoveDocumentViewModel(
                client: client, documentID: documentID, saveCoordinator: saveCoordinator,
                signedInUser: signedInUser))
    }

    var body: some View {
        // A flat, boxless list (handoff `OptionsSheet`): a pinned `SheetHeader`
        // over `ListRow`s drawn directly on the page surface — no `ListSection`
        // card and no `ProfileRowDivider`.
        VStack(spacing: 0) {
            SheetHeader(title: loc[.options_title], closeLabel: loc[.common_close], onClose: { dismiss() })

            if let errorKey = viewModel.errorKey {
                Text(loc[errorKey])
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DocsSpacing.gutter)
                    .padding(.bottom, DocsSpacing.spaceXS)
            }

            ScrollView {
                VStack(spacing: 0) {
                    // Everything above Delete addresses the *server's* copy, and a document
                    // created on this device has none: Pin POSTs to `…/favorite/` and 404s,
                    // Copy link yields a URL nobody can open (and says "Link copied" about
                    // it), Share lists accesses that do not exist, and Version history asks
                    // for versions of an id the server has never seen. The toolbar already
                    // drops Share for these; this sheet is the other way in, and would put
                    // all four back.
                    //
                    // Delete stays, and is exactly what a local document needs — it is the
                    // only way to throw one away.
                    if !viewModel.isLocalDocument {
                        ListRow(
                            icon: .push_pin,
                            title: viewModel.isFavorite ? loc[.options_unpin] : loc[.options_pin],
                            value: viewModel.isFavorite ? loc[.options_pinned] : nil,
                            action: { Task { await viewModel.toggleFavorite() } }
                        )

                        ListRow(icon: .link, title: loc[.options_copy_link], action: { copyLink() })

                        if onShare != nil {
                            ListRow(
                                icon: .group, title: loc[.options_share], showsChevron: true,
                                action: {
                                    onShare?()
                                    dismiss()
                                })
                        }

                        ListRow(
                            icon: .history, title: loc[.versions_title], showsChevron: true,
                            action: { isPresentingVersionHistory = true })
                    }

                    // **Outside** the block above, like Delete: a locally-created document can
                    // be moved, because its move is a re-parenting of the pending record on
                    // this device rather than a request the server would 404.
                    ListRow(
                        icon: .account_tree, title: loc[.options_move], showsChevron: true,
                        action: { isPresentingMove = true })

                    ListRow(
                        icon: .delete, title: loc[.options_delete_document], isDestructive: true,
                        action: { isConfirmingDelete = true })
                }
            }
        }
        .background(DocsColor.surfacePage)
        // A system alert, not an action sheet: this is a destructive confirm
        // with one verb, which is exactly what the handoff reserves alerts for.
        .alert(loc[.options_delete_confirm_title], isPresented: $isConfirmingDelete) {
            Button(loc[.common_cancel], role: .cancel) {}
            Button(loc[.options_delete], role: .destructive) {
                Task {
                    await viewModel.delete()
                    if viewModel.didDelete {
                        dismiss()
                        onDeleted?(viewModel.didQueueDelete)
                    }
                }
            }
        } message: {
            // Only when there is something extra to lose. A document with no sub-pages of its
            // own — every document on a server-backed screen — keeps the bare title it has
            // always had, so this cannot become chrome the user learns to skip past.
            if viewModel.hasLocalSubpages {
                Text(loc[.options_delete_confirm_subpages])
            }
        }
        .sheet(isPresented: $isPresentingVersionHistory) {
            VersionHistorySheetView(viewModel: versionHistoryViewModel, restoreURL: restoreURL)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isPresentingMove) {
            // Both sheets close on success: this one is about a document that is no longer
            // where the user opened it from.
            MoveDocumentSheetView(viewModel: moveViewModel, onMoved: { dismiss() })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private func copyLink() {
        if let shareURL {
            UIPasteboard.general.string = shareURL.absoluteString
            // Reported to the presenter rather than shown here: this sheet is
            // about to dismiss, and a toast inside it would go with it.
            onLinkCopied?()
        }
        dismiss()
    }
}

#Preview {
    let client = DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!)
    let documentID = UUID()
    OptionsSheetView(
        viewModel: OptionsViewModel(client: client, documentID: documentID, isFavorite: false),
        client: client,
        documentID: documentID,
        serverHost: "docs.llun.dev",
        shareURL: URL(string: "https://docs.llun.dev/docs/abc/")
    )
    .environment(LocalizationStore())
}
