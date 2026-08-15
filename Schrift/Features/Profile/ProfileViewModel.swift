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
        // **Before the fetch, not after it.** This runs again whenever the session changes
        // (`ProfileScreen` keys its `.task` on `SessionStore.signInGeneration`), and by then
        // the in-memory user can belong to the account that just went away — this view model
        // is `@State` in `MainTabView`, which the re-login sheet is presented *over*, so it
        // outlives the session it loaded for. Waiting for the fetch to settle would keep that
        // account's email in the row — and its detail screen one tap away — for a whole round
        // trip, or a ~60s timeout if connectivity died right after the re-login. The store is
        // the session-scoped answer: `SessionStore.signIn` clears it. On an ordinary visit it
        // holds what is already on screen, so this is a no-op.
        user = cachedUser.user
        // Tolerate failure on either fetch: no error banner, and — the offline rule the list
        // screens already follow — keep the local copy rather than blanking the row. Only a
        // successful fetch may replace it.
        async let fetchedUser = try? client.currentUser()
        async let fetchedVersion = try? client.serverConfig().version
        let freshUser = await fetchedUser
        // Nothing learned under the previous session may be written after it ends. A
        // `.task(id:)` restart cancels this load, but cancellation is cooperative and the
        // response may already be in hand — so without this guard the cancelled load resumes
        // and writes the *old* account back into both stores, undoing the clear that
        // `signIn` just made. That would re-arm `SignedInUserStore` in particular, which
        // gates whose unsynced documents may be listed and replayed.
        guard !Task.isCancelled else { return }
        if let freshUser, freshUser.carriesAccountDetail {
            user = freshUser
            cachedUser.remember(freshUser)
        } else {
            // The store again, deliberately, and not the in-memory copy: at launch it is the
            // *fresher* of the two, since `MainTabView.init` builds this view model before
            // RootView's task runs the `/users/me/` that first fills the cache.
            user = cachedUser.user
        }
        // Keep the persisted account id fresh from the one screen that fetches the user on
        // every visit. Offline document creation cannot mint or list a record without it, and
        // this is a free refresh on a fetch the screen already makes. Deliberately the
        // *fetched* user, never the cached one: that store gates what may be listed and sent
        // for another account's unsynced documents, and only a live `/users/me/` is evidence
        // of whose session this is. Kept beside the user write, before the second await, so
        // there is one cancellation window here rather than two.
        signedInUser.remember(freshUser?.id)
        // The version row hides itself when nil, so there is nothing to preserve and a stale
        // version number is worth less than an absent one — it describes the *server*, which
        // may well have been upgraded since.
        let freshVersion = await fetchedVersion
        guard !Task.isCancelled else { return }
        serverVersion = freshVersion
    }
}
