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
    /// A network load is in flight. Whether that shows as a placeholder is a
    /// per-scope decision — see `showsLoadingPlaceholder`.
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
    /// Scopes with a real local result (cached or fetched this session).
    /// An unknown scope must never render as "0 documents" — nil ≠ empty.
    /// Stored (not derived from the cache on demand) so SwiftUI re-renders
    /// when knowledge changes and cache reads stay out of view evaluation.
    private var knownScopes: Set<Scope> = []

    init(
        client: DocsAPIClient,
        cache: DocumentCacheStore = DocumentCacheStore(),
        userDefaults: UserDefaults = .standard
    ) {
        self.client = client
        self.cache = cache
        self.userDefaults = userDefaults
        if let withMe = cache.loadSharedWithMeDocuments() {
            sharedWithMe = withMe
            knownScopes.insert(.withMe)
        }
        if let byMe = cache.loadSharedByMeDocuments() {
            sharedByMe = byMe
            knownScopes.insert(.byMe)
        }
    }

    var documents: [Document] {
        scope == .withMe ? sharedWithMe : sharedByMe
    }

    /// Per-scope spinner gate: only while fetching a scope that has no local
    /// list yet. A cached (even empty) scope revalidates silently; switching
    /// segments mid-fetch re-evaluates for the newly visible scope.
    var showsLoadingPlaceholder: Bool {
        isLoading && !knownScopes.contains(scope) && documents.isEmpty
    }

    /// Whether the visible scope may render its list (and "N documents"
    /// header). False only for a scope that is unknown — never fetched and
    /// never cached — where a "0 documents" claim would be a lie; the offline
    /// banner or error footnote conveys the state instead.
    var showsDocumentList: Bool {
        knownScopes.contains(scope) || !documents.isEmpty
    }

    func load(userInitiated: Bool = false) async {
        errorMessage = nil
        loadGeneration += 1
        let generation = loadGeneration

        // "Work offline" preference (Profile > Preferences): serve cached
        // documents and never hit the network.
        if userDefaults.bool(forKey: "schrift.workOffline") {
            if let withMe = cache.loadSharedWithMeDocuments() {
                sharedWithMe = withMe
                knownScopes.insert(.withMe)
            }
            if let byMe = cache.loadSharedByMeDocuments() {
                sharedByMe = byMe
                knownScopes.insert(.byMe)
            }
            isOffline = true
            isLoading = false
            return
        }

        // Cache existence is read per scope: both the spinner (via
        // knownScopes) and the silent-vs-loud policy are keyed to the exact
        // list in question (nil = never cached ≠ cached empty), so one
        // scope's cache never silences or masks the other's first-ever state.
        let hadWithMeCache = knownScopes.contains(.withMe)
        let hadByMeCache = knownScopes.contains(.byMe)
        isLoading = true

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
            knownScopes.insert(.withMe)
        } catch {
            guard generation == loadGeneration else { return }
            withMeFailed = true
        }
        do {
            let byMe = try await client.listDocuments(isCreatorMe: true, ordering: "-updated_at").results
            guard generation == loadGeneration else { return }
            sharedByMe = byMe
            cache.saveSharedByMeDocuments(byMe)
            knownScopes.insert(.byMe)
        } catch {
            guard generation == loadGeneration else { return }
            byMeFailed = true
        }
        isOffline = withMeFailed || byMeFailed
        // Loud when a *failing* scope has no cached list to fall back on
        // (a never-fetched list must not masquerade as a real empty result),
        // or on an explicit pull-to-refresh.
        if withMeFailed || byMeFailed,
            userInitiated || (withMeFailed && !hadWithMeCache) || (byMeFailed && !hadByMeCache)
        {
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
