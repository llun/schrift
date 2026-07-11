import Foundation

/// A CLDR plural category. Most languages in `AppLanguage` only distinguish
/// `one` vs `other`; Slovene additionally uses `two` (the dual) and `few`.
/// No supported language needs `zero`/`many`.
enum PluralCategory {
    case one
    case two
    case few
    case other
}

/// CLDR plural rules, simplified to the categories the supported languages use:
/// - zh-Hans/zh-Hant/th have a single form (`other`);
/// - Slovene uses the full `one`/`two`/`few`/`other` set, including the dual;
/// - every other language uses `one`/`other`.
func pluralCategory(_ count: Int, language: AppLanguage) -> PluralCategory {
    switch language {
    case .chineseSimplified, .chineseTraditional, .thai:
        return .other
    case .slovene:
        // CLDR `sl` (integers, v = 0): one = i%100==1, two = i%100==2,
        // few = i%100==3..4, other = everything else.
        switch abs(count) % 100 {
        case 1: return .one
        case 2: return .two
        case 3, 4: return .few
        default: return .other
        }
    default:
        return count == 1 ? .one : .other
    }
}
