import Foundation

@MainActor
@Observable
final class SearchViewModel {
    var query: String = ""
    var results: [Document] = []
    var quickAccess: [Document] = []
    var recentSearches: [String] = []
    var isSearching = false
    var errorMessage: String?

    let client: DocsAPIClient
    private let store: RecentSearchesStore

    init(client: DocsAPIClient, store: RecentSearchesStore = RecentSearchesStore()) {
        self.client = client
        self.store = store
        recentSearches = store.searches
    }

    func loadQuickAccess() async {
        do {
            let page = try await client.favoriteDocuments()
            quickAccess = page.results
        } catch {
            errorMessage = "Couldn't load quick access. Please try again."
        }
    }

    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            return
        }
        // Debounce: when the query changes, the enclosing `.task(id:)` cancels
        // this task, so a newer keystroke supersedes an in-flight search and
        // stale results never overwrite fresh ones.
        try? await Task.sleep(nanoseconds: 250_000_000)
        if Task.isCancelled { return }

        isSearching = true
        errorMessage = nil
        do {
            let page = try await client.searchDocuments(query: trimmed)
            if Task.isCancelled { return }
            results = page.results
        } catch {
            if Task.isCancelled { return }
            errorMessage = "Search failed. Please try again."
        }
        isSearching = false
    }

    func recordSearch() {
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
