import Foundation

@MainActor
@Observable
final class SharedViewModel {
    /// Documents shared with the current user (newest first).
    var documents: [Document] = []
    /// Best-effort per-document members + creator name, resolved from each
    /// document's accesses after the list lands. Absent ⇒ date-only subtitle,
    /// no avatars.
    var enrichment: [UUID: SharedRowEnrichment] = [:]
    /// A list load is in flight. Whether that shows as a placeholder is decided
    /// by `showsLoadingPlaceholder`.
    var isLoading = false
    var errorKey: L10nKey?
    var isOffline = false

    let client: DocsAPIClient
    private let cache: DocumentCacheStore
    private let userDefaults: UserDefaults
    /// Monotonic guard: a completing fetch (list or enrichment) applies its
    /// outcome only if no newer load() superseded it (.task refires on every
    /// tab revisit and races .refreshable).
    private var loadGeneration = 0
    /// True once a real local list exists (cached or fetched). An unknown list
    /// must never render as "0 documents"; nil ≠ empty.
    private var hasLoaded = false

    init(
        client: DocsAPIClient,
        cache: DocumentCacheStore = DocumentCacheStore(),
        userDefaults: UserDefaults = .standard
    ) {
        self.client = client
        self.cache = cache
        self.userDefaults = userDefaults
        if let withMe = cache.loadSharedWithMeDocuments() {
            documents = withMe
            hasLoaded = true
        }
    }

    /// Spinner only while fetching a list that has no local copy yet. A cached
    /// (even empty) list revalidates silently.
    var showsLoadingPlaceholder: Bool {
        isLoading && !hasLoaded && documents.isEmpty
    }

    /// The list (and "N documents" header) may render once known; a
    /// never-fetched/never-cached list shows neither — the banner/error conveys
    /// state instead of a false "0 documents".
    var showsDocumentList: Bool {
        hasLoaded || !documents.isEmpty
    }

    func load(userInitiated: Bool = false) async {
        errorKey = nil
        loadGeneration += 1
        let generation = loadGeneration

        // "Work offline" (Profile > Preferences): serve cache, never hit the network.
        if userDefaults.bool(forKey: "schrift.workOffline") {
            if let withMe = cache.loadSharedWithMeDocuments() {
                documents = withMe
                hasLoaded = true
            }
            isOffline = true
            isLoading = false
            return
        }

        let hadCache = hasLoaded
        isLoading = true
        let withMe: [Document]
        do {
            withMe = try await client.listDocuments(isCreatorMe: false, ordering: "-updated_at").results
        } catch {
            guard generation == loadGeneration else { return }
            // A real 401 is not "offline": the client's onSessionExpired hook has
            // already raised the app-level re-login sheet, so keep cache silently.
            let failed = (error as? DocsAPIError) != .sessionExpired
            isOffline = failed
            // Loud when a failing load has no cache to fall back on, or on an
            // explicit pull-to-refresh.
            if failed, userInitiated || !hadCache {
                errorKey = .shared_error_load
            }
            isLoading = false
            return
        }
        guard generation == loadGeneration else { return }
        documents = withMe
        cache.saveSharedWithMeDocuments(withMe)
        hasLoaded = true
        isOffline = false
        isLoading = false
        // Prune enrichment to the current list: a document that is no longer
        // shared can't keep showing stale avatars, and the dictionary can't grow
        // without bound across a long session. Surviving entries are overwritten
        // as fresh accesses land.
        let currentIDs = Set(withMe.map(\.id))
        enrichment = enrichment.filter { currentIDs.contains($0.key) }

        // Enrichment runs *outside* the list-load do/catch above and never
        // throws — so a decorative accesses failure can never be caught there
        // and misreported as a failed document list (offline / errorKey).
        await enrich(documents: withMe, generation: generation)
    }

    /// Fetch each document's accesses concurrently and resolve avatars +
    /// creator name. Best-effort: a per-document failure leaves that row
    /// un-enriched and never surfaces an error or "offline". Generation-guarded
    /// so a superseded load's late results are dropped.
    private func enrich(documents: [Document], generation: Int) async {
        await withTaskGroup(of: (UUID, SharedRowEnrichment?).self) { group in
            for document in documents {
                let id = document.id
                let creator = document.creator
                group.addTask { [client] in
                    do {
                        let accesses = try await client.listAccesses(documentID: id)
                        return (
                            id,
                            SharedRowEnrichment(
                                sharedByName: sharedCreatorName(accesses: accesses, creator: creator),
                                memberNames: sharedMemberNames(accesses: accesses)
                            )
                        )
                    } catch {
                        return (id, nil)
                    }
                }
            }
            for await (id, result) in group {
                guard generation == loadGeneration else { continue }
                if let result { enrichment[id] = result }
            }
        }
    }

    /// Explicit pull-to-refresh: surfaces failures instead of swallowing them
    /// behind cached rows.
    func refresh() async {
        await load(userInitiated: true)
    }
}
