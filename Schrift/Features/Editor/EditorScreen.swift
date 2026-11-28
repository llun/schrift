import SwiftUI

/// Owns the `EditorViewModel` as view state so parent re-renders (the sidebar
/// refreshing, offline state flipping, list reloads) never recreate the
/// editing session mid-edit. A fresh model is created only when the screen's
/// identity changes (a different document is opened). `NativeEditorOpen` reads the
/// native preference (on by default) at each safe open/reopen; preference changes never
/// replace a focused editor.
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
    var onCreatedDocument: ((Document) -> Void)? = nil
    /// See `EditorView.signInGeneration`.
    var signInGeneration: Int = 0

    @State var viewModel: EditorViewModel
    /// Builds a fresh model for the same document, for when another account signs in under a
    /// screen that stays mounted (the re-login sheet): the old one's content is that account's.
    private let makeViewModel: @MainActor () -> EditorViewModel
    /// Retained past `init` because the Pages drawer reads the same store the
    /// view model writes; a test that isolates one must isolate both.
    private let childrenCache: DocumentChildrenCacheStore
    /// The row this screen was opened from. An account change drops it: its `abilities.update`
    /// is the previous account's answer, and a swapped screen must fail closed (read-only) until
    /// a fresh fetch says otherwise. A reference, so the drop is visible even where a `@State`
    /// write is lost (a screen driven before it is mounted); the model swap re-renders.
    @State var pinRow: PinRowBox

    init(
        client: DocsAPIClient,
        documentID: UUID,
        title: String,
        saveCoordinator: DocumentSaveCoordinator,
        entryIntent: NewDocumentEntryIntent? = nil,
        contentCache: DocumentContentCacheStore = DocumentContentCacheStore(),
        childrenCache: DocumentChildrenCacheStore = DocumentChildrenCacheStore(),
        diagnostics: APIDiagnosticsLog? = nil,
        availability: OnlineAvailability = OnlineAvailability(),
        reach: LinkReach,
        serverHost: String,
        serverOrigin: String,
        linkRole: LinkRole? = nil,
        initialIsFavorite: Bool = false,
        pinRow: Document? = nil,
        isOffline: Bool = false,
        onDeleted: (() -> Void)? = nil,
        onOpenDocument: ((Document) -> Void)? = nil,
        onCreatedDocument: ((Document) -> Void)? = nil,
        signInGeneration: Int = 0
    ) {
        let makeViewModel = { @MainActor (entryIntent: NewDocumentEntryIntent?) in
            EditorViewModel(
                client: client,
                documentID: documentID,
                title: title,
                saveCoordinator: saveCoordinator,
                entryIntent: entryIntent,
                serverOrigin: serverOrigin,
                contentCache: contentCache,
                childrenCache: childrenCache,
                diagnostics: diagnostics,
                availability: availability
            )
        }
        _viewModel = State(initialValue: makeViewModel(entryIntent))
        self.makeViewModel = { makeViewModel(nil) }
        self.childrenCache = childrenCache
        self.reach = reach
        self.serverHost = serverHost
        self.serverOrigin = serverOrigin
        self.linkRole = linkRole
        self.initialIsFavorite = initialIsFavorite
        _pinRow = State(initialValue: PinRowBox(pinRow))
        self.isOffline = isOffline
        self.onDeleted = onDeleted
        self.onOpenDocument = onOpenDocument
        self.onCreatedDocument = onCreatedDocument
        self.signInGeneration = signInGeneration
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
            pinRow: pinRow.row,
            isOffline: isOffline,
            onDeleted: onDeleted,
            onOpenDocument: onOpenDocument,
            onCreatedDocument: onCreatedDocument,
            signInGeneration: signInGeneration
        )
        // A new model is a new editor: the old one disappears, flushing its edits under the
        // account it loaded for — kept for that account, never sent under this one.
        .id(ObjectIdentifier(viewModel))
        // `initial`: a screen off-screen during the change (beneath another in the stack, or on
        // another tab) checks again when it comes back.
        .onChange(of: signInGeneration, initial: true) { _, _ in replaceIfAnotherAccount() }
        .onChange(of: viewModel.signedInUserID, initial: true) { _, _ in replaceIfAnotherAccount() }
    }

    /// Returns the model now on screen, or nil when the account did not change.
    @discardableResult
    func replaceIfAnotherAccount() -> EditorViewModel? {
        guard viewModel.loadedSession.isAnotherAccount(than: viewModel.saveCoordinator.signedInSession) else {
            return nil
        }
        viewModel.endForAccountChange()
        // A document only this device holds was the previous account's: there is nothing to
        // reload it as, so the screen closes instead. The model is replaced either way, so the
        // old one's content never stays on screen under the new account.
        let wasLocalDocument = viewModel.isLocalDocument
        let replacement = makeViewModel()
        viewModel = replacement
        // The old row's abilities are the previous account's: fail closed until a fresh fetch.
        pinRow.row = nil
        if wasLocalDocument, let onDeleted { onDeleted() }
        return replacement
    }
}

/// Holds the row a screen was opened from so an account change can drop it (see
/// `EditorScreen.pinRow`).
@MainActor
final class PinRowBox {
    var row: Document?
    init(_ row: Document?) { self.row = row }
}
