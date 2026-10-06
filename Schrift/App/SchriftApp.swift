import SwiftUI

@main
struct SchriftApp: App {
    @State private var appearanceStore = AppearanceStore()
    @State private var themeStore = ThemeStore()
    @State private var localizationStore = LocalizationStore()
    @State private var connectivity = ConnectivityMonitor()

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
