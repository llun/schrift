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

    // Home
    case home_title = "home.title"  // "Schrift"
    case home_search_placeholder = "home.search_placeholder"  // "Search %@"
    case home_search_documents = "home.search_documents"  // "Search documents"
    case home_filter_all = "home.filter.all"  // "All"
    case home_filter_shared = "home.filter.shared"  // "Shared"
    case home_filter_pinned = "home.filter.pinned"  // "Pinned"
    case home_section_pinned = "home.section.pinned"  // "Pinned"
    case home_section_recent = "home.section.recent"  // "Recent"
    case home_section_shared = "home.section.shared"  // "Shared with me"
    case home_results = "home.results"  // "Results"
    case home_empty_title = "home.empty.title"  // "No documents yet"
    case home_empty_body = "home.empty.body"  // "Documents you create or that are shared with you will appear here."
    case home_newdoc = "home.new_document"  // "New doc"
    case home_pin = "home.pin"  // "Pin"
    case home_unpin = "home.unpin"  // "Unpin"
    case home_dismiss_error = "home.dismiss_error"  // "Dismiss error"
    case home_document_options = "home.document_options"  // "Document Options"
    // (screen-specific keys are added by B6–B11, Phase C, Phase F)
}
