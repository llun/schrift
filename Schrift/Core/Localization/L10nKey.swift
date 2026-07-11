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
    case common_profile = "common.profile"  // "Profile"
    case common_clear_search = "common.clear_search"  // "Clear search"
    case common_you = "common.you"  // "(you)" — suffix after the current user's name
    // Search results plural
    case search_results_one = "search.results.one"  // "%d result"
    case search_results_other = "search.results.other"  // "%d results"

    // Offline banner (common chrome)
    case offline_status = "offline.status"  // "Offline"
    case offline_note = "offline.note"  // "All documents saved on this device"

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
    case home_select_document = "home.select_document"  // "Select a Document"
    case home_error_load = "home.error.load"  // "Couldn't load documents. Pull to refresh to try again."
    case home_error_search = "home.error.search"  // "Search failed. Please try again."
    case home_error_create = "home.error.create"  // "Couldn't create a document. Please try again."
    case home_error_favorite = "home.error.favorite"  // "Couldn't update favorite. Please try again."

    // Search
    case search_title = "search.title"  // "Search"
    case search_placeholder = "search.placeholder"  // "Search all documents"
    case search_recent = "search.recent"  // "Recent searches"
    case search_quick = "search.quick"  // "Quick access"
    case search_quick_empty = "search.quick_empty"  // "Pinned documents will appear here."
    case search_empty_title = "search.empty.title"  // "No documents found"
    case search_empty_body = "search.empty.body"  // "Nothing matches \u{201C}%@\u{201D}. Try another title or keyword."
    case search_error_quick = "search.error.quick"  // "Couldn't load quick access. Please try again."
    case search_error_search = "search.error.search"  // "Search failed. Please try again."

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
    case shared_error_load = "shared.error.load"
    // "Could not load shared documents. Check your connection and try again."
    case reach_restricted = "reach.restricted"  // "Restricted"
    case reach_connected = "reach.connected"  // "Connected"
    case reach_public = "reach.public"  // "Public"

    // DocRow (design-system component)
    case docrow_pinned = "docrow.pinned"  // "Pinned"
    case docrow_shared_with_organization = "docrow.shared_with_organization"  // "Shared with organization"
    case docrow_public = "docrow.public"  // "Public"
    case docrow_more_options = "docrow.more_options"  // "More options"
    case docrow_available_offline = "docrow.available_offline"  // "Available offline"

    // LinkReachPill hints (design-system component; labels reuse reach.*)
    case linkreach_hint_restricted = "linkreach.hint.restricted"  // "Only invited people"
    case linkreach_hint_authenticated = "linkreach.hint.authenticated"  // "Anyone in the org"
    case linkreach_hint_public = "linkreach.hint.public"  // "Anyone with the link"

    // ShareMemberRow (design-system component)
    case sharemember_role_a11y = "sharemember.role_a11y"  // "Role: %@"
    case sharemember_role_hint = "sharemember.role_hint"  // "Double tap to change role"

    // Connect
    case connect_hero_title = "connect.hero_title"  // "Welcome to Schrift"
    case connect_hero_subtitle = "connect.hero_subtitle"
    // "Connect to any server to write, organize and collaborate — in real time."
    case connect_server_label = "connect.server_label"  // "Server"
    case connect_server_placeholder = "connect.server_placeholder"  // "schrift.example.org"
    case connect_server_helper = "connect.server_helper"
    // "The app signs in with your existing session — no password stored."
    case connect_sign_in = "connect.sign_in"  // "Sign in"
    case connect_sign_in_to = "connect.sign_in_to"  // "Sign in to %@"
    case connect_recent_servers = "connect.recent_servers"  // "Recent servers"
    case connect_error_invalid_server = "connect.error.invalid_server"  // "Enter a valid server address."
    case connect_error_sign_in_failed = "connect.error.sign_in_failed"
    // "Sign-in could not be confirmed. Please try again."

    // Reauthentication
    case reauth_title = "reauth.title"  // "Session expired"
    case reauth_error_sign_in_failed = "reauth.error.sign_in_failed"
    // "Sign-in could not be confirmed. Please try again."

    // Options sheet
    case options_title = "options.title"  // "Options"
    case options_pin = "options.pin"  // "Pin"
    case options_unpin = "options.unpin"  // "Unpin"
    case options_pinned = "options.pinned"  // "Pinned"
    case options_copy_link = "options.copy_link"  // "Copy link"
    case options_share = "options.share"  // "Share"
    case options_copy_markdown = "options.copy_markdown"  // "Copy as Markdown"
    case options_duplicate = "options.duplicate"  // "Duplicate"
    case options_delete_document = "options.delete_document"  // "Delete document"
    case options_delete_confirm_title = "options.delete_confirm_title"  // "Delete this document?"
    case options_delete = "options.delete"  // "Delete"
    case options_error_toggle_favorite = "options.error.toggle_favorite"
    // "Couldn't update favorite. Please try again."
    case options_error_duplicate = "options.error.duplicate"  // "Couldn't duplicate document. Please try again."
    case options_error_delete = "options.error.delete"  // "Couldn't delete document. Please try again."

    // Share sheet
    case share_title = "share.title"  // "Share"
    case share_invite_placeholder = "share.invite_placeholder"  // "Invite by name or email"
    case share_members_one = "share.members.one"  // "Shared with %d person"
    case share_members_other = "share.members.other"  // "Shared with %d people"
    case share_add_people = "share.add_people"  // "Add people"
    case share_no_people_found = "share.no_people_found"  // "No people found"
    case share_link_parameters = "share.link_parameters"  // "Link parameters"
    case share_change_link_access = "share.change_link_access"  // "Change link access"
    case share_copy_link = "share.copy_link"  // "Copy link"
    case share_change_role = "share.change_role"  // "Change Role"
    case share_remove = "share.remove"  // "Remove"
    case share_link_access = "share.link_access"  // "Link Access"
    case share_reach_authenticated = "share.reach.authenticated"  // "Anyone in the organization"
    case share_reach_public = "share.reach.public"  // "Anyone with the link"
    case share_role_reader = "share.role.reader"  // "Reader"
    case share_role_commenter = "share.role.commenter"  // "Commenter"
    case share_role_editor = "share.role.editor"  // "Editor"
    case share_role_administrator = "share.role.administrator"  // "Administrator"
    case share_role_owner = "share.role.owner"  // "Owner"
    case share_role_pending = "share.role.pending"  // "%@ (Pending)"
    case share_error_load = "share.error.load"  // "Couldn't load members. Pull to refresh to try again."
    case share_error_search = "share.error.search"  // "Search failed. Please try again."
    case share_error_invite = "share.error.invite"  // "Couldn't add member. Please try again."
    case share_error_update_role = "share.error.update_role"  // "Couldn't update role. Please try again."
    case share_error_remove_member = "share.error.remove_member"  // "Couldn't remove member. Please try again."
    case share_error_update_link = "share.error.update_link"  // "Couldn't update link settings. Please try again."

    // Editor - save bar
    case editor_save = "editor.save"  // "Save"
    case editor_save_now_a11y = "editor.save_now_a11y"  // "Save now"
    case editor_saving = "editor.saving"  // "Saving…"
    case editor_saved = "editor.saved"  // "Saved"
    case editor_save_failed = "editor.save_failed"  // "Couldn't save · Retry"
    case editor_save_failed_a11y = "editor.save_failed_a11y"  // "Save failed. Retry"

    // Editor - reading surface / chrome
    case editor_offline_local_copy = "editor.offline_local_copy"  // "Reading the copy saved on this device"
    case editor_update_available = "editor.update_available"  // "Document updated · tap to refresh"
    case editor_update_available_a11y = "editor.update_available_a11y"  // "Document updated. Tap to refresh."
    case editor_uploading_photo = "editor.uploading_photo"  // "Uploading photo…"
    case editor_uploading_photo_a11y = "editor.uploading_photo_a11y"  // "Uploading photo"
    case editor_empty_title = "editor.empty_title"  // "Empty document"
    case editor_empty_body = "editor.empty_body"  // "This document doesn't have any content yet."
    case editor_start_writing = "editor.start_writing"  // "Start writing"
    case editor_subpages_title = "editor.subpages_title"  // "Subpages"
    case editor_subpages_title_count = "editor.subpages_title_count"  // "Subpages · %d"
    case editor_subpages_empty = "editor.subpages_empty"  // "Organize this document by creating subpages."
    case editor_add_subpage = "editor.add_subpage"  // "Add a subpage"
    case editor_action_done = "editor.action.done"  // "Done"
    case editor_action_pages = "editor.action.pages"  // "Pages"
    case editor_action_share = "editor.action.share"  // "Share"
    case editor_action_options = "editor.action.options"  // "Options"

    // Editor - sync caption (reading-surface header)
    case editor_sync_save_failed = "editor.sync.save_failed"  // "Couldn't save · tap to retry"
    case editor_sync_save_failed_a11y = "editor.sync.save_failed_a11y"  // "Couldn't save. Tap to retry."
    case editor_sync_saved_on_device = "editor.sync.saved_on_device"  // "Saved on this device"
    case editor_sync_edited_just_now = "editor.sync.edited_just_now"  // "Edited just now"
    case editor_sync_just_now = "editor.sync.just_now"  // "Synced just now"
    case editor_sync_ago = "editor.sync.ago"  // "Synced %@"
    case editor_sync_not_synced_yet = "editor.sync.not_synced_yet"  // "Not synced yet"

    // Editor - errors
    case editor_error_load = "editor.error.load"  // "Couldn't load this document. Pull to refresh to try again."
    case editor_error_refresh = "editor.error.refresh"  // "Couldn't refresh. Please try again."
    case editor_error_add_subpage = "editor.error.add_subpage"  // "Couldn't add the subpage. Please try again."
    case editor_error_open_link = "editor.error.open_link"  // "Couldn't open that link. Please try again."
    case editor_error_add_photo = "editor.error.add_photo"  // "Couldn't add the photo. Please try again."
    case editor_unavailable = "editor.unavailable"  // "This document is no longer available."
    case editor_unavailable_with_draft = "editor.unavailable_with_draft"
    // "This document is no longer available. Your unsaved changes are kept on this device."

    // Editor - slash menu (display labels; matching/filtering uses the
    // stable English `SlashMenuItem.title`, never these keys — see SlashMenu.swift)
    case editor_slash_menu_a11y = "editor.slash.menu_a11y"  // "Block type menu"
    case editor_slash_text = "editor.slash.text"  // "Text"
    case editor_slash_heading1 = "editor.slash.heading1"  // "Heading 1"
    case editor_slash_heading2 = "editor.slash.heading2"  // "Heading 2"
    case editor_slash_heading3 = "editor.slash.heading3"  // "Heading 3"
    case editor_slash_bulleted_list = "editor.slash.bulleted_list"  // "Bulleted list"
    case editor_slash_numbered_list = "editor.slash.numbered_list"  // "Numbered list"
    case editor_slash_checklist = "editor.slash.checklist"  // "Checklist"
    case editor_slash_quote = "editor.slash.quote"  // "Quote"
    case editor_slash_code_block = "editor.slash.code_block"  // "Code block"
    case editor_slash_divider = "editor.slash.divider"  // "Divider"
    case editor_slash_photo = "editor.slash.photo"  // "Photo"

    // Editor - formatting bar (icon-only buttons; accessibility labels)
    case editor_format_add_block = "editor.format.add_block"  // "Add block"
    case editor_format_bold = "editor.format.bold"  // "Bold"
    case editor_format_italic = "editor.format.italic"  // "Italic"
    case editor_format_link = "editor.format.link"  // "Link"
    case editor_format_bulleted_list = "editor.format.bulleted_list"  // "Bulleted list"
    case editor_format_checklist = "editor.format.checklist"  // "Checklist"
    case editor_format_quote = "editor.format.quote"  // "Quote"
    case editor_format_code_block = "editor.format.code_block"  // "Code block"
    case editor_format_insert_photo = "editor.format.insert_photo"  // "Insert photo"

    // Editor - link editor sheet
    case editor_link_add_title = "editor.link.add_title"  // "Add link"
    case editor_link_edit_title = "editor.link.edit_title"  // "Edit link"
    case editor_link_text_label = "editor.link.text_label"  // "Text"
    case editor_link_text_placeholder = "editor.link.text_placeholder"  // "Link text"
    case editor_link_text_helper = "editor.link.text_helper"  // "Leave empty to show the address itself."
    case editor_link_address_label = "editor.link.address_label"  // "Address"
    case editor_link_address_placeholder = "editor.link.address_placeholder"  // "example.com/page"
    case editor_link_address_error = "editor.link.address_error"  // "That address can't be used as a link."
    case editor_link_remove = "editor.link.remove"  // "Remove link"
    case editor_link_save = "editor.link.save"  // "Save"
    case editor_link_add = "editor.link.add"  // "Add"

    // Editor - document tree panel (DocTreePanel)
    case editor_tree_pages = "editor.tree.pages"  // "Pages"
    case editor_tree_close = "editor.tree.close"  // "Close pages"
    case editor_tree_empty = "editor.tree.empty"  // "No subpages yet. Add one to organize this document."
    case editor_tree_new_page = "editor.tree.new_page"  // "New page"

    // Editor - inline image (MarkdownImageView; accessibility labels only —
    // the image alt text is document content and is never localized)
    case editor_image_a11y = "editor.image.a11y"  // "Image"
    case editor_image_loading_a11y = "editor.image.loading_a11y"  // "Loading image"
    case editor_image_loading_named_a11y = "editor.image.loading_named_a11y"  // "Loading image: %@"

    // Editor - block canvas accessibility labels (BlockEditorView)
    case editor_add_paragraph_a11y = "editor.add_paragraph_a11y"  // "Add paragraph at end"
    case editor_divider_a11y = "editor.divider_a11y"  // "Divider"
    case editor_checklist_done_a11y = "editor.checklist.done_a11y"  // "Mark as done"
    case editor_checklist_not_done_a11y = "editor.checklist.not_done_a11y"  // "Mark as not done"

    // Profile
    case profile_title = "profile.title"  // "Profile"
    case profile_user = "profile.user"  // "User"
    case profile_prefs = "profile.prefs"  // "Preferences"
    case profile_prefs_footer = "profile.prefs_footer"
    // "When on, documents you've opened stay readable on this device without a connection."
    case profile_appearance = "profile.appearance"  // "Appearance"
    case profile_language = "profile.language"  // "Language"
    case profile_notifications = "profile.notifications"  // "Notifications"
    case profile_work_offline = "profile.work_offline"  // "Work offline"
    case profile_server = "profile.server"  // "Server"
    case profile_server_footer = "profile.server_footer"
    // "The app connects to any Schrift server using your existing web session."
    case profile_connected = "profile.connected"  // "Connected"
    case profile_offline = "profile.offline"  // "Offline"
    case profile_server_version = "profile.server_version"  // "Server version"
    case profile_about = "profile.about"  // "About"
    case profile_version = "profile.version"  // "Version"
    case profile_sign_out = "profile.sign_out"  // "Sign out"
    case profile_disconnect_title = "profile.disconnect_title"  // "Disconnect from %@?"
    case profile_disconnect = "profile.disconnect"  // "Disconnect"
    case profile_disconnect_body = "profile.disconnect_body"  // "You'll need to sign in again to reconnect."

    // Appearance picker (values shared by the Profile row and the sheet)
    case appearance_system = "appearance.system"  // "System"
    case appearance_light = "appearance.light"  // "Light"
    case appearance_dark = "appearance.dark"  // "Dark"
    // (screen-specific keys are added by B9, B11, Phase C, Phase F)
}
