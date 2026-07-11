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

        // Connect
        .connect_hero_title: "Welcome to Schrift",
        .connect_hero_subtitle: "Connect to any server to write, organize and collaborate — in real time.",
        .connect_server_label: "Server",
        .connect_server_placeholder: "schrift.example.org",
        .connect_server_helper: "The app signs in with your existing session — no password stored.",
        .connect_sign_in: "Sign in",
        .connect_sign_in_to: "Sign in to %@",
        .connect_recent_servers: "Recent servers",
        .connect_error_invalid_server: "Enter a valid server address.",
        .connect_error_sign_in_failed: "Sign-in could not be confirmed. Please try again.",

        // Reauthentication
        .reauth_title: "Session expired",
        .reauth_error_sign_in_failed: "Sign-in could not be confirmed. Please try again.",

        // Options sheet
        .options_title: "Options",
        .options_pin: "Pin",
        .options_unpin: "Unpin",
        .options_pinned: "Pinned",
        .options_copy_link: "Copy link",
        .options_share: "Share",
        .options_copy_markdown: "Copy as Markdown",
        .options_duplicate: "Duplicate",
        .options_delete_document: "Delete document",
        .options_delete_confirm_title: "Delete this document?",
        .options_delete: "Delete",
        .options_error_toggle_favorite: "Couldn't update favorite. Please try again.",
        .options_error_duplicate: "Couldn't duplicate document. Please try again.",
        .options_error_delete: "Couldn't delete document. Please try again.",

        // Share sheet
        .share_title: "Share",
        .share_invite_placeholder: "Invite by name or email",
        .share_members_one: "Shared with %d person",
        .share_members_other: "Shared with %d people",
        .share_add_people: "Add people",
        .share_no_people_found: "No people found",
        .share_link_parameters: "Link parameters",
        .share_change_link_access: "Change link access",
        .share_copy_link: "Copy link",
        .share_change_role: "Change Role",
        .share_remove: "Remove",
        .share_link_access: "Link Access",
        .share_reach_authenticated: "Anyone in the organization",
        .share_reach_public: "Anyone with the link",
        .share_role_reader: "Reader",
        .share_role_commenter: "Commenter",
        .share_role_editor: "Editor",
        .share_role_administrator: "Administrator",
        .share_role_owner: "Owner",
        .share_role_pending: "%@ (Pending)",
        .share_error_load: "Couldn't load members. Pull to refresh to try again.",
        .share_error_search: "Search failed. Please try again.",
        .share_error_invite: "Couldn't add member. Please try again.",
        .share_error_update_role: "Couldn't update role. Please try again.",
        .share_error_remove_member: "Couldn't remove member. Please try again.",
        .share_error_update_link: "Couldn't update link settings. Please try again.",
    ]
}
