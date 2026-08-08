import Foundation

@MainActor
@Observable
final class HomeViewModel {
    var searchQuery: String = ""
    var pinnedDocuments: [Document] = []
    /// What the server (or its cache) last said. **Never contains a locally-created
    /// document** — see `recentDocuments`.
    var fetchedRecentDocuments: [Document] = []
    /// The list the screen renders: the fetched one with this device's unsynced documents
    /// merged in at read time, minus whatever the Pinned section is already showing.
    ///
    /// **Each document belongs to exactly one section.** The feed is fetched unfiltered, so the
    /// server returns pinned documents in both responses; `recentsExcludingPinned` is what keeps
    /// the same row from rendering twice, and its doc comment carries the reasoning. It runs
    /// *after* the merge below, which is free rather than load-bearing: a locally-created
    /// document is never a favorite, so the filter has nothing of its own to drop.
    ///
    /// Merging at *read* time rather than storing them together is the invariant that keeps
    /// a synthetic `Document` out of `DocumentCacheStore`. A list load replaces its array
    /// **and** its cache entry wholesale, so a synthetic row written into the cache would
    /// afterwards be indistinguishable from a real server document — with a client-minted id
    /// that every fetch 404s on. Reading `pendingCreatesVersion` here is what makes the row
    /// disappear on its own once the replay migrates it, without a list fetch.
    var recentDocuments: [Document] {
        // Memoised, because this is read several times per `DocumentListView` body — the list
        // itself, `isCurrentListKnown`, the empty-state branch — and the body re-runs on every
        // search-field keystroke. Uncached, each read costs a **full decode of every draft on
        // the device, document bodies included**, on the main actor: `pendingLocalDocuments`
        // goes through `PendingDraftStore.allDrafts()`, whose `loadAll` is all-or-nothing.
        //
        // The key is the pair that can change the answer — the fetched array and the
        // coordinator's record version. Reading `pendingCreatesVersion` here is also what
        // registers the `@Observable` dependency, so a migrated row leaves a live Home the
        // moment `removePendingCreate` runs rather than at the next successful fetch.
        // **The account is part of the key.** Re-authenticating as someone else changes who
        // may be listed without touching either of the other two, so a memo keyed only on
        // them would keep serving the previous user's documents to the new one.
        // **Reading `pinnedDocuments` here is load-bearing; keying on it is defensive.** The
        // read is what registers the `@Observable` dependency and, since it sits above the
        // early return, it happens on every call — so a body that renders only this list is
        // still invalidated by a pin. The *key* is the belt-and-braces half: no current path
        // needs it, because every writer of `pinnedDocuments` (`applyFavoriteChange`, `load()`,
        // the deletion observer) reassigns `fetchedRecentDocuments` in the same breath, and the
        // paths where that assignment is value-identical are exactly the ones where the
        // document is absent from the feed and the filtered answer cannot differ. Verified by
        // mutation — dropping this conjunct fails no test in the suite. It stays because a memo
        // whose key omits an input its body reads is wrong the moment a writer stops moving in
        // lockstep, and that is a silent wrong answer rather than a crash. Ids alone:
        // `applyingFavoriteFlag` rewrites a pinned row's *contents* on every toggle, and the
        // filtered answer depends on nothing but identity.
        let version = saveCoordinator.pendingCreatesVersion
        let owner = signedInUser.userID
        let pinnedIDs = pinnedDocuments.map(\.id)
        if let cached = mergedRecents, cached.version == version, cached.owner == owner,
            cached.pinnedIDs == pinnedIDs, cached.fetched == fetchedRecentDocuments
        {
            return cached.merged
        }
        let merged = recentsExcludingPinned(
            recent: mergedWithLocalDocuments(
                fetched: fetchedRecentDocuments,
                local: saveCoordinator.pendingLocalDocuments(parentID: nil, currentUserID: owner)),
            pinned: pinnedDocuments)
        mergedRecents = (version, owner, pinnedIDs, fetchedRecentDocuments, merged)
        return merged
    }

    /// Memo for `recentDocuments`. `@ObservationIgnored` so writing it from a *getter* does
    /// not register a mutation and re-invalidate the very view that just read it.
    @ObservationIgnored
    private var mergedRecents: (version: Int, owner: UUID?, pinnedIDs: [UUID], fetched: [Document], merged: [Document])?
    var searchResults: [Document] = []
    var isLoading = false
    var errorKey: L10nKey?
    /// The server's own words about the failure behind `errorKey`, when it had any —
    /// `DocsAPIError` collapses a CSRF 403, a validation 400, and a decoding bug into the
    /// same sentence, and a self-hoster needs to tell them apart without a debugger.
    var errorDetail: String?
    var isOffline = false
    /// Whether the recent list is known — cached or fetched this session. The
    /// view may render the "No documents yet" empty state only for a known
    /// list: nil (never fetched) must not masquerade as a real empty result,
    /// e.g. a fresh install under Work Offline (mirrors Shared's
    /// showsDocumentList).
    private(set) var hasKnownFetchedList = false
    /// …or this device holds an unsynced document, which is itself a real answer: a fresh
    /// install in airplane mode that has created one must render that row, not the
    /// never-fetched placeholder.
    var isCurrentListKnown: Bool {
        hasKnownFetchedList || !recentDocuments.isEmpty
    }

    let client: DocsAPIClient
    let saveCoordinator: DocumentSaveCoordinator
    private let cache: DocumentCacheStore
    /// Whose local documents may be listed. Nil (never signed in on this device, or signed
    /// out) withholds every record — `belongsToSession` gates listing and sending on the same
    /// test, because showing user B another user's unsynced document is the worse half of the
    /// same disclosure: B's edits would land in A's document when A signs back in.
    private let signedInUser: SignedInUserStore
    private let userDefaults: UserDefaults
    /// The same log the shared client records into. nil in previews and in tests that don't
    /// care, which simply means no detail is offered. Not private: the editor screens this
    /// view model pushes are handed the same log, or their detail never arrives.
    let diagnostics: APIDiagnosticsLog?
    /// Monotonic guard: a completing fetch applies its outcome only if no
    /// newer load() superseded it (latest-wins; .task refires on pop-back and
    /// races .refreshable).
    private var loadGeneration = 0
    /// Documents whose deletion landed while a fetch was in flight. That fetch was issued
    /// before the DELETE and still names them, so its results are filtered through this before
    /// being applied or cached — invariant 0b, without cancelling the fetch (which would throw
    /// away every *other* row it carries, and on Home would discard a load fired from inside
    /// the sync pass that announced the deletion).
    ///
    /// **Never cleared.** A screen can have more than one fetch in flight, so clearing when one
    /// lands strips the others' protection mid-flight. A stale entry is inert rather than
    /// merely harmless: server ids are never reused — the revive mints a *new* local id — so an
    /// id that named a deleted document can never name a live one. It grows by one `UUID` per
    /// landed deletion per process.
    private var deletedSinceLoad: Set<UUID> = []

    /// Pins and unpins made on this device that a list fetch in flight does not yet know
    /// about. Unlike `deletedSinceLoad` these are **retired** as soon as a fetch agrees with
    /// them — see `applyFavoriteOverrides` for why keeping them would veto the next change
    /// made from the web.
    private var favoriteOverrides: [UUID: Bool] = [:]

    /// Documents with a delete or pin in flight from a swipe, so a second swipe on the same
    /// row cannot double-send. Not a spinner: the row keeps drawing normally.
    private(set) var mutatingDocumentIDs: Set<UUID> = []

    /// The shared delete/pin ladder, the same one the Options sheet goes through.
    private let actions: DocumentActions

    init(
        client: DocsAPIClient,
        cache: DocumentCacheStore = DocumentCacheStore(),
        saveCoordinator: DocumentSaveCoordinator? = nil,
        serverOrigin: String = "",
        userDefaults: UserDefaults = .standard,
        signedInUser: SignedInUserStore = SignedInUserStore(),
        diagnostics: APIDiagnosticsLog? = nil
    ) {
        self.signedInUser = signedInUser
        self.client = client
        self.cache = cache
        // `serverOrigin` reaches the coordinator only to stamp documents created on this
        // device, so a record minted against one server is never replayed into another
        // (drafts and metadata caches deliberately survive sign-out). Ignored when a
        // coordinator is injected — that caller owns its own origin.
        self.saveCoordinator =
            saveCoordinator ?? DocumentSaveCoordinator(client: client, serverOrigin: serverOrigin)
        self.userDefaults = userDefaults
        self.diagnostics = diagnostics
        // Before the two subscriptions below, which capture `self`. Takes the *resolved*
        // coordinator, not the optional parameter.
        self.actions = DocumentActions(
            client: client, saveCoordinator: self.saveCoordinator, signedInUser: signedInUser)
        // A migration re-keys a document onto its server id, after which the local row is
        // correctly withheld and the real one exists only in a server response this view model
        // has not made yet. Refetch on the event itself — see `onDocumentMigrated`.
        self.saveCoordinator.onDocumentMigrated = { [weak self] migrated in
            // nil when the resume could not fetch the document — the refetch below is then
            // the whole remedy.
            guard let self else { return }
            // Swap the real document in *first*, so the row never blinks out. A refetch alone
            // is not enough: a fresh install used offline first has no recents cache, so
            // `insertIntoListCaches` correctly declines to fabricate one and a refetch that
            // then fails would leave the document in no list at all. In-memory only — the
            // cache stays the server's to fill.
            // **Not roots-only, unlike `insertIntoListCaches`.** That rule exists because
            // Home's feed is fetched without a parent filter, so a sub-page's place in it is
            // the server's answer to give — and `Document` carries no `parentID`, so this
            // subscriber cannot tell. The divergence is bounded: this is in-memory only and
            // the `load()` on the next line replaces it with the server's own list, so a
            // wrongly-placed sub-page row survives only until the first successful fetch.
            if let migrated, !self.fetchedRecentDocuments.contains(where: { $0.id == migrated.id }) {
                self.fetchedRecentDocuments.insert(migrated, at: 0)
                self.hasKnownFetchedList = true
            }
            Task { await self.load() }
        }
        // A queued deletion that has now landed: drop the row from the lists this view model
        // is holding. `completePendingDelete` purged the caches, but these arrays are its own
        // — and leaving the row would do worse than linger, since the tombstone is gone and
        // the row would *un-strike* back into looking like a live document.
        self.saveCoordinator.observeDocumentDeleted(self) { [weak self] documentID in
            guard let self else { return }
            self.pinnedDocuments.removeAll { $0.id == documentID }
            self.fetchedRecentDocuments.removeAll { $0.id == documentID }
            // The inline search field on this very screen is a third list of server documents.
            self.searchResults.removeAll { $0.id == documentID }
            // **A list fetch already in flight was issued before the DELETE landed**, so it
            // still names the document and would write it back — into the cache as well
            // (invariant 0b). Bumping `loadGeneration` here is the obvious move and the wrong
            // one: `load()` captures a generation, kicks `recoverDrafts()`, *then* awaits the
            // list calls, so a deletion landing in that window is fired from inside the load
            // it would be cancelling. That discards the whole fetch rather than one row —
            // list stale, `isOffline` unset, and `isLoading` stuck true, because the guarded
            // early return skips the line that clears it. Filter instead.
            self.deletedSinceLoad.insert(documentID)
        }
        pinnedDocuments = cache.loadPinnedDocuments()
        if let recents = cache.loadRecentDocuments() {
            fetchedRecentDocuments = recents
            hasKnownFetchedList = true
        }
    }

    var showsPinnedSection: Bool {
        !pinnedDocuments.isEmpty
    }

    func load(userInitiated: Bool = false) async {
        clearError()
        loadGeneration += 1
        let generation = loadGeneration

        // "Work offline" preference (Profile > Preferences): serve cached
        // documents and never hit the network.
        if userDefaults.bool(forKey: "schrift.workOffline") {
            pinnedDocuments = cache.loadPinnedDocuments()
            let cachedRecents = cache.loadRecentDocuments()
            // Don't clobber a just-migrated in-memory row with a nil cache. `runCreatePass`
            // reads no `workOffline` gate, so a replay *does* run in this mode — and on a
            // fresh install `insertIntoListCaches` correctly declines to write a cache that
            // was never fetched, so this assignment would drop the document that just synced
            // out of every list, with no way back while the toggle is on.
            if let cachedRecents { fetchedRecentDocuments = cachedRecents }
            hasKnownFetchedList = cachedRecents != nil
            isOffline = true
            isLoading = false
            return
        }

        // One read decides both halves of the silent-vs-loud policy: spinner
        // and error may only appear when the list has no local copy. Pinned
        // rows are visible whenever the pinned section renders, so they count
        // toward "rows on screen" and rightly suppress the first-run spinner.
        let hasCachedList = cache.loadRecentDocuments() != nil
        hasKnownFetchedList = hasCachedList
        let visiblePinnedCount = showsPinnedSection ? pinnedDocuments.count : 0
        isLoading = shouldShowLoadingPlaceholder(
            hasCachedList: hasCachedList,
            visibleRowCount: visiblePinnedCount + recentDocuments.count
        )

        // Replay any drafts stranded by a previous session (runs once).
        let coordinator = saveCoordinator
        Task { await coordinator.recoverDrafts() }

        let marker = diagnostics?.marker()
        do {
            async let pinnedPage = client.favoriteDocuments()
            async let recentPage = client.listDocuments(
                isFavorite: nil,
                isCreatorMe: nil,
                ordering: "-updated_at"
            )
            let fetchedPinned = try await pinnedPage.results
            let fetchedRecent = try await recentPage.results
            guard generation == loadGeneration else { return }
            // Anything deleted while this was in flight is dropped before it can be applied or
            // cached — the fetch predates the DELETE and cannot know.
            let pinned = fetchedPinned.filter { !deletedSinceLoad.contains($0.id) }
            let recent = fetchedRecent.filter { !deletedSinceLoad.contains($0.id) }
            // …and a pin made here while this was in flight is folded back in, for the same
            // reason and by the same rule: filter, never cancel. Retiring the confirmed
            // overrides happens inside this guard, so only the winning fetch may retire one.
            let overlaid = applyFavoriteOverrides(pinned: pinned, recent: recent, overrides: favoriteOverrides)
            for documentID in overlaid.confirmed { favoriteOverrides[documentID] = nil }
            pinnedDocuments = overlaid.pinned
            fetchedRecentDocuments = overlaid.recent
            cache.savePinnedDocuments(overlaid.pinned)
            cache.saveRecentDocuments(overlaid.recent)
            hasKnownFetchedList = true
            isOffline = false
        } catch {
            guard generation == loadGeneration else { return }
            // **Re-seed from the cache.** A migration writes the real document into it
            // (`insertIntoListCaches`) and then drops the record, so if the refetch that
            // follows fails — a flaky reconnect being exactly the profile here — the row is in
            // neither list and pull-to-refresh fails too, leaving it invisible until relaunch.
            // The cache already holds the answer; the only reason it was not being read is
            // that the online path re-seeds nowhere but `init`.
            if let cachedRecents = cache.loadRecentDocuments() {
                fetchedRecentDocuments = cachedRecents
                hasKnownFetchedList = true
            }
            // A real 401 is not "offline": the client's onSessionExpired hook
            // has already raised the app-level re-login sheet, so keep serving
            // cached rows silently. Everything else keeps the offline
            // treatment. Assigned unconditionally (like SharedViewModel's
            // recompute) so a 401 also *clears* a stale true from an earlier
            // network failure — device back online, session since expired.
            let failed = (error as? DocsAPIError) != .sessionExpired
            isOffline = failed
            // Silent when the list has a cached copy to fall back on (offline
            // reading); loud on a true first run — pinned rows are no evidence
            // for it — or an explicit pull-to-refresh.
            if failed, userInitiated || !hasCachedList {
                errorKey = .home_error_load
                errorDetail = requestFailureDetail(after: marker, in: diagnostics)
            }
        }

        if generation == loadGeneration {
            isLoading = false
        }
    }

    /// Explicit pull-to-refresh: unlike the passive on-appear revalidation it
    /// surfaces failures instead of swallowing them behind cached rows.
    func refresh() async {
        await load(userInitiated: true)
    }

    /// Auto-sync trigger for reconnect / foreground. Keeps the coordinator access
    /// inside the view model (like `load()`'s `recoverDrafts()`), so the view never
    /// drives networking/persistence directly.
    func syncPendingDrafts() async {
        await saveCoordinator.syncPendingDrafts()
        // **A migrated document must not vanish from a live Home.** The replay drops the
        // record, so the local row is correctly withheld the instant it migrates — but the
        // *real* row only exists in `fetchedRecentDocuments`, which still holds the fetch from
        // before the document was created. Nothing else reloads: the reconnect and foreground
        // edges call this and not `load()`, `insertIntoListCaches` writes only the cache, and
        // the list's own `.task` does not re-run on pop-back. So the user watches their
        // document disappear from the screen, until a pull-to-refresh brings it back.
        //
        // The refetch itself hangs off `onDocumentMigrated`, not off this call: two of the
        // four things that start a create pass never come through here (`recoverDrafts` at
        // launch, and `releaseOpenEditor` when an editor closes — the designed completion
        // path, and the only one on iPad), and an overlapping trigger is coalesced into a
        // no-op that returns before the migration happens.
    }

    func search() async {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        let marker = diagnostics?.marker()
        do {
            let page = try await client.searchDocuments(query: trimmed)
            var results = page.results.filter { !deletedSinceLoad.contains($0.id) }
            // The inline results are the same documents the two lists above show, so a pin
            // made here has to reach them too or the same row reads as pinned in one section
            // and not in another on the same screen. Flags only — search results have no
            // membership to correct.
            for (documentID, isFavorite) in favoriteOverrides {
                results = applyingFavoriteFlag(results, documentID: documentID, isFavorite: isFavorite)
            }
            searchResults = results
        } catch {
            errorKey = .home_error_search
            errorDetail = requestFailureDetail(after: marker, in: diagnostics)
        }
    }

    /// Learn (or re-learn) which account this session belongs to, and persist it.
    ///
    /// Offline creation needs the id when there is no network to ask for it, so it is stored
    /// rather than fetched on demand. **Re-run it after re-authentication**, not only at
    /// launch: the sheet can be answered by a *different* account, and a stale id would list
    /// the previous user's unsynced documents to the new one — who could then type into them,
    /// with the edits eventually POSTed into the first user's account when they sign back in.
    /// That is exactly the disclosure `belongsToSession` exists to prevent, reached through
    /// the one writer that was not being refreshed.
    ///
    /// Best-effort: a failure leaves whatever the last successful fetch stored, which is the
    /// conservative direction — the *send* half re-checks against a live `/users/me/` anyway.
    func refreshSignedInUser() async {
        guard let user = try? await client.currentUser() else { return }
        signedInUser.remember(user.id)
    }

    /// Whether this document's deletion is queued and unsent, so its row draws struck through
    /// and its tap offers the undo instead of opening it.
    ///
    /// Scoped to the signed-in account (`isListablePendingDelete`, never the unscoped
    /// protective predicate): tombstones survive sign-out and these caches are neither
    /// account-scoped nor cleared, so an unscoped answer would strike one user's document
    /// through another's list and offer them a button that cancels a deletion they never made.
    ///
    /// The coordinator reads `pendingDeletesVersion` first, so a SwiftUI body calling this
    /// registers the dependency and re-renders the moment a deletion is queued or undone.
    func isDeletePending(_ document: Document) -> Bool {
        saveCoordinator.isListablePendingDelete(
            documentID: document.id, currentUserID: signedInUser.userID)
    }

    /// Cancel a queued deletion. Kicks the sync funnel as well: a draft this document had was
    /// suppressed while the tombstone stood, and undoing is exactly when it becomes replayable
    /// again — waiting for an unrelated foreground or reconnect would leave it stalled.
    func undoPendingDelete(_ document: Document) {
        saveCoordinator.cancelPendingDelete(documentID: document.id)
        Task { await saveCoordinator.syncPendingDrafts() }
    }

    /// Whether this row is a document created here that the server has not seen yet.
    func isLocalDocument(_ document: Document) -> Bool {
        saveCoordinator.isPendingCreate(documentID: document.id)
    }

    /// Whether deleting this row also throws away sub-pages that exist nowhere else, so the
    /// confirmation can say so.
    func hasLocalSubpages(_ document: Document) -> Bool {
        actions.hasLocalSubpages(document.id)
    }

    /// Delete a document from its list row.
    ///
    /// **Nothing here removes the row**, deliberately. A landed deletion is announced by the
    /// coordinator and this view model's own `observeDocumentDeleted` handler — registered in
    /// `init` — is the single writer that drops it from `pinnedDocuments`,
    /// `fetchedRecentDocuments` and `searchResults` and records it in `deletedSinceLoad`. Two
    /// writers for the same fact is how the two get to disagree.
    ///
    /// A *queued* deletion needs nothing either: `recordPendingDelete` bumps
    /// `pendingDeletesVersion`, which the row's `isDeletePending` read in the view body
    /// depends on, so it strikes through on its own.
    ///
    /// A **locally-created** document is announced by nothing — there is no server id to
    /// announce — but `discardPendingWork` bumps `pendingCreatesVersion`, which invalidates
    /// `recentDocuments`' memo, so its synthetic row leaves the same way it arrived.
    func deleteDocument(_ document: Document) async {
        guard !mutatingDocumentIDs.contains(document.id) else { return }
        clearError()
        mutatingDocumentIDs.insert(document.id)
        defer { mutatingDocumentIDs.remove(document.id) }
        let marker = diagnostics?.marker()
        switch await actions.delete(documentID: document.id) {
        case .deleted, .queued:
            break
        case .failed:
            errorKey = .options_error_delete
            errorDetail = requestFailureDetail(after: marker, in: diagnostics)
        }
    }

    /// Pin or unpin from a list row.
    ///
    /// Withheld for a document the server has never seen: there is no
    /// `documents/{local-uuid}/favorite/` route, so the request would 404 and
    /// `retryableSaveFailure` rightly refuses to retry it. The view withholds the action too;
    /// this is the backstop, and it mirrors `OptionsSheetView`'s own `!isLocalDocument` gate.
    func toggleFavorite(_ document: Document) async {
        guard !mutatingDocumentIDs.contains(document.id), !isLocalDocument(document) else { return }
        clearError()
        mutatingDocumentIDs.insert(document.id)
        defer { mutatingDocumentIDs.remove(document.id) }
        let marker = diagnostics?.marker()
        let desired = !document.isFavorite
        switch await actions.setFavorite(documentID: document.id, isFavorite: desired) {
        case .changed(let isFavorite):
            applyFavoriteChange(document, isFavorite: isFavorite)
        case .failed:
            errorKey = .options_error_toggle_favorite
            errorDetail = requestFailureDetail(after: marker, in: diagnostics)
        }
    }

    /// Reflect a landed pin/unpin across every list this screen holds, without a reload.
    ///
    /// Three lists show the same server documents — the Pinned section, the recents feed and
    /// the inline search results — and all three render `DocRow(pinned: document.isFavorite)`,
    /// so a mutation reaching only one of them shows the user a document that is pinned in one
    /// place and not in another on the same screen.
    ///
    /// A reload instead of this would cost two round trips for a bit the client already knows,
    /// re-run `recoverDrafts()`, re-derive `isOffline` and possibly flash a skeleton — and it
    /// would not even remove the race, since a slower pre-pin fetch already in flight still
    /// wins. The override below is needed either way, at which point the reload buys nothing.
    private func applyFavoriteChange(_ document: Document, isFavorite: Bool) {
        fetchedRecentDocuments = applyingFavoriteFlag(
            fetchedRecentDocuments, documentID: document.id, isFavorite: isFavorite)
        searchResults = applyingFavoriteFlag(
            searchResults, documentID: document.id, isFavorite: isFavorite)

        if isFavorite {
            if !pinnedDocuments.contains(where: { $0.id == document.id }) {
                var copy = document
                copy.isFavorite = true
                pinnedDocuments.insert(copy, at: 0)
            }
        } else {
            pinnedDocuments.removeAll { $0.id == document.id }
        }
        // The recents *order* is deliberately untouched: that list is `-updated_at`, and
        // whether the server bumps `updated_at` on a favorite is its answer to give.

        favoriteOverrides[document.id] = isFavorite
        cache.setFavorite(document.id, isFavorite: isFavorite, document: document)
    }

    /// Mint a document that exists only on this device. Nil when nobody is known to own it —
    /// `createLocalDocument` takes a non-optional owner, and a record nothing can attribute is
    /// kept and protected but listed to nobody and replayed never, so minting one would create
    /// a document the user can never see again. Failing closed with the ordinary error is the
    /// honest outcome; it needs one successful `/users/me/` ever, on any launch.
    private func createLocalDocument() -> Document? {
        guard let ownerUserID = signedInUser.userID else {
            errorKey = .home_error_create
            return nil
        }
        return saveCoordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: ownerUserID)
    }

    func createDocument() async -> Document? {
        // A retry must not sit underneath the message its predecessor left behind: nothing
        // else clears this one, since the failure path never reaches load().
        clearError()
        // Work Offline is a strict no-network contract on every read path, so honour it here
        // too rather than POSTing behind the user's back and reporting a failure they asked
        // for. Creating locally is the whole point of the mode.
        if userDefaults.bool(forKey: "schrift.workOffline") {
            return createLocalDocument()
        }
        let marker = diagnostics?.marker()
        do {
            let document = try await client.createDocument(title: "Untitled document")
            await load()
            return document
        } catch {
            // **Fall back only for a failure that is worth retrying.** Not, strictly, one that
            // "could not have created anything": a `.network` timeout can hide a POST the
            // server applied, and a 502/504 can sit in front of an origin that created the
            // document. The accepted residual is one orphaned *empty* document per such
            // response — the body is enqueued after migration, so the orphan never holds
            // content — which is the same trade the replay accepts for a lost response, and
            // the opposite of the `.decoding` case, where a 2xx makes creation likely enough
            // to block the retry outright.
            // `retryableSaveFailure` is the same classifier the save path uses: transport,
            // 5xx, rate limit. A rejection on the merits (a 400, a 403) means the server
            // answered and declined, and minting a local document there would promise a
            // replay that will be declined again — so those keep today's error.
            //
            // `.sessionExpired` is deliberately *not* a fallback either: the re-login sheet
            // is already up, and the document would be minted against an account the user is
            // in the middle of re-authenticating.
            if let apiError = error as? DocsAPIError, retryableSaveFailure(apiError) {
                return createLocalDocument()
            }
            errorKey = .home_error_create
            errorDetail = requestFailureDetail(after: marker, in: diagnostics)
            return nil
        }
    }

    // MARK: - Error state

    /// The one way an error leaves the screen without a reload. `createDocument`'s failure
    /// path never reaches `load()`, so before this the message could only be cleared by a
    /// pull-to-refresh — it looked permanent.
    func dismissError() {
        clearError()
    }

    private func clearError() {
        errorKey = nil
        errorDetail = nil
    }

}
