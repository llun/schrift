import Foundation

@MainActor
@Observable
final class HomeViewModel {
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
    /// Whether the recent list is known — cached or fetched this session. The
    /// view may render the "No documents yet" empty state only for a known
    /// list: nil (never fetched) must not masquerade as a real empty result,
    /// e.g. a fresh install under Work Offline (mirrors Shared's
    /// showsDocumentList).
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
    /// races .refreshable).
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
        if let recents = cache.loadRecentDocuments() {
            recentDocuments = recents
            isCurrentListKnown = true
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
            recentDocuments = cachedRecents ?? []
            isCurrentListKnown = cachedRecents != nil
            isOffline = true
            isLoading = false
            return
        }

        // One read decides both halves of the silent-vs-loud policy: spinner
        // and error may only appear when the list has no local copy. Pinned
        // rows are visible whenever the pinned section renders, so they count
        // toward "rows on screen" and rightly suppress the first-run spinner.
        let hasCachedList = cache.loadRecentDocuments() != nil
        isCurrentListKnown = hasCachedList
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
            recentDocuments = recent
            cache.savePinnedDocuments(pinned)
            cache.saveRecentDocuments(recent)
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
                recentDocuments.insert(document, at: 0)
                var recents = cache.loadRecentDocuments() ?? []
                recents.insert(document, at: 0)
                cache.saveRecentDocuments(recents)
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
    /// pull-to-refresh — it looked permanent.
    func dismissError() {
        clearError()
    }

    private func clearError() {
        errorKey = nil
        errorDetail = nil
    }

}
