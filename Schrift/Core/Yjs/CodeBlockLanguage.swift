import Foundation

/// A code block's `language` prop: 1–64 characters, no whitespace, control characters or
/// inline-object placeholders. Shared by the engine's prop rule and the native editor's fence
/// shortcut, which lives on the main actor and so cannot name the engine.
func isValidCodeBlockLanguage(_ language: String) -> Bool {
    (1...64).contains(language.count)
        && !language.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
                || $0.value == 0xfffc
        }
}
