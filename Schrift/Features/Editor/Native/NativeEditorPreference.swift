import Foundation

/// On by default. Read again when a document opens or reopens, never swap a
/// focused editor live. An absent key means on; only an explicit off keeps the
/// classic editor.
enum NativeEditorPreference {
    static let key = "schrift.nativeEditor"
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

/// Separate opt-in for in-memory diagnostics collection and hot-path counters.
/// Off by default; only surfaced when `NativeEditorPreference` is enabled.
enum NativeEditorDiagnosticsPreference {
    static let key = "schrift.nativeEditor.diagnostics"

    static func isEnabled(_ userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: key)
    }
}
