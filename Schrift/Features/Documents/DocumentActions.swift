import Foundation

/// What a delete attempt settled on — the three-way ladder collapsed into the three answers
/// any caller can act on.
enum DocumentDeleteOutcome: Equatable {
    /// Gone. The server confirmed it, it was already gone (a co-author got there first), or it
    /// never existed there at all.
    case deleted
    /// Queued as a tombstone and still cancellable. `serverID` is the id the tombstone names,
    /// which for a checkpointed record is **not** the id the caller passed in.
    case queued(serverID: UUID)
    /// Rejected on the merits, or unattributable to an account. Nothing changed anywhere.
    case failed
}

enum DocumentFavoriteOutcome: Equatable {
    case changed(isFavorite: Bool)
    case failed
}

enum DocumentMoveOutcome: Equatable {
    case moved
    case failed
}

/// Where a document is being moved to.
///
/// The two cases are not symmetric, because the backend's move endpoint has no "no parent"
/// target: promoting a document to the top level is expressed as filing it *beside* an
/// existing root, so `.root` has to name one. A local document needs no such target — it is
/// re-parented on this device, where nil is simply nil — which is why the id is Optional
/// rather than a second case nobody could construct correctly.
enum DocumentMoveDestination: Equatable {
    case root(siblingRootID: UUID?)
    case under(parentID: UUID)
}

/// The one place a document is deleted or favorited.
///
/// A value type, not a view model: it owns no UI state and publishes nothing, so a caller
/// keeps its own `errorKey` / `isDeleting` / row bookkeeping and this keeps only the ladder.
/// Every caller builds one from dependencies it already holds, which is why adding it needed
/// no new injection seam — `MockURLProtocol` and a suite-scoped `DocumentSaveCoordinator`
/// already control everything it touches.
///
/// It exists because the delete ladder is safety-critical and had already drifted **inside a
/// single function**: the plain-server branch was missing the `.notFound`-reads-as-deleted
/// rule the checkpointed branch had always carried. Three copies across three features would
/// drift again, and each copy would need the ~70 lines of reasoning below kept true.
@MainActor
struct DocumentActions {
    private let client: DocsAPIClient

    /// Optional for the same reason `OptionsViewModel`'s was: nil means "no local documents
    /// here", which is true of every screen that does not own one, and keeps every `#Preview`
    /// working.
    private let saveCoordinator: DocumentSaveCoordinator?

    /// Who is signed in, for a tombstone's `ownerUserID`. A queued deletion nobody can be
    /// attributed to is neither sent nor shown, so a deletion that could not name the user
    /// reports the ordinary error instead of silently going nowhere.
    private let signedInUser: SignedInUserStore

    init(
        client: DocsAPIClient,
        saveCoordinator: DocumentSaveCoordinator? = nil,
        signedInUser: SignedInUserStore = SignedInUserStore()
    ) {
        self.client = client
        self.saveCoordinator = saveCoordinator
        self.signedInUser = signedInUser
    }

    /// This document exists only on this device — every server-addressed affordance must be
    /// withheld. In particular **Pin**: there is no `documents/{local-uuid}/favorite/` route,
    /// and `retryableSaveFailure` correctly refuses to retry the 404, so there is no fallback.
    func isLocalDocument(_ documentID: UUID) -> Bool {
        saveCoordinator?.isPendingCreate(documentID: documentID) ?? false
    }

    /// Whether deleting this document also throws away sub-pages that exist nowhere else, so
    /// a confirmation can say so. Not gated on `isLocalDocument`: a *checkpointed* record is
    /// met under its server id, and its sub-pages still go with it.
    func hasLocalSubpages(_ documentID: UUID) -> Bool {
        saveCoordinator?.hasPendingLocalChildren(documentID: documentID) ?? false
    }

    func delete(documentID: UUID) async -> DocumentDeleteOutcome {
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
            // Read **before** anything clears the record: the purge below drops it, after which
            // this answers nil and the server id's own caches and rows would be left behind.
            let checkpointedServerID = coordinator.syncedServerID(forLocalID: documentID)
            if let serverID = checkpointedServerID {
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
                    if let queued = queueDeletion(of: serverID, coordinator: coordinator, failure: error) {
                        return queued
                    }
                    // Rejected on the merits, or nothing to attribute the deletion to: leave
                    // everything. The record may still name a live document, and discarding
                    // the local trace would strand it permanently with no way to reach it.
                    return .failed
                }
            }
            // Drops the record *and* its draft, so no replay can resurrect what the user threw
            // away — and purges the caches and **announces**, which is what
            // `discardPendingWork` alone does not do.
            //
            // The announcement is not optional here. `EditorView`'s `onDeleted` no longer
            // tears its own session down for a made deletion, on the premise that every made
            // deletion announces; without this, deleting a locally-created document from its
            // own editor would leave `isDocumentDiscarded` false and the autosave running, and
            // a dirty screen's flush on disappear would then write a *fresh* draft under the
            // id whose record was just dropped — resurrecting it until a later pass reaps the
            // 404. The premise has to hold on every branch, or it holds on none.
            coordinator.completeImmediateDelete(documentID: documentID)
            // A **checkpointed** record is also known under its server id: that is the id the
            // lists show once the POST has landed, the id any other open editor was reached
            // by, and the id whose cached body and children levels were written. It owes the
            // same purge and the same announcement.
            if let serverID = checkpointedServerID {
                coordinator.completeImmediateDelete(documentID: serverID)
            }
            return .deleted
        }
        do {
            try await client.deleteDocument(documentID: documentID)
        } catch let error as DocsAPIError where error == .notFound {
            // **Already gone reads as deleted, not as a failure.** The same reasoning the
            // checkpointed branch has always had, which this branch was once missing: a 404
            // is what a co-author's delete looks like, and reporting "Couldn't delete
            // document" about a document that is already gone asks the user to retry
            // something that has no work left in it.
        } catch {
            if let coordinator = saveCoordinator,
                let queued = queueDeletion(of: documentID, coordinator: coordinator, failure: error)
            {
                return queued
            }
            return .failed
        }
        // **Everything a landed deletion owes the device.**
        //
        // The editor used to be the only thing that did this — `EditorView`'s `onDeleted`
        // called `handleDidDelete()`, which purged that one screen's caches — so a delete made
        // from a *list* row, which has no editor, would purge nothing and announce nothing.
        // Two concrete failures follow from skipping it, and the second is the worse:
        //
        //  - a live editor, or a list on another tab, keeps a row for a document the server no
        //    longer has;
        //  - a **checkpointed** record's document is met here under its *server* id, so the
        //    branch above never runs and nothing clears its create record or draft. The next
        //    resume GETs `serverID`, takes a 404, clears the checkpoint, and the pass after
        //    that re-POSTs the document the user just deleted.
        //
        // `purgeLocalTraces` — which `completeImmediateDelete` wraps — reaches
        // `discardPendingWork`'s `checkpointedRecord(forServerID:)` branch, which is what
        // closes that second one.
        saveCoordinator?.completeImmediateDelete(documentID: documentID)
        return .deleted
    }

    /// Queue the deletion for the replay if this failure is worth retrying and we can say
    /// whose deletion it is. Returns the outcome when it was queued, so the caller falls
    /// through to its own error when it was not.
    ///
    /// Never gated on `isOffline`: that flag is derived from Home's last *list* fetch, so it
    /// is wrong in both directions here. What decides is the failure the server actually gave
    /// us, exactly as the create fallbacks decide.
    ///
    /// A deletion nobody can be attributed to would be neither sent nor shown — it would
    /// vanish, leaving a row that looks alive — so an unknown account reports the error
    /// instead, the same rule `createLocalDocument`'s required `ownerUserID` enforces at the
    /// mint site.
    private func queueDeletion(
        of serverID: UUID, coordinator: DocumentSaveCoordinator, failure: Error
    ) -> DocumentDeleteOutcome? {
        guard let apiError = failure as? DocsAPIError, retryableSaveFailure(apiError),
            let ownerUserID = signedInUser.userID
        else { return nil }
        coordinator.recordPendingDelete(documentID: serverID, ownerUserID: ownerUserID)
        return .queued(serverID: serverID)
    }

    /// Pin or unpin.
    ///
    /// **Awaited before anything local changes, never optimistic.** There is no offline queue
    /// for favorites — `setFavorite` is the one mutation with no replay — so an optimistic
    /// flip would have to be rolled back on every failure, and the honest thing is to report
    /// it instead.
    func setFavorite(documentID: UUID, isFavorite: Bool) async -> DocumentFavoriteOutcome {
        do {
            try await client.setFavorite(documentID: documentID, isFavorite: isFavorite)
            return .changed(isFavorite: isFavorite)
        } catch {
            return .failed
        }
    }

    /// Move a document — with its whole subtree, which the server relocates in one atomic
    /// transaction — under another document or up to the top level.
    ///
    /// The same three-state ladder `delete` walks, and the middle state matters here for the
    /// same reason: a record that has been **checkpointed** is still `isPendingCreate`, but a
    /// real server document exists under `syncedServerID` and that is the one the user is
    /// looking at. Moving the local record instead would rewrite a `parentID` the migration
    /// has already stopped reading, and nothing would move.
    ///
    /// **Awaited, never optimistic, and never queued** — the `setFavorite` posture. There is
    /// no replay for a move: a transport failure changes nothing anywhere and the caller
    /// reports it, which is honest, where an optimistic re-parent would have to be rolled back
    /// on every failure and a queue would need a whole tombstone-shaped machinery to hold a
    /// placement the server may reject on the merits.
    ///
    /// A `.notFound` is a plain failure here, deliberately unlike `delete`'s: "already
    /// deleted" is a coherent reading of a 404 for a deletion, but there is no state of the
    /// world in which a move that was never made is already done.
    /// `row` is the document as some list is drawing it, when the caller has one. It is what a
    /// surface *inserts* where the document has landed, so a caller without one — the editor's
    /// Options sheet, which holds an id and a title rather than a row — passes nil and the
    /// destination simply picks the document up on its next fetch. Fabricating a row there
    /// would be worse than nil: it would be cached, and its `depth`/`path` would be invented.
    func move(
        documentID: UUID, row: Document?, to destination: DocumentMoveDestination
    ) async -> DocumentMoveOutcome {
        // A document already queued for deletion is not somewhere to file work: the tombstone
        // outlives the move, so the only thing a successful one buys is a document that is
        // deleted from a different place. The row surfaces withhold Move for a struck-through
        // row anyway (they offer only "Keep this document"); this is the rule stated once, for
        // every surface, rather than per-caller — the same reason `moveLocalDocument` refuses a
        // tombstoned *destination*.
        if saveCoordinator?.isPendingDelete(documentID: documentID) == true { return .failed }
        if let coordinator = saveCoordinator, coordinator.isPendingCreate(documentID: documentID),
            coordinator.syncedServerID(forLocalID: documentID) == nil
        {
            let newParentID: UUID? =
                switch destination {
                case .root: nil
                case .under(let parentID): parentID
                }
            return coordinator.moveLocalDocument(documentID: documentID, newParentID: newParentID)
                ? .moved : .failed
        }
        // The id the server knows this document by: its own, or — for a checkpointed record
        // met under its local id — the one the POST returned.
        let serverID = saveCoordinator?.syncedServerID(forLocalID: documentID) ?? documentID
        let targetID: UUID
        let position: DocumentMovePosition
        switch destination {
        case .under(let parentID):
            // A client-minted id names nothing on the server, so this would 404. The picker
            // does not offer local destinations for a server document; this refuses the state
            // rather than sending a request that cannot succeed.
            guard saveCoordinator?.isPendingCreate(documentID: parentID) != true else { return .failed }
            // …and a destination on its way out is no place to file work — the local twin
            // refuses one, as does `PagesTreeViewModel.addPage`, and on the **unscoped**
            // predicate deliberately: the scoped one answers false for an unattributable or
            // foreign-account tombstone, which is protection this must not skip.
            guard saveCoordinator?.isPendingDelete(documentID: parentID) != true else { return .failed }
            targetID = parentID
            position = .lastChild
        case .root(let siblingRootID):
            // Promotion needs a root to sit beside. Its absence is not something to guess at —
            // the picker withholds the affordance when it has no root to name.
            guard let siblingRootID else { return .failed }
            targetID = siblingRootID
            position = .lastSibling
        }
        do {
            try await client.moveDocument(
                documentID: serverID, targetDocumentID: targetID, position: position)
        } catch {
            return .failed
        }
        let newParentID: UUID? = if case .under(let parentID) = destination { parentID } else { nil }
        // Everything the landed move owes the device — the caches, then the announcement that
        // is the single writer for every on-screen list. As with `delete`, the calling surface
        // removes nothing itself.
        //
        // Keyed on `serverID`, which for a checkpointed record met under its *local* id is not
        // the id the caller passed: every cache entry and every list row for such a document is
        // written under the id the POST returned, so completing under the local one would sweep
        // nothing and announce a row no screen holds.
        //
        // **The row is passed on only when it is already usable as-is.** Two things disqualify
        // it, and between them nothing is left to re-key:
        //
        //  - it is **synthetic**. Every surface that offers Move merges `localDocument(from:)`
        //    rows in at read time, and those must never enter a persisted cache. Re-keying one
        //    onto the server id is the specific thing that would make a leak undetectable — a
        //    client-minted id 404s on every fetch, a re-keyed one is indistinguishable from a
        //    real row;
        //  - it names an id the caches are not keyed by. That can only happen for a
        //    checkpointed record met under its local id, which the first test already drops.
        //
        // Passing nil costs only that the destination picks the document up on its next fetch.
        let cacheableRow = row.flatMap { $0.id == serverID && !isLocalDocument($0.id) ? $0 : nil }
        saveCoordinator?.completeDocumentMove(
            documentID: serverID, row: cacheableRow, newParentID: newParentID)
        return .moved
    }
}
