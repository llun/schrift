import SwiftUI

struct OptionsSheetView: View {
    @Bindable var viewModel: OptionsViewModel
    let shareURL: URL?
    var onShare: (() -> Void)? = nil
    var onDeleted: (() -> Void)? = nil
    /// Called when the link reached the pasteboard, so the presenter can
    /// confirm it after this sheet closes.
    var onLinkCopied: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(LocalizationStore.self) private var loc
    @State private var isConfirmingDelete = false
    @State private var isPresentingVersionHistory = false
    @State private var versionHistoryViewModel: VersionHistoryViewModel
    private let restoreURL: URL?

    init(
        viewModel: OptionsViewModel,
        client: DocsAPIClient,
        documentID: UUID,
        serverHost: String,
        shareURL: URL?,
        onLinkCopied: (() -> Void)? = nil,
        onShare: (() -> Void)? = nil,
        onDeleted: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.shareURL = shareURL
        self.onLinkCopied = onLinkCopied
        self.onShare = onShare
        self.onDeleted = onDeleted
        self.restoreURL = documentShareURL(serverHost: serverHost, documentID: documentID)
        _versionHistoryViewModel = State(
            initialValue: VersionHistoryViewModel(client: client, documentID: documentID))
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
                        onDeleted?()
                    }
                }
            }
        }
        .sheet(isPresented: $isPresentingVersionHistory) {
            VersionHistorySheetView(viewModel: versionHistoryViewModel, restoreURL: restoreURL)
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
