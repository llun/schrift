import SwiftUI

/// The documents tab on a regular width: the list beside the open document.
///
/// The search field here searches inline rather than jumping to the Search tab
/// (`onSearchTap` stays nil), because the list is permanently on screen next to
/// the editor — there is nothing to navigate away from.
struct HomeSplitView: View {
    @Bindable var viewModel: HomeViewModel
    let serverHost: String
    /// Server origin for the editor's off-origin image gate (`imageLoadPolicy`).
    let serverOrigin: String
    /// Creates and opens a document. Previously absent here, which left iPad
    /// with no way to make one at all.
    var onNewDocument: (() -> Void)? = nil

    @State private var selectedDocument: Document?

    @Environment(LocalizationStore.self) private var loc

    var body: some View {
        NavigationSplitView {
            DocumentListView(
                viewModel: viewModel,
                serverHost: serverHost,
                onSelect: { selectedDocument = $0 },
                onNewDocument: onNewDocument
            )
        } detail: {
            if let selectedDocument {
                EditorScreen(
                    client: viewModel.client,
                    documentID: selectedDocument.id,
                    title: selectedDocument.title ?? loc[.common_untitled],
                    saveCoordinator: viewModel.saveCoordinator,
                    diagnostics: viewModel.diagnostics,
                    reach: selectedDocument.linkReach,
                    serverHost: serverHost,
                    serverOrigin: serverOrigin,
                    linkRole: selectedDocument.linkRole,
                    initialIsFavorite: selectedDocument.isFavorite,
                    isOffline: viewModel.isOffline,
                    onDeleted: {
                        self.selectedDocument = nil
                        Task { await viewModel.load() }
                    },
                    onOpenDocument: { self.selectedDocument = $0 }
                )
                .id(selectedDocument.id)
            } else {
                ContentUnavailableView {
                    Label {
                        Text(loc[.home_select_document])
                    } icon: {
                        MaterialSymbol(.description, size: 52)
                    }
                }
                .background(DocsColor.surfacePage)
            }
        }
    }
}

#Preview {
    HomeSplitView(
        viewModel: HomeViewModel(client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!)),
        serverHost: "docs.llun.dev",
        serverOrigin: "https://docs.llun.dev"
    )
    .environment(LocalizationStore())
}
