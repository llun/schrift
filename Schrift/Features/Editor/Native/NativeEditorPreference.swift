import Foundation

/// Experimental and opt-in. Read again when a document opens or reopens, never
/// swap a focused editor live. Existing installations have no stored key.
enum NativeEditorPreference {
    static let key = "schrift.nativeEditor"

    static func isEnabled(_ userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: key)
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
