import Foundation

/// The English string table — the source of truth every other language's
/// table is generated from and falls back to (see `Strings.table(for:)`).
enum Strings_en {
    static let table: [L10nKey: String] = [
        .common_done: "Done",
        .common_cancel: "Cancel",
        .common_retry: "Try again",
        .common_untitled: "Untitled document",
        .search_results_one: "%d result",
        .search_results_other: "%d results",

        // Home
        .home_title: "Schrift",
        .home_search_placeholder: "Search %@",
        .home_search_documents: "Search documents",
        .home_filter_all: "All",
        .home_filter_shared: "Shared",
        .home_filter_pinned: "Pinned",
        .home_section_pinned: "Pinned",
        .home_section_recent: "Recent",
        .home_section_shared: "Shared with me",
        .home_results: "Results",
        .home_empty_title: "No documents yet",
        .home_empty_body: "Documents you create or that are shared with you will appear here.",
        .home_newdoc: "New doc",
        .home_pin: "Pin",
        .home_unpin: "Unpin",
        .home_dismiss_error: "Dismiss error",
        .home_document_options: "Document Options",

        // Search
        .search_title: "Search",
        .search_placeholder: "Search all documents",
        .search_recent: "Recent searches",
        .search_quick: "Quick access",
        .search_quick_empty: "Pinned documents will appear here.",
        .search_empty_title: "No documents found",
        .search_empty_body: "Nothing matches \u{201C}%@\u{201D}. Try another title or keyword.",

        // Shared
        .shared_title: "Shared",
        .shared_with_me: "Shared with me",
        .shared_by_me: "Shared by me",
        .shared_count_one: "%d document",
        .shared_count_other: "%d documents",
        .shared_subtitle_with: "Shared · %@",
        .shared_subtitle_by: "%@ · Shared %@",
        .shared_footer_with:
            "Documents other people have invited you to. Your access depends on your role on each one.",
        .shared_footer_by:
            "Documents you own or have shared. Manage who can see them from each document’s share sheet.",
        .reach_restricted: "Restricted",
        .reach_connected: "Connected",
        .reach_public: "Public",
    ]
}
