import Foundation

/// Dispatches to the string table for a given language.
enum Strings {
    static func table(for language: AppLanguage) -> [L10nKey: String] {
        switch language {
        case .english: Strings_en.table
        default: Strings_en.table  // replaced by real tables in Task B12
        }
    }
}

/// Owns the app's current language, persists it, and resolves `L10nKey`s
/// against the current language's table (falling back to English for any
/// key a language's table doesn't cover).
@MainActor
@Observable
final class LocalizationStore {
    var language: AppLanguage { didSet { userDefaults.set(language.code, forKey: Self.key) } }
    private let userDefaults: UserDefaults
    private static let key = "schrift.language"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let code = userDefaults.string(forKey: Self.key),
            let saved = AppLanguage.allCases.first(where: { $0.code == code })
        {
            language = saved
        } else {
            language = AppLanguage.bestMatch(preferred: Locale.preferredLanguages)
        }
    }

    subscript(_ key: L10nKey) -> String {
        Strings.table(for: language)[key] ?? Strings_en.table[key] ?? key.rawValue
    }

    func format(_ key: L10nKey, _ args: CVarArg...) -> String {
        String(format: self[key], locale: locale, arguments: args)
    }

    /// Resolves the correct plural form for `count` in the current language
    /// (see `pluralCategory(_:language:)`) and substitutes it into the
    /// matching key's format string.
    func plural(_ count: Int, one: L10nKey, other: L10nKey) -> String {
        let key = pluralCategory(count, language: language) == .one ? one : other
        return String(format: self[key], locale: locale, arguments: [count])
    }

    var locale: Locale { language.locale }
}
