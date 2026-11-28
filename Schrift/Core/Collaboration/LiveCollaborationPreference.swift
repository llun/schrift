import Foundation

/// The app-UI toggle for live collaboration — **on by default**. Its only writer is the
/// Profile switch (Profile → Preferences → "Live collaboration", an
/// `@AppStorage(LiveCollaborationPreference.key)` binding in `ProfileScreen`). Read
/// through here so the `schrift.`-prefixed key has a single source. An absent key means
/// on; a user who turned it off keeps it off (the stored `false` wins over the default).
enum LiveCollaborationPreference {
    static let key = "schrift.liveCollaboration"
    /// What an install that never touched the switch gets. Registered in
    /// `UserDefaults.standard` at launch so `@AppStorage` reads it too.
    static let defaultValue = true

    static func registerDefault(in userDefaults: UserDefaults = .standard) {
        userDefaults.register(defaults: [key: defaultValue])
    }

    static func isEnabled(_ userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.object(forKey: key) as? Bool ?? defaultValue
    }
}
