import Foundation

@MainActor
@Observable
final class SearchViewModel {
    var query: String = ""
    var results: [Document] = []
    var quickAccess: [Document] = []
    var recentSearches: [String] = []
    var isSearching = false
    var errorKey: L10nKey?

    let client: DocsAPIClient
    private let store: RecentSearchesStore
    /// Optional: nil simply means "no queued deletions to annotate here", which is what every
    /// existing call site and `#Preview` gets.
    private let saveCoordinator: DocumentSaveCoordinator?
    private let signedInUser: SignedInUserStore

    init(
        client: DocsAPIClient, store: RecentSearchesStore = RecentSearchesStore(),
        saveCoordinator: DocumentSaveCoordinator? = nil,
        signedInUser: SignedInUserStore = SignedInUserStore()
    ) {
        self.client = client
        self.store = store
        self.saveCoordinator = saveCoordinator
        self.signedInUser = signedInUser
        recentSearches = store.searches
    }

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
        do {
            let page = try await client.favoriteDocuments()
            quickAccess = page.results
        } catch {
            errorKey = .search_error_quick
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
        errorKey = nil
        do {
            let page = try await client.searchDocuments(query: trimmed)
            if Task.isCancelled { return }
            results = page.results
        } catch {
            if Task.isCancelled { return }
            errorKey = .search_error_search
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
