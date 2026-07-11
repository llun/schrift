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
    ]
}
