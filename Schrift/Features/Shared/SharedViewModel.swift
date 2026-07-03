import Foundation

@MainActor
@Observable
final class SharedViewModel {
    enum Scope {
        case withMe
        case byMe
    }

    var scope: Scope = .withMe
    var sharedWithMe: [Document] = []
    var sharedByMe: [Document] = []
    var isLoading = false
    var errorMessage: String?
    var isOffline = false

    let client: DocsAPIClient
    private let cache: DocumentCacheStore
    private let userDefaults: UserDefaults
    /// Monotonic guard: a completing fetch applies its outcome only if no
    /// newer load() superseded it (latest-wins; .task refires on every tab
    /// revisit and races .refreshable).
    private var loadGeneration = 0

    init(
        client: DocsAPIClient,
        cache: DocumentCacheStore = DocumentCacheStore(),
        userDefaults: UserDefaults = .standard
    ) {
        self.client = client
        self.cache = cache
        self.userDefaults = userDefaults
        sharedWithMe = cache.loadSharedWithMeDocuments() ?? []
        sharedByMe = cache.loadSharedByMeDocuments() ?? []
    }

    var documents: [Document] {
        scope == .withMe ? sharedWithMe : sharedByMe
    }

    func load(userInitiated: Bool = false) async {
        errorMessage = nil
        loadGeneration += 1
        let generation = loadGeneration

        // "Work offline" preference (Profile > Preferences): serve cached
        // documents and never hit the network.
        if userDefaults.bool(forKey: "schrift.workOffline") {
            sharedWithMe = cache.loadSharedWithMeDocuments() ?? []
            sharedByMe = cache.loadSharedByMeDocuments() ?? []
            isOffline = true
            isLoading = false
            return
        }

        // Cache existence is read per scope: the silent-vs-loud policy is
        // keyed to the exact list that failed (nil = never cached ≠ cached
        // empty), so one scope's cache never silences the other's first-ever
        // failure.
        let hadWithMeCache = cache.loadSharedWithMeDocuments() != nil
        let hadByMeCache = cache.loadSharedByMeDocuments() != nil
        isLoading = shouldShowLoadingPlaceholder(
            hasCachedList: hadWithMeCache || hadByMeCache,
            visibleRowCount: sharedWithMe.count + sharedByMe.count
        )

        // Load each scope independently so a failure in one doesn't discard the
        // other's results (partial success is kept; the failing scope keeps its
        // cached rows).
        var withMeFailed = false
        var byMeFailed = false
        do {
            let withMe = try await client.listDocuments(isCreatorMe: false, ordering: "-updated_at").results
            guard generation == loadGeneration else { return }
            sharedWithMe = withMe
            cache.saveSharedWithMeDocuments(withMe)
        } catch {
            guard generation == loadGeneration else { return }
            withMeFailed = true
        }
        do {
            let byMe = try await client.listDocuments(isCreatorMe: true, ordering: "-updated_at").results
            guard generation == loadGeneration else { return }
            sharedByMe = byMe
            cache.saveSharedByMeDocuments(byMe)
        } catch {
            guard generation == loadGeneration else { return }
            byMeFailed = true
        }
        isOffline = withMeFailed || byMeFailed
        // Loud when a *failing* scope has no cached list to fall back on
        // (a never-fetched list must not masquerade as a real empty result),
        // or on an explicit pull-to-refresh.
        if withMeFailed || byMeFailed,
           userInitiated || (withMeFailed && !hadWithMeCache) || (byMeFailed && !hadByMeCache) {
            errorMessage = "Could not load shared documents. Check your connection and try again."
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
}
