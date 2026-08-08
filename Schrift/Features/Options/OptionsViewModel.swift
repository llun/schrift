import Foundation

func documentShareURL(serverHost: String, documentID: UUID) -> URL? {
    URL(string: "https://\(serverHost)/docs/\(documentID.uuidString.lowercased())/")
}

@MainActor
@Observable
final class OptionsViewModel {
    var isFavorite: Bool
    var isDeleting = false
    var errorKey: L10nKey?
    private(set) var didDelete = false

    /// Whether the deletion `didDelete` reports was **queued** rather than made.
    ///
    /// The screen has to tell the two apart, and only at this moment: a completed delete
    /// tears everything down, while a queued one must leave the draft, the create record and
    /// the caches exactly where they are, because they are what the undo restores. See
    /// `EditorViewModel.handleDidQueueDelete`.
    private(set) var didQueueDelete = false

    private let documentID: UUID

    /// The delete/pin ladder itself, shared with every list surface that offers the same two
    /// verbs from a swipe. This view model keeps only the translation into screen state —
    /// `didDelete`, `didQueueDelete`, `errorKey`, `isDeleting` — which is the part that is
    /// genuinely Options-specific.
    private let actions: DocumentActions

    init(
        client: DocsAPIClient, documentID: UUID, isFavorite: Bool,
        saveCoordinator: DocumentSaveCoordinator? = nil,
        signedInUser: SignedInUserStore = SignedInUserStore()
    ) {
        self.documentID = documentID
        self.isFavorite = isFavorite
        self.actions = DocumentActions(
            client: client, saveCoordinator: saveCoordinator, signedInUser: signedInUser)
    }

    func toggleFavorite() async {
        errorKey = nil
        switch await actions.setFavorite(documentID: documentID, isFavorite: !isFavorite) {
        case .changed(let value): isFavorite = value
        case .failed: errorKey = .options_error_toggle_favorite
        }
    }

    /// This document exists only on this device — every server-addressed row must be hidden.
    var isLocalDocument: Bool { actions.isLocalDocument(documentID) }

    /// Whether deleting this document also throws away sub-pages that exist nowhere else, so
    /// the confirmation can say so. Not gated on `isLocalDocument`: a *checkpointed* record is
    /// met under its server id, and its sub-pages still go with it.
    var hasLocalSubpages: Bool { actions.hasLocalSubpages(documentID) }

    func delete() async {
        isDeleting = true
        errorKey = nil
        defer { isDeleting = false }
        switch await actions.delete(documentID: documentID) {
        case .deleted:
            didDelete = true
        case .queued:
            // The screen pops either way; `didQueueDelete` is what tells it to leave the
            // draft, the record and the caches alone, because they are what the undo restores.
            didQueueDelete = true
            didDelete = true
        case .failed:
            errorKey = .options_error_delete
        }
    }
}
