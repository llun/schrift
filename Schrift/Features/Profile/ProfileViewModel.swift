import Foundation

@MainActor
@Observable
final class ProfileViewModel {
    var user: CurrentUser?
    var serverVersion: String?
    var isLoading = false

    let client: DocsAPIClient
    private let signedInUser: SignedInUserStore
    private let cachedUser: CurrentUserCacheStore

    init(
        client: DocsAPIClient,
        signedInUser: SignedInUserStore = SignedInUserStore(),
        cachedUser: CurrentUserCacheStore = CurrentUserCacheStore()
    ) {
        self.client = client
        self.signedInUser = signedInUser
        self.cachedUser = cachedUser
        // Seed **synchronously**, like the document lists seed from their metadata caches:
        // the screen renders `user` in its `body` and only then runs `.task`, so anything
        // awaited is a frame too late to be the sole source and the row would show its "—"
        // placeholder first. Offline that placeholder was the permanent state.
        self.user = cachedUser.user
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        // Tolerate failure on either fetch: no error banner, and — the offline rule the list
        // screens already follow — keep whatever local copy is on screen rather than blanking
        // it. Only a successful fetch may replace the user, so a failed one leaves the cached
        // account showing instead of reverting the row to "—".
        async let fetchedUser = try? client.currentUser()
        async let fetchedVersion = try? client.serverConfig().version
        let freshUser = await fetchedUser
        if let freshUser, freshUser.carriesAccountDetail {
            user = freshUser
            cachedUser.remember(freshUser)
        } else {
            // Re-read the store rather than keeping what is already on screen. This view model
            // is `@State` in `MainTabView`, which is **not** rebuilt across a re-login — the
            // sheet is presented over it while `isAuthenticated` stays true — so the in-memory
            // copy can belong to the account that just went away, and keeping it would display
            // one user's email inside another's session. The store is cleared by
            // `SessionStore.signIn`, so it is the session-scoped answer. It is also the
            // *fresher* one at launch: `MainTabView.init` builds this before RootView's task
            // runs the `/users/me/` that first fills the cache.
            user = cachedUser.user
        }
        // The version row hides itself when nil, so there is nothing to preserve and a stale
        // version number is worth less than an absent one — it describes the *server*, which
        // may well have been upgraded since.
        serverVersion = await fetchedVersion
        // Keep the persisted account id fresh from the one screen that fetches the user on
        // every visit. Offline document creation cannot mint or list a record without it, and
        // this is a free refresh on a fetch the screen already makes. Deliberately the
        // *fetched* user, never the cached one: that store gates what may be listed and sent
        // for another account's unsynced documents, and only a live `/users/me/` is evidence
        // of whose session this is.
        signedInUser.remember(freshUser?.id)
    }
}
