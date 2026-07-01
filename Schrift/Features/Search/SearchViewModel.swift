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
        isSearching = true
        errorMessage = nil
        do {
            let page = try await client.searchDocuments(query: trimmed)
            results = page.results
        } catch {
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
