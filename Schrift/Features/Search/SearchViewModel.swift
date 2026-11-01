import Foundation

@MainActor
@Observable
final class SearchViewModel {
    var query: String = ""
    /// The server's answer, the trimmed query it answered (nil for rows set directly, which
    /// answer no query in particular), the sign-in session whose cookies fetched it and the
    /// account known when it landed (nil while that session's id was still being learned). The
    /// rows stay on screen while a query that refines theirs is in flight (see
    /// `mergeSearchResults`), but never for another query, another session or another account
    /// (`showsServerRows`).
    private var rawResults: [Document] = []
    private(set) var serverResultsQuery: String?
    private var serverResultsSession = 0
    private var serverResultsOwner: UUID?
    private var resultsPinRevision = -1
    /// The matches among the documents already on this device, the trimmed query they answered
    /// and the account whose documents they were found among. Set before the server is asked, so
    /// a keystroke has rows at once.
    private var localResults: [Document] = []
    private(set) var localResultsQuery: String?
    private var localResultsOwner: UUID?
    /// The searchable form of the on-device documents, kept for the length of one search session
    /// so each keystroke is a scan of memory, not a read of the caches. A session ends when the
    /// query is cleared or Search appears (`invalidateLocalIndex`), and the index is only reused
    /// for the account and the availability it was built under (`LocalIndexKey`).
    private var localEntries: [LocalSearchEntry]?
    private var localEntriesKey: LocalIndexKey?
    /// The index build in flight. Every search typed while it runs awaits it instead of starting
    /// another read of the caches.
    private var localIndexBuild: LocalIndexBuild?
    /// Bumped whenever the index is dropped, so a build that was in flight then is not installed.
    private var localIndexSession = 0
    /// The rows to show, server first and then the on-device matches the server did not return.
    /// While offline the server's rows are not an index and are left out. Rows found for another
    /// account than the signed-in one are never shown: an account switch through the re-login
    /// sheet keeps this view model, and the on-device rows carry cached body text.
    var resultSet: SearchResultSet {
        let owner = signedInUser.userID
        let server = showsServerRows ? rawResults : []
        let merged = mergeSearchResults(server: server, local: localResultsOwner == owner ? localResults : [])
        guard let pins = saveCoordinator?.pins else { return merged }
        return SearchResultSet(
            server: pins.applyingFlags(merged.server, ownerUserID: owner, fetchedAt: resultsPinRevision),
            localOnly: pins.applyingFlags(merged.localOnly, ownerUserID: owner, fetchedAt: resultsPinRevision))
    }
    /// Whether the server's rows answer what is on screen now. Online only; only in the session
    /// that fetched them (`belongsToSession`); and only while the current query is theirs or
    /// refines it — typing on keeps them in place until the new answer lands, but another query
    /// (a recent term, a deleted character, a different word typed offline before a reconnect)
    /// does not show an unrelated answer as its results.
    private var showsServerRows: Bool {
        guard !availability.isOffline, belongsToSession(serverResultsSession, owner: serverResultsOwner) else {
            return false
        }
        guard let serverResultsQuery else { return true }
        return query.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(serverResultsQuery)
    }
    var results: [Document] {
        get { resultSet.all }
        set {
            rawResults = newValue
            serverResultsQuery = nil
            serverResultsSession = signInGeneration
            serverResultsOwner = signedInUser.userID
        }
    }
    private var rawQuickAccess: [Document] = []
    private var quickAccessSession = 0
    private var quickAccessOwner: UUID?
    private var quickPinRevision = -1
    var quickAccess: [Document] {
        get {
            // Like the results, the pinned list is only shown in the session that fetched it.
            let owner = signedInUser.userID
            let rows = belongsToSession(quickAccessSession, owner: quickAccessOwner) ? rawQuickAccess : []
            return saveCoordinator?.pins.resolve(
                pinned: rows, recent: [], ownerUserID: owner, fetchedAt: quickPinRevision
            ).pinned ?? rows
        }
        set {
            rawQuickAccess = newValue
            quickAccessSession = signInGeneration
            quickAccessOwner = signedInUser.userID
        }
    }

    /// `SessionStore.signInGeneration` as the screen last reported it (`beginSession`, or the
    /// argument to `search`/`loadQuickAccess`).
    ///
    /// The server's rows and Quick access are stamped with it rather than with the account id
    /// alone: they are what one session's cookies were answered with, so they belong to that
    /// session even when its id is learned only afterwards. A re-login clears the id, bumps the
    /// generation and learns the id again from `/users/me/` some time later, so an answer
    /// gated on the id known when it was asked would be dropped or hidden, with nothing to run
    /// it again. The on-device lists stay gated on the id itself (`localSearchDocuments`).
    private(set) var signInGeneration = 0

    /// The signed-in account's id, for the screen to search again once a re-login learns it:
    /// `SignedInUserStore` is not observable, and the on-device half reads nothing while the id is
    /// unknown. Reading `pins.revision` registers the dependency on
    /// `DocumentPinCoordinator.sessionIdentityDidChange`, which `HomeViewModel
    /// .refreshSignedInUser` calls when it learns a different id.
    var signedInUserID: UUID? {
        _ = saveCoordinator?.pins.revision
        return signedInUser.userID
    }

    /// Whether rows fetched in `session`, when `owner` was the known account, may be shown now:
    /// only in that same session, and never once another account is known. An id learned after
    /// they landed (`owner` nil) is that session's own, so it does not hide them; an id cleared
    /// since (a re-login starting) hides rows known to be the previous account's at once.
    private func belongsToSession(_ session: Int, owner: UUID?) -> Bool {
        session == signInGeneration && (owner == nil || owner == signedInUser.userID)
    }

    /// Search appeared, or the sign-in session changed under it: the previous session's server
    /// rows and Quick access stop showing at once, before the screen's tasks search again, and the
    /// on-device index is read afresh (`invalidateLocalIndex`).
    func beginSession(signInGeneration: Int) {
        self.signInGeneration = signInGeneration
        invalidateLocalIndex()
    }

    var recentSearches: [String] = []
    var isSearching = false
    var errorKey: L10nKey?

    let availability: OnlineAvailability
    private var searchGeneration = 0
    private var quickAccessGeneration = 0

    let client: DocsAPIClient
    private let store: RecentSearchesStore
    /// The caches the on-device search reads. Their lists are not cleared on sign-out, so they
    /// are only read through the account-scoped accessors — see `localSearchDocuments`.
    private let listCache: DocumentCacheStore
    private let childrenCache: DocumentChildrenCacheStore
    private let contentCache: DocumentContentCacheStore
    /// The locale on-device matching folds case and diacritics with — the app's, set by the
    /// screen, so a row is found by the same rule that then highlights it.
    var locale: Locale = .current
    /// Optional: nil simply means "no queued deletions to annotate here", which is what every
    /// existing call site and `#Preview` gets.
    private let saveCoordinator: DocumentSaveCoordinator?
    private let signedInUser: SignedInUserStore
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

    init(
        client: DocsAPIClient, store: RecentSearchesStore = RecentSearchesStore(),
        saveCoordinator: DocumentSaveCoordinator? = nil,
        signedInUser: SignedInUserStore = SignedInUserStore(),
        availability: OnlineAvailability = OnlineAvailability(),
        listCache: DocumentCacheStore = DocumentCacheStore(),
        childrenCache: DocumentChildrenCacheStore = DocumentChildrenCacheStore(),
        contentCache: DocumentContentCacheStore = DocumentContentCacheStore()
    ) {
        self.client = client
        self.listCache = listCache
        self.childrenCache = childrenCache
        self.contentCache = contentCache
        self.availability = availability
        self.store = store
        self.saveCoordinator = saveCoordinator
        self.signedInUser = signedInUser
        recentSearches = store.searches
        // A landed deletion: drop the row from the array this view model holds. The caches are
        // purged by the coordinator, but these are its own — and leaving the row does worse
        // than linger, since the tombstone is gone and it would **un-strike** back into
        // looking like a live document.
        saveCoordinator?.observeDocumentDeleted(self) { [weak self] documentID in
            self?.dropDeletedDocument(documentID)
        }

    }

    private func dropDeletedDocument(_ documentID: UUID) {
        rawResults.removeAll { $0.id == documentID }
        localResults.removeAll { $0.id == documentID }
        localEntries?.removeAll { $0.document.id == documentID }
        rawQuickAccess.removeAll { $0.id == documentID }
        deletedSinceLoad.insert(documentID)
    }
    /// Search caches nothing, so there is no durable resurrection to prevent — but an
    /// in-flight fetch can still write the row back on screen. "The next keystroke replaces it"
    /// covers `search`, whose results the user is actively retyping over; it does **not** cover
    /// `loadQuickAccess`, which is not query-driven and assigns unconditionally. Both filter.

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
        saveCoordinator?.isListablePendingDelete(
            documentID: document.id, currentUserID: signedInUser.userID) ?? false
    }

    /// Cancel a queued deletion, and kick the sync funnel: a draft this document had was
    /// suppressed while the tombstone stood, and undoing is exactly when it becomes replayable
    /// again.
    func undoPendingDelete(_ document: Document) {
        guard let saveCoordinator else { return }
        saveCoordinator.cancelPendingDelete(documentID: document.id)
        Task { await saveCoordinator.syncPendingDrafts() }
    }

    /// `signInGeneration` is the session the screen loads for (nil keeps the last one reported).
    func loadQuickAccess(signInGeneration: Int? = nil) async {
        if let signInGeneration { self.signInGeneration = signInGeneration }
        let session = self.signInGeneration
        quickAccessGeneration += 1
        let generation = quickAccessGeneration
        let pinRevision = saveCoordinator?.pins.revision ?? -1
        let askedOwner = signedInUser.userID
        guard !availability.isOffline else { return }
        let token = availability.token
        do {
            let page = try await client.favoriteDocuments()
            // The session's answer, even when its id was learned meanwhile; but not once a known
            // account changed under it.
            guard generation == quickAccessGeneration, availability.permitsResponse(for: token), !Task.isCancelled,
                session == self.signInGeneration, askedOwner == nil || signedInUser.userID == askedOwner
            else { return }
            let pinOwner = signedInUser.userID
            quickPinRevision = pinRevision
            rawQuickAccess = page.results.filter { !deletedSinceLoad.contains($0.id) }
            quickAccessSession = session
            quickAccessOwner = pinOwner
            // Membership in this endpoint proves pinned even when the serializer omits the flag.
            let pinnedRows = rawQuickAccess.map { row in
                var row = row
                row.isFavorite = true
                return row
            }
            saveCoordinator?.pins.didReadFlags(pinnedRows, ownerUserID: pinOwner, fetchedAt: pinRevision)
        } catch {
            guard generation == quickAccessGeneration, availability.permitsResponse(for: token), !Task.isCancelled
            else { return }
            errorKey = .search_error_quick
        }
    }

    /// Searches twice. The documents already on this device are matched first, at once and
    /// without a request — on every keystroke, with no debounce, and also while offline. The
    /// server is asked after the debounce (online only) and its rows are merged in by
    /// `resultSet`.
    ///
    /// Cancelling the task (the enclosing `.task(id:)` does on every keystroke) abandons the scan
    /// in flight and drops its result; the generation check does the same for a scan that
    /// finishes after a newer search began, and the owner check for one that finishes after
    /// another account signed in. The server's answer is the session's (`signInGeneration`, nil
    /// keeps the last one reported), so it is kept when the session's id is learned meanwhile.
    func search(signInGeneration: Int? = nil) async {
        if let signInGeneration { self.signInGeneration = signInGeneration }
        let session = self.signInGeneration
        searchGeneration += 1
        let generation = searchGeneration
        let pinRevision = saveCoordinator?.pins.revision ?? -1
        // Captured before any await: whatever the device finds is that account's.
        let owner = signedInUser.userID
        let token = availability.token
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        isSearching = false
        guard !trimmed.isEmpty else {
            results = []
            localResults = []
            localResultsQuery = nil
            invalidateLocalIndex()
            return
        }
        // A new question: the previous one's failure (or Quick access', which shares the property)
        // is not its answer. Cleared here rather than before the request, which an offline search
        // never reaches.
        errorKey = nil
        // An answer is coming — the device's, and online the server's too — so with nothing to
        // show yet the screen draws placeholder rows from the first keystroke rather than a "no
        // results" flash. Offline too: reading the caches and scanning take a moment, and the
        // empty state is only true once the device has answered.
        isSearching = true
        defer { if generation == searchGeneration { isSearching = false } }

        await searchOnDevice(trimmed, owner: owner, generation: generation)
        guard generation == searchGeneration, !Task.isCancelled else { return }
        guard !availability.isOffline else { return }

        // Debounce: when the query changes, the enclosing `.task(id:)` cancels
        // this task, so a newer keystroke supersedes an in-flight search and
        // stale results never overwrite fresh ones.
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard generation == searchGeneration, availability.permitsResponse(for: token), !Task.isCancelled,
            query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
        else { return }

        isSearching = true
        errorKey = nil
        do {
            let page = try await client.searchDocuments(query: trimmed)
            if generation == searchGeneration { isSearching = false }
            // The session's answer, even when its id was learned meanwhile (a re-login); but not
            // once a known account changed under it.
            guard generation == searchGeneration, availability.permitsResponse(for: token), !Task.isCancelled,
                query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed, session == self.signInGeneration,
                owner == nil || signedInUser.userID == owner
            else { return }
            let landedOwner = signedInUser.userID
            resultsPinRevision = pinRevision
            rawResults = page.results.filter { !deletedSinceLoad.contains($0.id) }
            serverResultsQuery = trimmed
            serverResultsSession = session
            serverResultsOwner = landedOwner
            saveCoordinator?.pins.didReadFlags(rawResults, ownerUserID: landedOwner, fetchedAt: pinRevision)
        } catch {
            if generation == searchGeneration { isSearching = false }
            guard generation == searchGeneration, availability.permitsResponse(for: token), !Task.isCancelled,
                query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
            else { return }
            errorKey = .search_error_search
            // The rows of an earlier query were only kept as a placeholder for this answer, and
            // none is coming: they are not this query's results. An answer to this very query
            // (Search revisited with the network gone) still is, so it stays above the error.
            if serverResultsQuery != trimmed {
                rawResults = []
                serverResultsQuery = nil
            }
        }
    }

    /// Drops the on-device index, so the next search reads the caches again — and a build in
    /// flight now is not installed when it finishes. Called when the query is cleared, and when
    /// the screen appears and when the session changes (`beginSession`): this view model outlives
    /// the screen and keeps its query, so otherwise one "session" could last as long as the app
    /// and miss every document opened, edited or newly cached since its index was built.
    func invalidateLocalIndex() {
        localIndexSession += 1
        localEntries = nil
        localEntriesKey = nil
        localIndexBuild = nil
    }

    /// Matches `trimmed` against `owner`'s documents on this device and installs the rows, unless
    /// a newer search began or another account signed in meanwhile. The scan runs off the main
    /// actor.
    private func searchOnDevice(_ trimmed: String, owner: UUID?, generation: Int) async {
        guard let entries = await localIndex(for: owner, generation: generation) else { return }
        let locale = locale
        let scan = Task.detached(priority: .userInitiated) {
            localSearchResults(query: trimmed, entries: entries, locale: locale)
        }
        let found = await withTaskCancellationHandler {
            await scan.value
        } onCancel: {
            scan.cancel()
        }
        guard generation == searchGeneration, !Task.isCancelled, signedInUser.userID == owner else { return }
        localResults = found.filter { !deletedSinceLoad.contains($0.id) }
        localResultsQuery = trimmed
        localResultsOwner = owner
    }

    /// What an on-device index was built for. It is reused only for the same account, and only
    /// under the same availability: a reconnect or a Work Offline toggle is when Home refreshes
    /// the caches it reads.
    private struct LocalIndexKey: Equatable {
        let owner: UUID?
        let availability: OnlineAvailability.Token
    }

    private struct LocalIndexBuild {
        let session: Int
        let key: LocalIndexKey
        let task: Task<[LocalSearchEntry], Never>
    }

    /// `owner`'s on-device index: the session's, or the one being built (awaited rather than
    /// started again), or a new build. nil when another account signed in meanwhile, or when
    /// the session was reset under a search that is no longer current.
    private func localIndex(for owner: UUID?, generation: Int) async -> [LocalSearchEntry]? {
        let key = LocalIndexKey(owner: owner, availability: availability.token)
        if let localEntries, localEntriesKey == key { return localEntries }
        let session = localIndexSession
        let build: Task<[LocalSearchEntry], Never>
        if let inFlight = localIndexBuild, inFlight.session == session, inFlight.key == key {
            build = inFlight.task
        } else {
            let documents = localSearchDocuments(owner: owner)
            let readContents = contentCache.allContentsReader()
            build = Task.detached(priority: .userInitiated) {
                localSearchEntries(documents: documents, contents: readContents())
            }
            localIndexBuild = LocalIndexBuild(session: session, key: key, task: build)
        }
        let entries = await build.value
        if let inFlight = localIndexBuild, inFlight.session == session, inFlight.key == key {
            localIndexBuild = nil
        }
        // Another account signed in while it was building: nothing read for the previous one is used.
        guard signedInUser.userID == owner else { return nil }
        // The session was reset (the query cleared, the screen reappeared) or availability changed
        // while it was building: what it read may be out of date, so it is not kept and the caches
        // are read again — unless this search was abandoned or superseded meanwhile, when the
        // search that replaced it builds its own.
        guard session == localIndexSession, key == LocalIndexKey(owner: owner, availability: availability.token)
        else {
            if Task.isCancelled || generation != searchGeneration { return nil }
            return await localIndex(for: owner, generation: generation)
        }
        // Kept even when a newer keystroke superseded this search: the index is not about this
        // query, and dropping it would rebuild it for every keystroke typed meanwhile.
        let kept = entries.filter { !deletedSinceLoad.contains($0.document.id) }
        localEntries = kept
        localEntriesKey = key
        return kept
    }

    /// The documents on this device that `owner` is known to see: Home's cached lists, but only
    /// those a fetch for that account wrote (`documents(fetchedFor:)` — none when the account is
    /// not known yet or the list was never stamped), and the cached sub-pages of exactly those
    /// documents. Neither cache is cleared on sign-out, so reading them any other way would
    /// search the previous user's titles for the next one.
    private func localSearchDocuments(owner: UUID?) -> [Document] {
        guard let owner else { return [] }
        let lists = listCache.documents(fetchedFor: owner)
        return lists + childrenCache.children(ofParents: Set(lists.map(\.id)))
    }

    func recordSearch() {
        guard !availability.isOffline else { return }
        store.add(query)
        recentSearches = store.searches
    }

    func selectRecent(_ term: String) {
        query = term
    }

    func clearRecent() {
        store.clear()
        recentSearches = store.searches
    }
}
