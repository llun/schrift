import Foundation

func documentShareURL(serverHost: String, documentID: UUID) -> URL? {
    URL(string: "https://\(serverHost)/docs/\(documentID.uuidString.lowercased())/")
}

@MainActor
@Observable
final class OptionsViewModel {
    private var originalIsFavorite: Bool
    private let saveCoordinator: DocumentSaveCoordinator?
    private let signedInUser: SignedInUserStore
    var isFavorite: Bool {
        get {
            saveCoordinator?.pins.value(
                for: documentID, fallback: originalIsFavorite, ownerUserID: signedInUser.userID, fetchedAt: -1)
                ?? originalIsFavorite
        }
        set { originalIsFavorite = newValue }
    }
    var isDeleting = false
    private var actionErrorKey: L10nKey?
    var errorKey: L10nKey? {
        get { actionErrorKey ?? saveCoordinator?.pins.failure(for: documentID, ownerUserID: signedInUser.userID) }
        set { actionErrorKey = newValue }
    }
    private(set) var didDelete = false

    /// Whether the deletion `didDelete` reports was **queued** rather than made.
    ///
    /// The screen has to tell the two apart, and only at this moment: a completed delete
    /// tears everything down, while a queued one must leave the draft, the create record and
    /// the caches exactly where they are, because they are what the undo restores. See
    /// `EditorViewModel.handleDidQueueDelete`.
    private(set) var didQueueDelete = false

    private let documentID: UUID
    private let pinRow: Document?

    /// The delete/pin ladder itself, shared with every list surface that offers the same two
    /// verbs from a swipe. This view model keeps only the translation into screen state —
    /// `didDelete`, `didQueueDelete`, `errorKey`, `isDeleting` — which is the part that is
    /// genuinely Options-specific.
    private let actions: DocumentActions

    init(
        client: DocsAPIClient, documentID: UUID, isFavorite: Bool,
        saveCoordinator: DocumentSaveCoordinator? = nil,
        signedInUser: SignedInUserStore = SignedInUserStore(),
        pinRow: Document? = nil
    ) {
        self.documentID = documentID
        self.pinRow = pinRow?.id == documentID ? pinRow : nil
        self.originalIsFavorite = isFavorite
        self.saveCoordinator = saveCoordinator
        self.signedInUser = signedInUser
        self.actions = DocumentActions(
            client: client, saveCoordinator: saveCoordinator, signedInUser: signedInUser)
    }

    func toggleFavorite(isOffline: Bool = false) async {
        errorKey = nil
        switch await actions.setFavorite(
            documentID: documentID, isFavorite: !isFavorite, row: pinRow, isOffline: isOffline)
        {
        case .changed(let value): isFavorite = value
        case .queued: break
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
