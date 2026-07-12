import SwiftUI

@main
struct SchriftApp: App {
    @State private var appearanceStore = AppearanceStore()
    @State private var localizationStore = LocalizationStore()
    @State private var connectivity = ConnectivityMonitor()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appearanceStore)
                .preferredColorScheme(appearanceStore.selected.colorScheme)
                .environment(localizationStore)
                .environment(\.locale, localizationStore.locale)
                .environment(connectivity)
        }
    }
}
