import Foundation

/// Experimental and opt-in. Read again when a document opens or reopens, never
/// swap a focused editor live. Existing installations have no stored key.
enum NativeEditorPreference {
    static let key = "schrift.nativeEditor"

    static func isEnabled(_ userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: key)
    }
}
