import SwiftUI

struct HomeSplitView: View {
    @Bindable var viewModel: HomeViewModel
    let serverHost: String

    @State private var selectedDocument: Document?

    @Environment(LocalizationStore.self) private var loc

    var body: some View {
        NavigationSplitView {
            DocumentListView(viewModel: viewModel, serverHost: serverHost, onSelect: { selectedDocument = $0 })
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
        serverHost: "docs.llun.dev"
    )
    .environment(LocalizationStore())
}
