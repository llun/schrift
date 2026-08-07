import SwiftUI

/// Owns the `EditorViewModel` as view state so parent re-renders (the sidebar
/// refreshing, offline state flipping, list reloads) never recreate the
/// editing session mid-edit. A fresh model is created only when the screen's
/// identity changes (a different document is opened).
struct EditorScreen: View {
    let reach: LinkReach
    let serverHost: String
    /// Server origin for the off-origin image gate (`imageLoadPolicy`).
    let serverOrigin: String
    var linkRole: LinkRole? = nil
    var initialIsFavorite: Bool = false
    var isOffline: Bool = false
    var onDeleted: (() -> Void)? = nil
    var onOpenDocument: ((Document) -> Void)? = nil

    @State private var viewModel: EditorViewModel
    /// Retained past `init` because the Pages drawer reads the same store the
    /// view model writes; a test that isolates one must isolate both.
    private let childrenCache: DocumentChildrenCacheStore

    init(
        client: DocsAPIClient,
        documentID: UUID,
        title: String,
        saveCoordinator: DocumentSaveCoordinator,
        contentCache: DocumentContentCacheStore = DocumentContentCacheStore(),
        childrenCache: DocumentChildrenCacheStore = DocumentChildrenCacheStore(),
        diagnostics: APIDiagnosticsLog? = nil,
        reach: LinkReach,
        serverHost: String,
        serverOrigin: String,
        linkRole: LinkRole? = nil,
        initialIsFavorite: Bool = false,
        isOffline: Bool = false,
        onDeleted: (() -> Void)? = nil,
        onOpenDocument: ((Document) -> Void)? = nil
    ) {
        _viewModel = State(
            initialValue: EditorViewModel(
                client: client,
                documentID: documentID,
                title: title,
                saveCoordinator: saveCoordinator,
                serverOrigin: serverOrigin,
                contentCache: contentCache,
                childrenCache: childrenCache,
                diagnostics: diagnostics
            ))
        self.childrenCache = childrenCache
        self.reach = reach
        self.serverHost = serverHost
        self.serverOrigin = serverOrigin
        self.linkRole = linkRole
        self.initialIsFavorite = initialIsFavorite
        self.isOffline = isOffline
        self.onDeleted = onDeleted
        self.onOpenDocument = onOpenDocument
    }

    var body: some View {
        EditorView(
            viewModel: viewModel,
            reach: reach,
            serverHost: serverHost,
            serverOrigin: serverOrigin,
            childrenCache: childrenCache,
            linkRole: linkRole,
            initialIsFavorite: initialIsFavorite,
            isOffline: isOffline,
            onDeleted: onDeleted,
            onOpenDocument: onOpenDocument
        )
    }
}
