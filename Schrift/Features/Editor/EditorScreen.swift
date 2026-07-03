import SwiftUI

/// Owns the `EditorViewModel` as view state so parent re-renders (the sidebar
/// refreshing, offline state flipping, list reloads) never recreate the
/// editing session mid-edit. A fresh model is created only when the screen's
/// identity changes (a different document is opened).
struct EditorScreen: View {
    let reach: LinkReach
    let serverHost: String
    var linkRole: LinkRole? = nil
    var initialIsFavorite: Bool = false
    var isOffline: Bool = false
    var onBack: (() -> Void)? = nil
    var onDeleted: (() -> Void)? = nil
    var onOpenDocument: ((Document) -> Void)? = nil

    @State private var viewModel: EditorViewModel

    init(
        client: DocsAPIClient,
        documentID: UUID,
        title: String,
        saveCoordinator: DocumentSaveCoordinator,
        contentCache: DocumentContentCacheStore = DocumentContentCacheStore(),
        reach: LinkReach,
        serverHost: String,
        linkRole: LinkRole? = nil,
        initialIsFavorite: Bool = false,
        isOffline: Bool = false,
        onBack: (() -> Void)? = nil,
        onDeleted: (() -> Void)? = nil,
        onOpenDocument: ((Document) -> Void)? = nil
    ) {
        _viewModel = State(initialValue: EditorViewModel(
            client: client,
            documentID: documentID,
            title: title,
            saveCoordinator: saveCoordinator,
            contentCache: contentCache
        ))
        self.reach = reach
        self.serverHost = serverHost
        self.linkRole = linkRole
        self.initialIsFavorite = initialIsFavorite
        self.isOffline = isOffline
        self.onBack = onBack
        self.onDeleted = onDeleted
        self.onOpenDocument = onOpenDocument
    }

    var body: some View {
        EditorView(
            viewModel: viewModel,
            reach: reach,
            serverHost: serverHost,
            linkRole: linkRole,
            initialIsFavorite: initialIsFavorite,
            isOffline: isOffline,
            onBack: onBack,
            onDeleted: onDeleted,
            onOpenDocument: onOpenDocument
        )
    }
}
