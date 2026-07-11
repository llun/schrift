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

    // Search
    case search_title = "search.title"  // "Search"
    case search_placeholder = "search.placeholder"  // "Search all documents"
    case search_recent = "search.recent"  // "Recent searches"
    case search_quick = "search.quick"  // "Quick access"
    case search_quick_empty = "search.quick_empty"  // "Pinned documents will appear here."
    case search_empty_title = "search.empty.title"  // "No documents found"
    case search_empty_body = "search.empty.body"  // "Nothing matches \u{201C}%@\u{201D}. Try another title or keyword."

    // Shared
    case shared_title = "shared.title"  // "Shared"
    case shared_with_me = "shared.with_me"  // "Shared with me"
    case shared_by_me = "shared.by_me"  // "Shared by me"
    case shared_count_one = "shared.count.one"  // "%d document"
    case shared_count_other = "shared.count.other"  // "%d documents"
    case shared_subtitle_with = "shared.subtitle_with"  // "Shared · %@"
    case shared_subtitle_by = "shared.subtitle_by"  // "%@ · Shared %@"
    case shared_footer_with = "shared.footer_with"
    // "Documents other people have invited you to. Your access depends on your role on each one."
    case shared_footer_by = "shared.footer_by"
    // "Documents you own or have shared. Manage who can see them from each document’s share sheet."
    case reach_restricted = "reach.restricted"  // "Restricted"
    case reach_connected = "reach.connected"  // "Connected"
    case reach_public = "reach.public"  // "Public"
    // (screen-specific keys are added by B8–B11, Phase C, Phase F)
}
