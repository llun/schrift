import SwiftUI

@main
struct SchriftApp: App {
    @State private var appearanceStore = AppearanceStore()

    var body: some Scene {
        WindowGroup {
            // LocalizationStore injection is added in Task B4 — do not add it
            // here yet.
            RootView()
                .environment(appearanceStore)
                .preferredColorScheme(appearanceStore.selected.colorScheme)
        }
    }
}
