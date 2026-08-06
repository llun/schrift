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

    private let client: DocsAPIClient
    private let documentID: UUID

    /// Optional so every existing call site and `#Preview` keeps working; nil simply means
    /// "no local documents here", which is true of every screen that does not own one.
    private let saveCoordinator: DocumentSaveCoordinator?

    init(
        client: DocsAPIClient, documentID: UUID, isFavorite: Bool,
        saveCoordinator: DocumentSaveCoordinator? = nil
    ) {
        self.saveCoordinator = saveCoordinator
        self.client = client
        self.documentID = documentID
        self.isFavorite = isFavorite
    }

    func toggleFavorite() async {
        errorKey = nil
        do {
            try await client.setFavorite(documentID: documentID, isFavorite: !isFavorite)
            isFavorite.toggle()
        } catch {
            errorKey = .options_error_toggle_favorite
        }
    }

    /// This document exists only on this device — every server-addressed row must be hidden.
    var isLocalDocument: Bool {
        saveCoordinator?.isPendingCreate(documentID: documentID) ?? false
    }

    /// Whether deleting this document also throws away sub-pages that exist nowhere else, so
    /// the confirmation can say so. Not gated on `isLocalDocument`: a *checkpointed* record is
    /// met under its server id, and its sub-pages still go with it.
    var hasLocalSubpages: Bool {
        saveCoordinator?.hasPendingLocalChildren(documentID: documentID) ?? false
    }

    func delete() async {
        isDeleting = true
        errorKey = nil
        defer { isDeleting = false }
        // A document created on this device may exist in one of three states, and only the
        // middle one is ambiguous:
        //
        //  - no record at all — an ordinary server document; delete it there;
        //  - a record with no checkpoint — it exists *nowhere* but here, so there is nothing
        //    to DELETE and a request would 404. Dropping the local work is the whole delete;
        //  - a record that has been checkpointed — `isPendingCreate` is still true, but the
        //    POST has landed and a real server document exists under `syncedServerID`. This is
        //    the case that must not be treated as purely local: doing so leaves the server
        //    copy alive, and it returns in Home's next list fetch with nothing on the device
        //    that knows about it.
        if let coordinator = saveCoordinator, coordinator.isPendingCreate(documentID: documentID) {
            if let serverID = coordinator.syncedServerID(forLocalID: documentID) {
                do {
                    try await client.deleteDocument(documentID: serverID)
                } catch let error as DocsAPIError where error == .notFound {
                    // **Already gone — fall through and clear, do not report.** A 404 here is
                    // indistinguishable from a co-author having deleted it first, and treating
                    // it as a failure re-arms the exact resurrection `discardPendingWork`'s
                    // server-id branch exists to prevent: the record survives, the next resume
                    // GETs `serverID`, takes the same 404, clears the checkpoint, and the pass
                    // after that **re-POSTs the document from its draft** — deleted, and back
                    // with its old body under a new id. The user's intent is known and there
                    // is provably nothing left to strand, which is precisely when clearing is
                    // the safe direction.
                } catch {
                    // Anything else — transport, 5xx, 403 — leaves everything: the record may
                    // still name a live document, and discarding the local trace would strand
                    // it permanently with no affordance to reach it.
                    errorKey = .options_error_delete
                    return
                }
            }
            // Drops the record *and* its draft, so no replay can resurrect what the user threw
            // away. Matched on either id — the checkpointed branch is keyed on the server one.
            coordinator.discardPendingWork(documentID: documentID)
            didDelete = true
            return
        }
        do {
            try await client.deleteDocument(documentID: documentID)
            didDelete = true
        } catch {
            errorKey = .options_error_delete
        }
    }
}
