import Foundation

@MainActor
@Observable
final class SearchViewModel {
    var query: String = ""
    /// The server's answer, and the trimmed query it answered (nil for rows set directly, which
    /// answer no query in particular — see `mergeSearchResults`).
    private var rawResults: [Document] = []
    private var serverResultsQuery: String?
    private var resultsPinRevision = -1
    /// The matches among the documents already on this device for the current query. Set before
    /// the server is asked, so a keystroke has rows at once.
    private var localResults: [Document] = []
    /// The searchable form of the on-device documents, kept for the length of one search session
    /// (until the query is cleared) so each keystroke is a scan of memory, not a read of the
    /// caches. `localEntriesOwner` is the account it was built for: it is not reused for another.
    private var localEntries: [LocalSearchEntry]?
    private var localEntriesOwner: UUID?
    /// The rows to show, server first and then the on-device matches the server did not return.
    /// While offline the server's rows are not an index and are left out.
    var resultSet: SearchResultSet {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let merged = mergeSearchResults(
            server: availability.isOffline ? [] : rawResults,
            serverIsCurrent: serverResultsQuery == trimmed, local: localResults)
        guard let pins = saveCoordinator?.pins else { return merged }
        let owner = signedInUser.userID
        return SearchResultSet(
            server: pins.applyingFlags(merged.server, ownerUserID: owner, fetchedAt: resultsPinRevision),
            localOnly: pins.applyingFlags(merged.localOnly, ownerUserID: owner, fetchedAt: resultsPinRevision))
    }
    var results: [Document] {
        get { resultSet.all }
        set {
            rawResults = newValue
            serverResultsQuery = nil
        }
    }
    private var rawQuickAccess: [Document] = []
    private var quickPinRevision = -1
    var quickAccess: [Document] {
        get {
            saveCoordinator?.pins.resolve(
                pinned: rawQuickAccess, recent: [], ownerUserID: signedInUser.userID, fetchedAt: quickPinRevision
            ).pinned ?? rawQuickAccess
        }
        set { rawQuickAccess = newValue }
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
            guard generation == quickAccessGeneration, availability.permitsResponse(for: token), !Task.isCancelled
            else { return }
            quickPinRevision = pinRevision
            rawQuickAccess = page.results.filter { !deletedSinceLoad.contains($0.id) }
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
    /// finishes after a newer search began.
    func search() async {
        searchGeneration += 1
        let generation = searchGeneration
        let pinRevision = saveCoordinator?.pins.revision ?? -1
        let pinOwner = signedInUser.userID
        let token = availability.token
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        isSearching = false
        guard !trimmed.isEmpty else {
            results = []
            localResults = []
            localEntries = nil
            return
        }
        // A request is coming, so with nothing to show yet the screen draws placeholder rows
        // from the first keystroke rather than a "no results" flash.
        isSearching = !availability.isOffline
        defer { if generation == searchGeneration { isSearching = false } }

        await searchOnDevice(trimmed, generation: generation)
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
                query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
            else { return }
            resultsPinRevision = pinRevision
            rawResults = page.results.filter { !deletedSinceLoad.contains($0.id) }
            serverResultsQuery = trimmed
            saveCoordinator?.pins.didReadFlags(rawResults, ownerUserID: pinOwner, fetchedAt: pinRevision)
        } catch {
            if generation == searchGeneration { isSearching = false }
            guard generation == searchGeneration, availability.permitsResponse(for: token), !Task.isCancelled,
                query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
            else { return }
            errorKey = .search_error_search
        }
    }

    /// Matches `trimmed` against the documents on this device and installs the rows, unless a
    /// newer search began meanwhile. The scan runs off the main actor.
    private func searchOnDevice(_ trimmed: String, generation: Int) async {
        let owner = signedInUser.userID
        let entries: [LocalSearchEntry]
        if let cached = localEntries, localEntriesOwner == owner {
            entries = cached
        } else {
            let documents = localSearchDocuments()
            let readContents = contentCache.allContentsReader()
            entries = await Task.detached(priority: .userInitiated) {
                localSearchEntries(documents: documents, contents: readContents())
            }.value
            // Kept even when a newer keystroke superseded this search: the index is not about
            // this query, and dropping it would rebuild it for every keystroke typed meanwhile.
            localEntries = entries.filter { !deletedSinceLoad.contains($0.document.id) }
            localEntriesOwner = owner
        }
        let locale = locale
        let scan = Task.detached(priority: .userInitiated) {
            localSearchResults(query: trimmed, entries: entries, locale: locale)
        }
        let found = await withTaskCancellationHandler {
            await scan.value
        } onCancel: {
            scan.cancel()
        }
        guard generation == searchGeneration, !Task.isCancelled else { return }
        localResults = found.filter { !deletedSinceLoad.contains($0.id) }
    }

    /// The documents on this device that this account is known to see: Home's cached lists, but
    /// only those a fetch for the signed-in account wrote (`documents(fetchedFor:)` — none when
    /// the account is not known yet or the list was never stamped), and the cached sub-pages of
    /// exactly those documents. Neither cache is cleared on sign-out, so reading them any other
    /// way would search the previous user's titles for the next one.
    private func localSearchDocuments() -> [Document] {
        guard let owner = signedInUser.userID else { return [] }
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
