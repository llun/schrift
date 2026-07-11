import Foundation

/// A key into the app's localized string tables (`Strings_en`, …). Raw values
/// are stable, human-readable identifiers (never shown to users) that double
/// as documentation of which screen/purpose each string serves.
enum L10nKey: String, CaseIterable, Sendable {
    // Common
    case common_done = "common.done"
    case common_cancel = "common.cancel"
    case common_retry = "common.retry"
    case common_untitled = "common.untitled_document"
    // Search results plural
    case search_results_one = "search.results.one"  // "%d result"
    case search_results_other = "search.results.other"  // "%d results"
    // (screen-specific keys are added by B5–B11, Phase C, Phase F)
}
