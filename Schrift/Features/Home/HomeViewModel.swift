import Foundation

@MainActor
@Observable
final class HomeViewModel {
    var selectedFilter: HomeFilter = .all
    var searchQuery: String = ""
    var pinnedDocuments: [Document] = []
    var recentDocuments: [Document] = []
    var searchResults: [Document] = []
    var isLoading = false
    var errorMessage: String?
    var isOffline = false
    /// Whether the current filter's list is known — cached or fetched this
    /// session. The view may render the "No documents yet" empty state only
    /// for a known list: nil (never fetched) must not masquerade as a real
    /// empty result, e.g. a never-visited filter under Work Offline (mirrors
    /// Shared's showsDocumentList).
    private(set) var isCurrentListKnown = false

    let client: DocsAPIClient
    let saveCoordinator: DocumentSaveCoordinator
    private let cache: DocumentCacheStore
    private let userDefaults: UserDefaults
    /// Monotonic guard: a completing fetch applies its outcome only if no
    /// newer load() superseded it (latest-wins; .task refires on pop-back and
    /// races .refreshable and rapid filter switches).
    private var loadGeneration = 0

    init(
        client: DocsAPIClient,
        cache: DocumentCacheStore = DocumentCacheStore(),
        saveCoordinator: DocumentSaveCoordinator? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.client = client
        self.cache = cache
        self.saveCoordinator = saveCoordinator ?? DocumentSaveCoordinator(client: client)
        self.userDefaults = userDefaults
        pinnedDocuments = cache.loadPinnedDocuments()
        if let recents = cache.loadRecentDocuments(filter: .all) {
            recentDocuments = recents
            isCurrentListKnown = true
        }
    }

    var showsPinnedSection: Bool {
        shouldShowPinnedSection(filter: selectedFilter, pinnedCount: pinnedDocuments.count)
    }

    func load(userInitiated: Bool = false) async {
        errorMessage = nil
        loadGeneration += 1
        let generation = loadGeneration
        let filter = selectedFilter

        // "Work offline" preference (Profile > Preferences): serve cached
        // documents and never hit the network.
        if userDefaults.bool(forKey: "schrift.workOffline") {
            pinnedDocuments = cache.loadPinnedDocuments()
            let cachedRecents = cache.loadRecentDocuments(filter: filter)
            recentDocuments = cachedRecents ?? []
            isCurrentListKnown = cachedRecents != nil
            isOffline = true
            isLoading = false
            return
        }

        // One read decides both halves of the silent-vs-loud policy: spinner
        // and error may only appear when this filter has no local list.
        // Pinned rows count as visible only when their section will actually
        // render — under the .pinned filter it is hidden, and suppressing the
        // spinner for rows the user can't see would leave a blank screen.
        let hasCachedList = cache.loadRecentDocuments(filter: filter) != nil
        isCurrentListKnown = hasCachedList
        let visiblePinnedCount =
            shouldShowPinnedSection(filter: filter, pinnedCount: pinnedDocuments.count)
            ? pinnedDocuments.count : 0
        isLoading = shouldShowLoadingPlaceholder(
            hasCachedList: hasCachedList,
            visibleRowCount: visiblePinnedCount + recentDocuments.count
        )

        // Replay any drafts stranded by a previous session (runs once).
        let coordinator = saveCoordinator
        Task { await coordinator.recoverDrafts() }

        let params = homeFilterQueryParameters(filter)
        do {
            async let pinnedPage = client.favoriteDocuments()
            async let recentPage = client.listDocuments(
                isFavorite: params.isFavorite,
                isCreatorMe: params.isCreatorMe,
                ordering: "-updated_at"
            )
            let pinned = try await pinnedPage.results
            let recent = try await recentPage.results
            guard generation == loadGeneration else { return }
            pinnedDocuments = pinned
            recentDocuments = recent
            cache.savePinnedDocuments(pinned)
            cache.saveRecentDocuments(recent, filter: filter)
            isCurrentListKnown = true
            isOffline = false
        } catch {
            guard generation == loadGeneration else { return }
            isOffline = true
            // Silent when this filter has a cached list to fall back on
            // (offline reading); loud on a true first run of the filter —
            // pinned rows are no evidence for it — or an explicit
            // pull-to-refresh.
            if userInitiated || !hasCachedList {
                errorMessage = "Couldn't load documents. Pull to refresh to try again."
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

    func selectFilter(_ filter: HomeFilter) async {
        guard filter != selectedFilter else { return }
        selectedFilter = filter
        // Instant swap: show this filter's cached rows (or empty) rather than
        // the previous filter's list while the fetch is in flight.
        let cachedRecents = cache.loadRecentDocuments(filter: filter)
        recentDocuments = cachedRecents ?? []
        isCurrentListKnown = cachedRecents != nil
        await load()
    }

    func search() async {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        do {
            let page = try await client.searchDocuments(query: trimmed)
            searchResults = page.results
        } catch {
            errorMessage = "Search failed. Please try again."
        }
    }

    func createDocument() async -> Document? {
        do {
            let document = try await client.createDocument(title: "Untitled document")
            if userDefaults.bool(forKey: "schrift.workOffline") {
                // load() skips the network in work-offline mode, so reflect
                // the new document directly rather than serving stale cache.
                // Screen and durable copy both go to the .all list only: a
                // brand-new document is neither a favorite nor shared-with-me,
                // so showing it under another filter would contradict that
                // filter's cache and vanish on the next cache-served load.
                if selectedFilter == .all {
                    recentDocuments.insert(document, at: 0)
                }
                var allDocuments = cache.loadRecentDocuments(filter: .all) ?? []
                allDocuments.insert(document, at: 0)
                cache.saveRecentDocuments(allDocuments, filter: .all)
            } else {
                await load()
            }
            return document
        } catch {
            errorMessage = "Couldn't create a document. Please try again."
            return nil
        }
    }

    func toggleFavorite(_ document: Document) async {
        do {
            try await client.setFavorite(documentID: document.id, isFavorite: !document.isFavorite)
            await load()
        } catch {
            errorMessage = "Couldn't update favorite. Please try again."
        }
    }
}
