import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english, french, spanish, german, italian, dutch, portuguese, slovene, thai
    case chineseSimplified, chineseTraditional

    var id: String { rawValue }

    var code: String {
        switch self {
        case .english: "en"
        case .french: "fr"
        case .spanish: "es"
        case .german: "de"
        case .italian: "it"
        case .dutch: "nl"
        case .portuguese: "pt"
        case .slovene: "sl"
        case .thai: "th"
        case .chineseSimplified: "zh-Hans"
        case .chineseTraditional: "zh-Hant"
        }
    }

    /// The language's own name, shown in the picker.
    var autonym: String {
        switch self {
        case .english: "English"
        case .french: "Français"
        case .spanish: "Español"
        case .german: "Deutsch"
        case .italian: "Italiano"
        case .dutch: "Nederlands"
        case .portuguese: "Português"
        case .slovene: "Slovenščina"
        case .thai: "ไทย"
        case .chineseSimplified: "简体中文"
        case .chineseTraditional: "繁體中文"
        }
    }

    var locale: Locale { Locale(identifier: code) }

    /// First-launch default: exact code, then script (zh-Hans/zh-Hant), then base
    /// language, else English.
    static func bestMatch(preferred: [String]) -> AppLanguage {
        for tag in preferred {
            let lower = tag.lowercased()
            if lower.hasPrefix("zh") {
                if lower.contains("hant") || lower.contains("-tw") || lower.contains("-hk") || lower.contains("-mo") {
                    return .chineseTraditional
                }
                return .chineseSimplified
            }
            let base = String(lower.prefix(2))
            if let match = allCases.first(where: { $0.code == base }) { return match }
        }
        return .english
    }
}
