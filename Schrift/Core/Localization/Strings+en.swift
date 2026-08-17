import Foundation

/// The English string table — the source of truth every other language's
/// table is generated from and falls back to (see `Strings.table(for:)`).
enum Strings_en {
    static let table: [L10nKey: String] = [
        .common_cancel: "Cancel",
        .common_close: "Close",
        .common_untitled: "Untitled document",
        .common_profile: "Profile",
        .common_clear_search: "Clear search",
        .common_you: "(you)",
        .common_loading: "Loading",
        .search_results_one: "%d result",
        .search_results_other: "%d results",

        // Offline banner (common chrome)
        .offline_status: "Offline",
        .offline_note: "All documents saved on this device",

        // Home
        .home_title: "Schrift",
        .home_search_placeholder: "Search %@",
        .home_search_documents: "Search documents",
        .home_section_pinned: "Pinned",
        .home_section_recent: "Recent",
        .home_results: "Results",
        .home_empty_title: "No documents yet",
        .home_empty_body: "Documents you create or that are shared with you will appear here.",
        .home_newdoc: "New doc",
        .home_dismiss_error: "Dismiss error",
        .home_select_document: "Select a Document",
        .home_error_load: "Couldn't load documents. Pull to refresh to try again.",
        .home_error_search: "Search failed. Please try again.",
        .home_error_create: "Couldn't create a document. Please try again.",

        // Search
        .search_title: "Search",
        .search_placeholder: "Search all documents",
        .search_recent: "Recent searches",
        .search_quick: "Quick access",
        .search_quick_empty: "Pinned documents will appear here.",
        .search_empty_title: "No documents found",
        .search_empty_body: "Nothing matches \u{201C}%@\u{201D}. Try another title or keyword.",
        .search_error_quick: "Couldn't load quick access. Please try again.",
        .search_error_search: "Search failed. Please try again.",

        // Shared
        .shared_title: "Shared",
        .shared_count_one: "%d document",
        .shared_count_other: "%d documents",
        .shared_subtitle_with: "Shared · %@",
        .shared_subtitle_shared_by: "Shared by %@ · %@",
        .shared_footer_with:
            "Documents other people have invited you to. Your access depends on your role on each one.",
        .shared_error_load: "Could not load shared documents. Check your connection and try again.",
        .reach_restricted: "Restricted",
        .reach_connected: "Connected",
        .reach_public: "Public",

        // DocRow (design-system component)
        .docrow_pinned: "Pinned",
        .docrow_shared_with_organization: "Shared with organization",
        .docrow_public: "Public",
        .docrow_available_offline: "Available offline",
        .docrow_pending_delete: "Waiting to be deleted",
        .pending_delete_alert_message: "This document will be deleted the next time it can reach the server.",
        .pending_delete_undo: "Keep this document",
        .docrow_on_this_device: "On this device, waiting to sync",

        // LinkReachPill hints (design-system component; labels reuse reach.*)
        .linkreach_hint_restricted: "Only invited people",
        .linkreach_hint_authenticated: "Anyone in the org",
        .linkreach_hint_public: "Anyone with the link",

        // ShareMemberRow (design-system component)
        .sharemember_role_a11y: "Role: %@",
        .sharemember_role_hint: "Double tap to change role",

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
        .options_delete_document: "Delete document",
        .options_delete_confirm_title: "Delete this document?",
        .options_delete_confirm_subpages: "Subpages saved on this device will be deleted with it.",
        .options_delete: "Delete",
        .options_error_toggle_favorite: "Couldn't update favorite. Please try again.",
        .options_error_delete: "Couldn't delete document. Please try again.",
        .options_move: "Move",
        .move_title: "Move to",
        .move_home: "Top level",
        .move_destinations: "Documents",
        .move_empty: "No destinations available.",
        .move_error: "Couldn't move document. Please try again.",
        .move_error_load: "Couldn't load destinations. Please try again.",

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

        // Editor - save bar
        .editor_save: "Save",
        .editor_save_now_a11y: "Save now",
        .editor_saving: "Saving…",
        .editor_saved: "Saved",
        .editor_save_failed: "Couldn't save · Retry",
        .editor_save_failed_a11y: "Save failed. Retry",

        // Editor - reading surface / chrome
        .editor_offline_local_copy: "Working on the copy saved on this device",
        .editor_update_available: "Document updated · tap to refresh",
        .editor_update_available_a11y: "Document updated. Tap to refresh.",
        .editor_uploading_photo: "Uploading photo…",
        .editor_attachment_pending: "Waiting to upload",
        .editor_attachment_pending_a11y: "Photo waiting to upload",
        .editor_attachment_failed: "Couldn't upload this photo.",
        .editor_attachment_missing: "This photo is no longer on this device.",
        .editor_attachment_unattributable:
            "This photo will appear once this device knows which account you're signed in to.",
        .editor_attachment_retry: "Retry",
        .editor_attachment_remove: "Remove",
        .editor_uploading_photo_a11y: "Uploading photo",
        .editor_empty_title: "Empty document",
        .editor_empty_body: "This document doesn't have any content yet.",
        .editor_start_writing: "Start writing",
        .editor_subpages_title: "Subpages",
        .editor_subpages_title_count: "Subpages · %d",
        .editor_subpages_empty: "Organize this document by creating subpages.",
        .editor_add_subpage: "Add a subpage",
        .editor_action_done: "Done",
        .editor_action_edit: "Edit",
        .editor_action_share: "Share",
        .editor_action_options: "Options",

        // Editor - sync caption (reading-surface header)
        .editor_sync_save_failed: "Couldn't save · tap to retry",
        .editor_sync_save_failed_a11y: "Couldn't save. Tap to retry.",
        .editor_sync_saved_on_device: "Saved on this device",
        .editor_sync_pending_sync: "Saved on this device · syncs when online",
        .editor_sync_edited_just_now: "Edited just now",
        .editor_sync_just_now: "Synced just now",
        .editor_sync_ago: "Synced %@",
        .editor_sync_not_synced_yet: "Not synced yet",
        .editor_conflict_pill: "Sync conflict · tap to review",
        .editor_conflict_pill_a11y: "Sync conflict. Tap to review.",
        .editor_conflict_title: "Sync conflict",
        .editor_conflict_body:
            "This document changed elsewhere while your edits were waiting to sync. Choose which version to keep.",
        .editor_conflict_server_changed: "The server copy changed %@.",
        .editor_conflict_keep_mine: "Keep my version",
        .editor_conflict_keep_mine_detail: "Overwrites the server copy",
        .editor_conflict_keep_server: "Keep the server version",
        .editor_conflict_keep_server_detail: "Discards the changes on this device",
        .editor_conflict_restore_hint: "Overwritten versions can be restored from version history on the web.",

        // Editor - errors
        .editor_pending_delete: "This document is waiting to be deleted.",
        .editor_error_load: "Couldn't load this document. Pull to refresh to try again.",
        .editor_error_refresh: "Couldn't refresh. Please try again.",
        .editor_error_add_subpage: "Couldn't add the subpage. Please try again.",
        .editor_error_open_link: "Couldn't open that link. Please try again.",
        .editor_error_add_photo: "Couldn't add the photo. Please try again.",
        .editor_unavailable: "This document is no longer available.",
        .editor_unavailable_with_draft:
            "This document is no longer available. Your unsaved changes are kept on this device.",

        // Editor - slash menu (display labels; matching/filtering uses the
        // stable English `SlashMenuItem.title`, never these keys)
        .editor_slash_menu_a11y: "Block type menu",
        .editor_slash_text: "Text",
        .editor_slash_heading1: "Heading 1",
        .editor_slash_heading2: "Heading 2",
        .editor_slash_heading3: "Heading 3",
        .editor_slash_bulleted_list: "Bulleted list",
        .editor_slash_numbered_list: "Numbered list",
        .editor_slash_checklist: "Checklist",
        .editor_slash_quote: "Quote",
        .editor_slash_code_block: "Code block",
        .editor_slash_divider: "Divider",
        .editor_slash_photo: "Photo",

        // Editor - formatting bar (icon-only buttons; accessibility labels)
        .editor_format_add_block: "Add block",
        .editor_format_bold: "Bold",
        .editor_format_italic: "Italic",
        .editor_format_link: "Link",
        .editor_format_bulleted_list: "Bulleted list",
        .editor_format_checklist: "Checklist",
        .editor_format_quote: "Quote",
        .editor_format_code_block: "Code block",
        .editor_format_insert_photo: "Insert photo",

        // Editor - link editor sheet
        .editor_link_add_title: "Add link",
        .editor_link_edit_title: "Edit link",
        .editor_link_text_label: "Text",
        .editor_link_text_placeholder: "Link text",
        .editor_link_text_helper: "Leave empty to show the address itself.",
        .editor_link_address_label: "Address",
        .editor_link_address_placeholder: "example.com/page",
        .editor_link_address_error: "That address can't be used as a link.",
        .editor_link_remove: "Remove link",
        .editor_link_save: "Save",
        .editor_link_add: "Add",

        // Editor - version history
        .versions_title: "Version history",
        .versions_current: "Current version",
        .versions_restore_web: "Restore on the web",
        .versions_error: "Couldn't load versions. Please try again.",
        .versions_empty: "No earlier versions yet.",

        // Editor - inline image (MarkdownImageView): accessibility labels plus the
        // visible off-origin tap-to-load caption
        .editor_image_a11y: "Image",
        .editor_image_loading_a11y: "Loading image",
        .editor_image_loading_named_a11y: "Loading image: %@",
        .editor_image_external: "External image · tap to load",
        .editor_image_external_a11y: "External image from %@. Tap to load.",
        .editor_attachment_downloading: "Downloading…",
        .editor_attachment_failed_retry: "Couldn't download · Tap to retry",
        .editor_attachment_offline: "Available when online",
        .editor_attachment_a11y: "Attachment: %@. %@",
        .editor_attachment_not_previewable: "Can’t be previewed here",
        .editor_error_add_file: "Couldn't add the file. Please try again.",
        .editor_error_file_too_large: "That file is too large to add.",
        .editor_slash_file: "File",
        .editor_uploading_file: "Uploading file…",
        .editor_uploading_file_a11y: "Uploading file",

        // Editor - block canvas accessibility labels (BlockEditorView)
        .editor_add_paragraph_a11y: "Add paragraph at end",
        .editor_divider_a11y: "Divider",
        .editor_checklist_done_a11y: "Mark as done",
        .editor_checklist_not_done_a11y: "Mark as not done",
        .editor_checklist_state_done_a11y: "Done",
        .editor_checklist_state_not_done_a11y: "Not done",
        .editor_presence_count_one: "%d person here",
        .editor_presence_count_other: "%d people here",

        // Profile
        .profile_title: "Profile",
        .profile_user: "User",
        .profile_prefs: "Preferences",
        .profile_prefs_footer:
            "When on, documents you've opened stay available to read and edit on this device without a connection.",
        .profile_appearance: "Appearance",
        .profile_language: "Language",
        .profile_notifications: "Notifications",
        .profile_work_offline: "Work offline",
        .profile_live_collaboration: "Live collaboration",
        .profile_live_collaboration_footer:
            "Live collaboration syncs your edits with others in real time when your server supports it.",
        .profile_server: "Server",
        .profile_server_footer: "The app connects to any Schrift server using your existing web session.",
        .profile_connected: "Connected",
        .profile_offline: "Offline",
        .profile_server_version: "Server version",
        .profile_about: "About",
        .profile_version: "Version",
        .profile_sign_out: "Sign out",
        .profile_disconnect_title: "Disconnect from %@?",
        .profile_disconnect: "Disconnect",
        .profile_disconnect_body: "You'll need to sign in again to reconnect.",

        // Appearance picker
        .appearance_system: "System",
        .appearance_light: "Light",
        .appearance_dark: "Dark",
        // Account screen
        .account_title: "Account",
        .account_section_profile: "Profile",
        .account_full_name: "Full name",
        .account_section_signin: "Sign-in",
        .account_signin_footer:
            "You're signed in with your web session. Schrift connects using your browser cookie and never stores your password.",
        .account_email: "Email",
        .account_manage_on_web: "Manage account on the web",
        .account_unavailable_title: "Account unavailable",
        .account_unavailable_body:
            "Your account details couldn't be loaded. Check your connection and try again.",
        // Pages tree drawer
        .pages_title: "Pages",
        .pages_open: "Show pages",
        .pages_close: "Close pages",
        .pages_expand: "Expand",
        .pages_collapse: "Collapse",
        .pages_new: "New page",
        .pages_empty: "No subpages yet. Add one to organize this document.",
        .pages_error_load: "Couldn't load the pages. Please try again.",
        .pages_error_create: "Couldn't add the page. Please try again.",
        .account_language_footer:
            "The language your server uses for emails and shared content. The app's own language is in Preferences.",
        // Toast
        .toast_link_copied: "Link copied",
    ]
}
