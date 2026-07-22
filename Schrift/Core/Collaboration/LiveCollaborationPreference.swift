import Foundation

/// The app-UI toggle for live collaboration — **opt-in, off by default**. Its only
/// writer is the C3 Profile switch (Profile → Preferences → "Live collaboration",
/// an `@AppStorage(LiveCollaborationPreference.key)` binding in `ProfileScreen`).
/// Read through here so the `schrift.`-prefixed key has a single source (matching
/// `AppearanceStore`/`LocalizationStore`, which use `schrift.appearance` /
/// `schrift.language`). `UserDefaults.bool(forKey:)` already returns `false` for an
/// unset key, so the default is free.
enum LiveCollaborationPreference {
    static let key = "schrift.liveCollaboration"

    static func isEnabled(_ userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: key)
    }
}
