import Foundation

/// A CLDR plural category. This app only distinguishes `one` vs `other` —
/// no language in `AppLanguage` needs `zero`/`two`/`few`/`many`.
enum PluralCategory {
    case one
    case other
}

/// CLDR-simplified: zh-Hans/zh-Hant/th have a single form; the rest use one/other.
func pluralCategory(_ count: Int, language: AppLanguage) -> PluralCategory {
    switch language {
    case .chineseSimplified, .chineseTraditional, .thai: return .other
    default: return count == 1 ? .one : .other
    }
}
