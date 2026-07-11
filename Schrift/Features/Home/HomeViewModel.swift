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
    var errorKey: L10nKey?
    /// The server's own words about the failure behind `errorKey`, when it had any —
    /// `DocsAPIError` collapses a CSRF 403, a validation 400, and a decoding bug into the
    /// same sentence, and a self-hoster needs to tell them apart without a debugger.
    var errorDetail: String?
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
    /// The same log the shared client records into. nil in previews and in tests that don't
    /// care, which simply means no detail is offered. Not private: the editor screens this
    /// view model pushes are handed the same log, or their detail never arrives.
    let diagnostics: APIDiagnosticsLog?
    /// Monotonic guard: a completing fetch applies its outcome only if no
    /// newer load() superseded it (latest-wins; .task refires on pop-back and
    /// races .refreshable and rapid filter switches).
    private var loadGeneration = 0

    init(
        client: DocsAPIClient,
        cache: DocumentCacheStore = DocumentCacheStore(),
        saveCoordinator: DocumentSaveCoordinator? = nil,
        userDefaults: UserDefaults = .standard,
        diagnostics: APIDiagnosticsLog? = nil
    ) {
        self.client = client
        self.cache = cache
        self.saveCoordinator = saveCoordinator ?? DocumentSaveCoordinator(client: client)
        self.userDefaults = userDefaults
        self.diagnostics = diagnostics
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
        clearError()
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
        let marker = diagnostics?.marker()
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
            // A real 401 is not "offline": the client's onSessionExpired hook
            // has already raised the app-level re-login sheet, so keep serving
            // cached rows silently. Everything else keeps the offline
            // treatment. Assigned unconditionally (like SharedViewModel's
            // recompute) so a 401 also *clears* a stale true from an earlier
            // network failure — device back online, session since expired.
            let failed = (error as? DocsAPIError) != .sessionExpired
            isOffline = failed
            // Silent when this filter has a cached list to fall back on
            // (offline reading); loud on a true first run of the filter —
            // pinned rows are no evidence for it — or an explicit
            // pull-to-refresh.
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
        let marker = diagnostics?.marker()
        do {
            let page = try await client.searchDocuments(query: trimmed)
            searchResults = page.results
        } catch {
            errorKey = .home_error_search
            errorDetail = requestFailureDetail(after: marker, in: diagnostics)
        }
    }

    func createDocument() async -> Document? {
        // A retry must not sit underneath the message its predecessor left behind: nothing
        // else clears this one, since the failure path never reaches load().
        clearError()
        let marker = diagnostics?.marker()
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
            errorKey = .home_error_create
            errorDetail = requestFailureDetail(after: marker, in: diagnostics)
            return nil
        }
    }

    // MARK: - Error state

    /// The one way an error leaves the screen without a reload. `createDocument`'s failure
    /// path never reaches `load()`, so before this the message could only be cleared by a
    /// pull-to-refresh or a filter switch — it looked permanent.
    func dismissError() {
        clearError()
    }

    private func clearError() {
        errorKey = nil
        errorDetail = nil
    }

}
