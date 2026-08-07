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

    private let client: DocsAPIClient
    private let documentID: UUID

    /// Optional so every existing call site and `#Preview` keeps working; nil simply means
    /// "no local documents here", which is true of every screen that does not own one.
    private let saveCoordinator: DocumentSaveCoordinator?
    /// Who is signed in, for the tombstone's `ownerUserID`. A queued deletion nobody can be
    /// attributed to is neither sent nor shown, so a deletion that could not name the user
    /// reports the ordinary error instead of silently going nowhere.
    private let signedInUser: SignedInUserStore

    init(
        client: DocsAPIClient, documentID: UUID, isFavorite: Bool,
        saveCoordinator: DocumentSaveCoordinator? = nil,
        signedInUser: SignedInUserStore = SignedInUserStore()
    ) {
        self.saveCoordinator = saveCoordinator
        self.signedInUser = signedInUser
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
                    // Worth retrying — offline, a 5xx, a rate limit — so queue it and let the
                    // replay send it. **Nothing local is cleared on this path**, deliberately:
                    // the record, its draft and its subtree are what the undo restores, and
                    // `completePendingDelete` is what removes them once the DELETE has really
                    // landed. Note the tombstone names `serverID` — the id that exists — while
                    // every local trace stays keyed on the local one.
                    if queueDeletion(of: serverID, coordinator: coordinator, failure: error) {
                        return
                    }
                    // Rejected on the merits, or nothing to attribute the deletion to: leave
                    // everything. The record may still name a live document, and discarding
                    // the local trace would strand it permanently with no way to reach it.
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
        } catch let error as DocsAPIError where error == .notFound {
            // **Already gone reads as deleted, not as a failure.** The same reasoning the
            // checkpointed branch has always had, which this branch was simply missing: a 404
            // is what a co-author's delete looks like, and reporting "Couldn't delete
            // document" about a document that is already gone asks the user to retry
            // something that has no work left in it.
            didDelete = true
        } catch {
            if let coordinator = saveCoordinator,
                queueDeletion(of: documentID, coordinator: coordinator, failure: error)
            {
                return
            }
            errorKey = .options_error_delete
        }
    }

    /// Queue the deletion for the replay if this failure is worth retrying and we can say
    /// whose deletion it is. Returns whether it was queued, so the caller falls through to
    /// its own error when it was not.
    ///
    /// Never gated on `isOffline`: that flag is derived from Home's last *list* fetch, so it
    /// is wrong in both directions here. What decides is the failure the server actually gave
    /// us, exactly as the create fallbacks decide.
    ///
    /// A deletion nobody can be attributed to would be neither sent nor shown — it would
    /// vanish, leaving a row that looks alive — so an unknown account reports the error
    /// instead, the same rule `createLocalDocument`'s required `ownerUserID` enforces at the
    /// mint site.
    private func queueDeletion(of serverID: UUID, coordinator: DocumentSaveCoordinator, failure: Error) -> Bool {
        guard let apiError = failure as? DocsAPIError, retryableSaveFailure(apiError),
            let ownerUserID = signedInUser.userID
        else { return false }
        coordinator.recordPendingDelete(documentID: serverID, ownerUserID: ownerUserID)
        didQueueDelete = true
        didDelete = true
        return true
    }
}
