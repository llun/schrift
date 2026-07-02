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

    let client: DocsAPIClient
    let saveCoordinator: DocumentSaveCoordinator
    private let cache: DocumentCacheStore

    init(client: DocsAPIClient, cache: DocumentCacheStore = DocumentCacheStore(), saveCoordinator: DocumentSaveCoordinator? = nil) {
        self.client = client
        self.cache = cache
        self.saveCoordinator = saveCoordinator ?? DocumentSaveCoordinator(client: client)
        pinnedDocuments = cache.loadPinnedDocuments()
        recentDocuments = cache.loadRecentDocuments()
    }

    var showsPinnedSection: Bool {
        shouldShowPinnedSection(filter: selectedFilter, pinnedCount: pinnedDocuments.count)
    }

    func load() async {
        isLoading = true
        errorMessage = nil

        // "Work offline" preference (Profile > Preferences): serve cached
        // documents and never hit the network.
        if UserDefaults.standard.bool(forKey: "schrift.workOffline") {
            pinnedDocuments = cache.loadPinnedDocuments()
            recentDocuments = cache.loadRecentDocuments()
            isOffline = true
            isLoading = false
            return
        }
        isOffline = false

        // Replay any drafts stranded by a previous session (runs once).
        let coordinator = saveCoordinator
        Task { await coordinator.recoverDrafts() }

        let params = homeFilterQueryParameters(selectedFilter)
        do {
            async let pinnedPage = client.favoriteDocuments()
            async let recentPage = client.listDocuments(
                isFavorite: params.isFavorite,
                isCreatorMe: params.isCreatorMe,
                ordering: "-updated_at"
            )
            pinnedDocuments = try await pinnedPage.results
            recentDocuments = try await recentPage.results
            cache.savePinnedDocuments(pinnedDocuments)
            if selectedFilter == .all {
                cache.saveRecentDocuments(recentDocuments)
            }
        } catch {
            errorMessage = "Couldn't load documents. Pull to refresh to try again."
            isOffline = true
        }

        isLoading = false
    }

    func selectFilter(_ filter: HomeFilter) async {
        selectedFilter = filter
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
            if UserDefaults.standard.bool(forKey: "schrift.workOffline") {
                // load() skips the network in work-offline mode, so reflect the
                // new document directly rather than serving stale cache.
                recentDocuments.insert(document, at: 0)
                cache.saveRecentDocuments(recentDocuments)
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
