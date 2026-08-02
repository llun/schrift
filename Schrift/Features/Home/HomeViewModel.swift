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
    /// merged in at read time.
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
        let version = saveCoordinator.pendingCreatesVersion
        if let cached = mergedRecents, cached.version == version, cached.fetched == fetchedRecentDocuments {
            return cached.merged
        }
        let merged = mergedWithLocalDocuments(
            fetched: fetchedRecentDocuments,
            local: saveCoordinator.pendingLocalDocuments(
                parentID: nil, currentUserID: signedInUser.userID))
        mergedRecents = (version, fetchedRecentDocuments, merged)
        return merged
    }

    /// Memo for `recentDocuments`. `@ObservationIgnored` so writing it from a *getter* does
    /// not register a mutation and re-invalidate the very view that just read it.
    @ObservationIgnored
    private var mergedRecents: (version: Int, fetched: [Document], merged: [Document])?
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
            fetchedRecentDocuments = cachedRecents ?? []
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
            let pinned = try await pinnedPage.results
            let recent = try await recentPage.results
            guard generation == loadGeneration else { return }
            pinnedDocuments = pinned
            fetchedRecentDocuments = recent
            cache.savePinnedDocuments(pinned)
            cache.saveRecentDocuments(recent)
            hasKnownFetchedList = true
            isOffline = false
        } catch {
            guard generation == loadGeneration else { return }
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
            searchResults = page.results
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

    /// Whether this row is a document created here that the server has not seen yet.
    func isLocalDocument(_ document: Document) -> Bool {
        saveCoordinator.isPendingCreate(documentID: document.id)
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
            // **Fall back only for a failure that could not have created anything.**
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
