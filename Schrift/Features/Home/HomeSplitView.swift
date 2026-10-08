import SwiftUI

/// The documents tab on a regular width: the list beside the open document.
///
/// The search field here searches inline rather than pushing a dedicated Search screen
/// (`onSearchTap` stays nil), because the list is permanently on screen next to
/// the editor — there is nothing to navigate away from.
struct HomeSplitView: View {
    @Environment(\.docsTheme) private var theme
    @Bindable var viewModel: HomeViewModel
    let serverHost: String
    /// Server origin for the editor's off-origin image gate (`imageLoadPolicy`).
    let serverOrigin: String

    @State private var selectedRoute: DocumentEditorRoute?
    /// The iPhone Duo's crease when unfolded; nil everywhere else.
    @State private var fold: ClosedRange<CGFloat>?
    @State private var width: CGFloat = 0

    @Environment(LocalizationStore.self) private var loc

    var body: some View {
        NavigationSplitView {
            DocumentListView(
                viewModel: viewModel,
                serverHost: serverHost,
                onSelect: { selectedRoute = DocumentEditorRoute(document: $0) },
                // Creation is owned here, not passed in: a split view opens a
                // document by *selecting* it. Handing this to the tab shell's
                // push-a-path version would create the document on the server
                // and then appear to do nothing, because this idiom never
                // renders that stack. (iPad had no create action at all before.)
                onNewDocument: {
                    Task {
                        if let document = await viewModel.createDocument() {
                            selectedRoute = DocumentEditorRoute(createdDocument: document)
                        }
                    }
                }
            )
            .environment(\.docsCanvasRole, DocsCanvasRole.sidebar)
            // Unfolded, the list fills the left panel and the document the right one.
            .sidebarWidth(fold.flatMap { FoldLayout.sidebarWidth(fold: $0, width: width) })
        } detail: {
            if let selectedRoute {
                let selectedDocument = selectedRoute.document
                EditorScreen(
                    client: viewModel.client,
                    documentID: selectedDocument.id,
                    title: selectedDocument.title ?? loc[.common_untitled],
                    saveCoordinator: viewModel.saveCoordinator,
                    entryIntent: selectedRoute.entryIntent,
                    diagnostics: viewModel.diagnostics,
                    availability: viewModel.availability,
                    reach: selectedDocument.linkReach,
                    serverHost: serverHost,
                    serverOrigin: serverOrigin,
                    linkRole: selectedDocument.linkRole,
                    initialIsFavorite: selectedDocument.isFavorite,
                    pinRow: selectedDocument,
                    onDeleted: {
                        self.selectedRoute = nil
                        Task { await viewModel.load() }
                    },
                    onOpenDocument: { self.selectedRoute = DocumentEditorRoute(document: $0) },
                    onCreatedDocument: { self.selectedRoute = DocumentEditorRoute(createdDocument: $0) }
                )
                .id(selectedDocument.id)
                // With the sidebar hidden the document spans the crease; keep it to one side.
                .foldClearance()
            } else {
                ContentUnavailableView {
                    Label {
                        Text(loc[.home_select_document])
                    } icon: {
                        MaterialSymbol(.description, size: 52)
                    }
                }
                .background(theme.colors.surfacePage)
            }
        }
        // The split view's own container shows through behind the status bar
        // and around the floating sidebar. Left alone it is the system
        // background, which matched only White's light page colour.
        .background(theme.colors.surfacePage.ignoresSafeArea())
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            width = $0
        }
        .foldAware { fold = $0 }
    }
}

extension View {
    @ViewBuilder
    fileprivate func sidebarWidth(_ width: CGFloat?) -> some View {
        if let width {
            navigationSplitViewColumnWidth(min: width, ideal: width, max: width)
        } else {
            self
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
    .environment(AttachmentLoader.inert())
    .environment(ImageLoader.inert())
}
