import Foundation

/// Experimental and opt-in. Capture once when a document opens, never while a
/// focused editor is on screen. Existing installations have no stored key.
enum NativeEditorPreference {
    static let key = "schrift.nativeEditor"

    static func isEnabled(_ userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: key)
    }
}
