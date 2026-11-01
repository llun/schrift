import Foundation

@MainActor
@Observable
final class SearchViewModel {
    var query: String = ""
    /// The server's answer, the trimmed query it answered (nil for rows set directly, which
    /// answer no query in particular) and the account it was fetched for. The rows stay on screen
    /// while a newer query is in flight (see `mergeSearchResults`), but never for another account.
    private var rawResults: [Document] = []
    private(set) var serverResultsQuery: String?
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
        let server = availability.isOffline || serverResultsOwner != owner ? [] : rawResults
        let merged = mergeSearchResults(server: server, local: localResultsOwner == owner ? localResults : [])
        guard let pins = saveCoordinator?.pins else { return merged }
        return SearchResultSet(
            server: pins.applyingFlags(merged.server, ownerUserID: owner, fetchedAt: resultsPinRevision),
            localOnly: pins.applyingFlags(merged.localOnly, ownerUserID: owner, fetchedAt: resultsPinRevision))
    }
    var results: [Document] {
        get { resultSet.all }
        set {
            rawResults = newValue
            serverResultsQuery = nil
            serverResultsOwner = signedInUser.userID
        }
    }
    private var rawQuickAccess: [Document] = []
    private var quickAccessOwner: UUID?
    private var quickPinRevision = -1
    var quickAccess: [Document] {
        get {
            // Like the results, the pinned list is never shown to another account than its own.
            let owner = signedInUser.userID
            let rows = quickAccessOwner == owner ? rawQuickAccess : []
            return saveCoordinator?.pins.resolve(
                pinned: rows, recent: [], ownerUserID: owner, fetchedAt: quickPinRevision
            ).pinned ?? rows
        }
        set {
            rawQuickAccess = newValue
            quickAccessOwner = signedInUser.userID
        }
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

    func loadQuickAccess() async {
        quickAccessGeneration += 1
        let generation = quickAccessGeneration
        let pinRevision = saveCoordinator?.pins.revision ?? -1
        let pinOwner = signedInUser.userID
        guard !availability.isOffline else { return }
        let token = availability.token
        do {
            let page = try await client.favoriteDocuments()
            guard generation == quickAccessGeneration, availability.permitsResponse(for: token), !Task.isCancelled,
                signedInUser.userID == pinOwner
            else { return }
            quickPinRevision = pinRevision
            rawQuickAccess = page.results.filter { !deletedSinceLoad.contains($0.id) }
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
    /// another account signed in.
    func search() async {
        searchGeneration += 1
        let generation = searchGeneration
        let pinRevision = saveCoordinator?.pins.revision ?? -1
        // Captured before any await: whatever this search finds is that account's.
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
        // A request is coming, so with nothing to show yet the screen draws placeholder rows
        // from the first keystroke rather than a "no results" flash.
        isSearching = !availability.isOffline
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
            guard generation == searchGeneration, availability.permitsResponse(for: token), !Task.isCancelled,
                query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed, signedInUser.userID == owner
            else { return }
            resultsPinRevision = pinRevision
            rawResults = page.results.filter { !deletedSinceLoad.contains($0.id) }
            serverResultsQuery = trimmed
            serverResultsOwner = owner
            saveCoordinator?.pins.didReadFlags(rawResults, ownerUserID: owner, fetchedAt: pinRevision)
        } catch {
            if generation == searchGeneration { isSearching = false }
            guard generation == searchGeneration, availability.permitsResponse(for: token), !Task.isCancelled,
                query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
            else { return }
            errorKey = .search_error_search
        }
    }

    /// Drops the on-device index, so the next search reads the caches again — and a build in
    /// flight now is not installed when it finishes. Called when the query is cleared, and by the
    /// screen when it appears and when the session changes: this view model outlives the screen
    /// and keeps its query, so otherwise one "session" could last as long as the app and miss
    /// every document opened, edited or newly cached since its index was built.
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
