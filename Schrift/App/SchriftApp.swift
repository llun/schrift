import SwiftUI

@main
struct SchriftApp: App {
    @State private var appearanceStore = AppearanceStore()
    @State private var themeStore = ThemeStore()
    @State private var localizationStore = LocalizationStore()
    @State private var connectivity = ConnectivityMonitor()

    init() {
        // Before any reader: the native editor is on unless the user turned it off.
        NativeEditorPreference.registerDefault()
        NativeMediaDropPaste.removeStagingRoot()
        // Responses earlier builds cached through `URLSession.shared` (not account-scoped).
        URLCache.shared.removeAllCachedResponses()
        // Every launch, not only after the upgrade: the login web view caches pages on each sign-in,
        // and a cold login page costs nothing outside one. Its cookies stay.
        clearWebLoginCache()
        // Before any sign-in can name an account: work and bodies from earlier builds carry no
        // account, so they go to the one signed in now, and nobody's when none is known.
        PendingDraftStore().assignOwnersToEarlierDrafts()
        DocumentContentCacheStore.moveEarlierBodiesIntoAccountFolder()
        // Signed out at launch: nobody's login may linger in the web view, including one an
        // earlier build left at its sign-out (it kept those cookies) or an abandoned sign-in.
        if SessionStore.hasNoSignInMarker() {
            clearWebLoginSiteData(includingCookies: true)
            HTTPCookieStorage.shared.removeCookies(since: .distantPast)  // the login's copies
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appearanceStore)
                .environment(themeStore)
                .environment(\.docsTheme, themeStore.selected)
                .tint(themeStore.selected.colors.textBrand)
                .preferredColorScheme(appearanceStore.selected.colorScheme)
                .environment(localizationStore)
                .environment(\.locale, localizationStore.locale)
                .environment(connectivity)
        }
    }
}
