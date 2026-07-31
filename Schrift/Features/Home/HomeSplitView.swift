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

    @State private var selectedDocument: Document?

    @Environment(LocalizationStore.self) private var loc

    var body: some View {
        NavigationSplitView {
            DocumentListView(
                viewModel: viewModel,
                serverHost: serverHost,
                onSelect: { selectedDocument = $0 },
                // Creation is owned here, not passed in: a split view opens a
                // document by *selecting* it. Handing this to the tab shell's
                // push-a-path version would create the document on the server
                // and then appear to do nothing, because this idiom never
                // renders that stack. (iPad had no create action at all before.)
                onNewDocument: {
                    Task {
                        if let document = await viewModel.createDocument() {
                            selectedDocument = document
                        }
                    }
                }
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
