import Foundation

/// The app-UI toggle for live collaboration — off by default until a Profile
/// switch lands (a later roadmap PR). Read through here so the `schrift.`-prefixed
/// key has a single source (matching `AppearanceStore`/`LocalizationStore`, which
/// use `schrift.appearance` / `schrift.language`). `UserDefaults.bool(forKey:)`
/// already returns `false` for an unset key, so the default is free.
enum LiveCollaborationPreference {
    static let key = "schrift.liveCollaboration"

    static func isEnabled(_ userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: key)
    }
}
