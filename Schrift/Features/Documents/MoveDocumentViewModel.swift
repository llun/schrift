import Foundation

/// Choosing where a document should live.
///
/// The destinations offered are **top-level documents only**, plus "Home" when the document is
/// not already there. That is a deliberate v1 shape rather than a limitation of the endpoint:
/// a one-level list needs one fetch and no expand/collapse state, and it makes the one
/// genuinely dangerous move — filing a document inside its own subtree — nearly unreachable,
/// since a root can only be a descendant of another root in the rare case the server settles
/// with a 400 anyway.
@MainActor
@Observable
final class MoveDocumentViewModel {
    /// Server documents at the top level, minus this one.
    private(set) var destinations: [Document] = []
    /// Top-level documents that exist only on this device. Offered **only** when the document
    /// being moved is itself local: `documents/{local-uuid}/move/` names nothing on the server,
    /// so a server document filed under one could never be sent.
    private(set) var localDestinations: [Document] = []
    private(set) var isLoading = false
    private(set) var isMoving = false
    var errorKey: L10nKey?
    /// Set once the move has landed, so the view can dismiss and tell its presenter.
    private(set) var didMove = false

    private let documentID: UUID
    /// The document as the presenting surface is drawing it, when there is one. A row surface
    /// has it; the editor's Options sheet does not (it holds an id and a title), and nil there
    /// is honest — the destination picks the document up on its next fetch rather than caching
    /// a row with an invented `depth`/`path`.
    private let row: Document?
    private let actions: DocumentActions
    private let client: DocsAPIClient
    private let saveCoordinator: DocumentSaveCoordinator?
    private let signedInUser: SignedInUserStore
    private let userDefaults: UserDefaults

    init(
        client: DocsAPIClient,
        documentID: UUID,
        row: Document? = nil,
        saveCoordinator: DocumentSaveCoordinator? = nil,
        signedInUser: SignedInUserStore = SignedInUserStore(),
        userDefaults: UserDefaults = .standard
    ) {
        self.client = client
        self.documentID = documentID
        self.row = row
        self.saveCoordinator = saveCoordinator
        self.signedInUser = signedInUser
        self.userDefaults = userDefaults
        self.actions = DocumentActions(
            client: client, saveCoordinator: saveCoordinator, signedInUser: signedInUser)
    }

    var isLocalDocument: Bool { actions.isLocalDocument(documentID) }

    /// Whether to offer "Home".
    ///
    /// For a local document the record's own `parentID` answers it exactly. For a server one
    /// the depth does: a root is already home. When the depth is unknown (the Options sheet,
    /// which has an id rather than a row) the row is offered — a root filed beside another
    /// root is a harmless no-op, whereas withholding it would strand a sub-page opened
    /// straight from a link with no way back to the top level.
    var offersHome: Bool {
        if isLocalDocument { return saveCoordinator?.pendingCreateParentID(forLocalID: documentID) != nil }
        guard let depth = row?.depth ?? resolvedDepth else { return true }
        return depth > 1
    }

    /// True once a load has finished and found nowhere to put the document.
    var isEmpty: Bool {
        !isLoading && !offersHome && destinations.isEmpty && localDestinations.isEmpty
    }

    /// The depth learned from the destinations fetch, for a caller that had no row to read it
    /// from: a document listed among the roots is a root.
    private var resolvedDepth: Int?

    func loadDestinations() async {
        errorKey = nil
        isLoading = true
        defer { isLoading = false }

        // A local document can be filed under another local one — the replay orders the two
        // creates — so those are worth offering even with no network at all.
        localDestinations =
            isLocalDocument
            ? (saveCoordinator?.pendingLocalDocuments(parentID: nil, currentUserID: signedInUser.userID) ?? [])
                .filter { $0.id != documentID }
            : []

        // Work Offline is a no-network contract on every read path — the same early return
        // `HomeViewModel`, `SharedViewModel` and `PagesTreeViewModel` make. Local destinations
        // are already in hand and stay offered.
        guard !userDefaults.bool(forKey: "schrift.workOffline") else { return }

        do {
            let response = try await client.listDocuments(ordering: "-updated_at")
            if let mine = response.results.first(where: { $0.id == documentID }) {
                resolvedDepth = mine.depth
            }
            destinations = response.results.filter { candidate in
                // Roots only: the picker offers one level, so anything deeper is not a
                // destination it can name.
                candidate.depth == 1 && candidate.id != documentID
                    // A document on its way to being deleted is no place to file work.
                    && !(saveCoordinator?.isListablePendingDelete(
                        documentID: candidate.id, currentUserID: signedInUser.userID) ?? false)
            }
        } catch {
            // Silent when there is still something to choose from — the cached-data silence
            // rule every list here follows. Loud only when the sheet would otherwise be blank.
            if localDestinations.isEmpty { errorKey = .move_error_load }
        }
    }

    func moveToHome() async {
        // A server document is promoted by being filed beside an existing root, so one has to
        // be named. `offersHome` is what keeps this reachable only when there is one.
        let sibling = isLocalDocument ? nil : destinations.first?.id
        if !isLocalDocument && sibling == nil {
            errorKey = .move_error
            return
        }
        await perform(.root(siblingRootID: sibling))
    }

    func move(under parent: Document) async {
        await perform(.under(parentID: parent.id))
    }

    private func perform(_ destination: DocumentMoveDestination) async {
        guard !isMoving else { return }
        errorKey = nil
        isMoving = true
        defer { isMoving = false }
        switch await actions.move(documentID: documentID, row: row, to: destination) {
        case .moved:
            didMove = true
        case .failed:
            errorKey = .move_error
        }
    }
}
