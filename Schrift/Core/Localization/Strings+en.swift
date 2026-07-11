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
    ]
}
