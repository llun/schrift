import Foundation

// AI-generated translation — pending native-speaker review.
enum Strings_de {
    static let table: [L10nKey: String] = [
        .common_cancel: "Abbrechen",
        .common_close: "Schließen",
        .common_retry: "Erneut versuchen",
        .common_untitled: "Unbenanntes Dokument",
        .common_profile: "Profil",
        .common_clear_search: "Suche löschen",
        .common_you: "(du)",
        .search_results_one: "%d Ergebnis",
        .search_results_other: "%d Ergebnisse",

        // Offline banner (common chrome)
        .offline_status: "Offline",
        .offline_note: "Alle Dokumente auf diesem Gerät gespeichert",

        // Home
        .home_title: "Schrift",
        .home_search_placeholder: "%@ durchsuchen",
        .home_search_documents: "Dokumente durchsuchen",
        .home_section_pinned: "Angeheftet",
        .home_section_recent: "Zuletzt",
        .home_results: "Ergebnisse",
        .home_empty_title: "Noch keine Dokumente",
        .home_empty_body: "Dokumente, die du erstellst oder die mit dir geteilt werden, werden hier angezeigt.",
        .home_newdoc: "Neues Dokument",
        .home_dismiss_error: "Fehler ausblenden",
        .home_select_document: "Dokument auswählen",
        .home_error_load: "Dokumente konnten nicht geladen werden. Zum Aktualisieren nach unten ziehen.",
        .home_error_search: "Suche fehlgeschlagen. Bitte versuche es erneut.",
        .home_error_create: "Dokument konnte nicht erstellt werden. Bitte versuche es erneut.",

        // Search
        .search_title: "Suche",
        .search_placeholder: "Alle Dokumente durchsuchen",
        .search_recent: "Letzte Suchen",
        .search_quick: "Schnellzugriff",
        .search_quick_empty: "Angeheftete Dokumente werden hier angezeigt.",
        .search_empty_title: "Keine Dokumente gefunden",
        .search_empty_body:
            "Nichts entspricht \u{201C}%@\u{201D}. Versuche einen anderen Titel oder ein anderes Stichwort.",
        .search_error_quick: "Schnellzugriff konnte nicht geladen werden. Bitte versuche es erneut.",
        .search_error_search: "Suche fehlgeschlagen. Bitte versuche es erneut.",

        // Shared
        .shared_title: "Geteilt",
        .shared_with_me: "Mit mir geteilt",
        .shared_by_me: "Von mir geteilt",
        .shared_count_one: "%d Dokument",
        .shared_count_other: "%d Dokumente",
        .shared_subtitle_with: "Geteilt · %@",
        .shared_subtitle_shared_by: "Geteilt von %@ · %@",
        .shared_subtitle_by: "%@ · Geteilt %@",
        .shared_footer_with:
            "Dokumente, zu denen andere dich eingeladen haben. Dein Zugriff hängt von deiner Rolle bei jedem einzelnen ab.",
        .shared_footer_by:
            "Dokumente, die dir gehören oder die du geteilt hast. Verwalte im Freigabemenü des jeweiligen Dokuments, wer sie sehen kann.",
        .shared_error_load:
            "Geteilte Dokumente konnten nicht geladen werden. Überprüfe deine Verbindung und versuche es erneut.",
        .reach_restricted: "Eingeschränkt",
        .reach_connected: "Verbunden",
        .reach_public: "Öffentlich",

        // DocRow (design-system component)
        .docrow_pinned: "Angeheftet",
        .docrow_shared_with_organization: "Mit der Organisation geteilt",
        .docrow_public: "Öffentlich",
        .docrow_available_offline: "Offline verfügbar",

        // LinkReachPill hints (design-system component; labels reuse reach.*)
        .linkreach_hint_restricted: "Nur eingeladene Personen",
        .linkreach_hint_authenticated: "Alle in der Organisation",
        .linkreach_hint_public: "Alle mit dem Link",

        // ShareMemberRow (design-system component)
        .sharemember_role_a11y: "Rolle: %@",
        .sharemember_role_hint: "Doppeltippen, um die Rolle zu ändern",

        // Connect
        .connect_hero_title: "Willkommen bei Schrift",
        .connect_hero_subtitle:
            "Verbinde dich mit einem beliebigen Server, um zu schreiben, zu organisieren und zusammenzuarbeiten — in Echtzeit.",
        .connect_server_label: "Server",
        .connect_server_placeholder: "schrift.example.org",
        .connect_server_helper:
            "Die App meldet sich mit deiner bestehenden Sitzung an — es wird kein Passwort gespeichert.",
        .connect_sign_in: "Anmelden",
        .connect_sign_in_to: "Bei %@ anmelden",
        .connect_recent_servers: "Letzte Server",
        .connect_error_invalid_server: "Gib eine gültige Serveradresse ein.",
        .connect_error_sign_in_failed: "Die Anmeldung konnte nicht bestätigt werden. Bitte versuche es erneut.",

        // Reauthentication
        .reauth_title: "Sitzung abgelaufen",
        .reauth_error_sign_in_failed: "Die Anmeldung konnte nicht bestätigt werden. Bitte versuche es erneut.",

        // Options sheet
        .options_title: "Optionen",
        .options_pin: "Anheften",
        .options_unpin: "Nicht mehr anheften",
        .options_pinned: "Angeheftet",
        .options_copy_link: "Link kopieren",
        .options_share: "Teilen",
        .options_delete_document: "Dokument löschen",
        .options_delete_confirm_title: "Dieses Dokument löschen?",
        .options_delete: "Löschen",
        .options_error_toggle_favorite: "Favorit konnte nicht aktualisiert werden. Bitte versuche es erneut.",
        .options_error_delete: "Dokument konnte nicht gelöscht werden. Bitte versuche es erneut.",

        // Share sheet
        .share_title: "Teilen",
        .share_invite_placeholder: "Per Name oder E-Mail einladen",
        .share_members_one: "Mit %d Person geteilt",
        .share_members_other: "Mit %d Personen geteilt",
        .share_add_people: "Personen hinzufügen",
        .share_no_people_found: "Keine Personen gefunden",
        .share_link_parameters: "Linkparameter",
        .share_change_link_access: "Link-Zugriff ändern",
        .share_copy_link: "Link kopieren",
        .share_change_role: "Rolle ändern",
        .share_remove: "Entfernen",
        .share_link_access: "Link-Zugriff",
        .share_reach_authenticated: "Alle in der Organisation",
        .share_reach_public: "Alle mit dem Link",
        .share_role_reader: "Leser",
        .share_role_commenter: "Kommentator",
        .share_role_editor: "Bearbeiter",
        .share_role_administrator: "Administrator",
        .share_role_owner: "Eigentümer",
        .share_role_pending: "%@ (Ausstehend)",
        .share_error_load: "Mitglieder konnten nicht geladen werden. Zum Aktualisieren nach unten ziehen.",
        .share_error_search: "Suche fehlgeschlagen. Bitte versuche es erneut.",
        .share_error_invite: "Mitglied konnte nicht hinzugefügt werden. Bitte versuche es erneut.",
        .share_error_update_role: "Rolle konnte nicht aktualisiert werden. Bitte versuche es erneut.",
        .share_error_remove_member: "Mitglied konnte nicht entfernt werden. Bitte versuche es erneut.",
        .share_error_update_link: "Linkeinstellungen konnten nicht aktualisiert werden. Bitte versuche es erneut.",

        // Editor - save bar
        .editor_save: "Speichern",
        .editor_save_now_a11y: "Jetzt speichern",
        .editor_saving: "Wird gespeichert…",
        .editor_saved: "Gespeichert",
        .editor_save_failed: "Speichern fehlgeschlagen · Erneut versuchen",
        .editor_save_failed_a11y: "Speichern fehlgeschlagen. Erneut versuchen",

        // Editor - reading surface / chrome
        .editor_offline_local_copy: "Du siehst die auf diesem Gerät gespeicherte Kopie",
        .editor_update_available: "Dokument aktualisiert · zum Aktualisieren tippen",
        .editor_update_available_a11y: "Dokument aktualisiert. Zum Aktualisieren tippen.",
        .editor_uploading_photo: "Foto wird hochgeladen…",
        .editor_uploading_photo_a11y: "Foto wird hochgeladen",
        .editor_empty_title: "Leeres Dokument",
        .editor_empty_body: "Dieses Dokument hat noch keinen Inhalt.",
        .editor_start_writing: "Schreiben beginnen",
        .editor_subpages_title: "Unterseiten",
        .editor_subpages_title_count: "Unterseiten · %d",
        .editor_subpages_empty: "Organisiere dieses Dokument, indem du Unterseiten erstellst.",
        .editor_add_subpage: "Unterseite hinzufügen",
        .editor_action_done: "Fertig",
        .editor_action_edit: "Bearbeiten",
        .editor_action_share: "Teilen",
        .editor_action_options: "Optionen",

        // Editor - sync caption (reading-surface header)
        .editor_sync_save_failed: "Speichern fehlgeschlagen · zum Wiederholen tippen",
        .editor_sync_save_failed_a11y: "Speichern fehlgeschlagen. Zum Wiederholen tippen.",
        .editor_sync_saved_on_device: "Auf diesem Gerät gespeichert",
        .editor_sync_edited_just_now: "Gerade eben bearbeitet",
        .editor_sync_just_now: "Gerade eben synchronisiert",
        .editor_sync_ago: "Synchronisiert %@",
        .editor_sync_not_synced_yet: "Noch nicht synchronisiert",

        // Editor - errors
        .editor_error_load: "Dieses Dokument konnte nicht geladen werden. Zum Aktualisieren nach unten ziehen.",
        .editor_error_refresh: "Aktualisierung fehlgeschlagen. Bitte versuche es erneut.",
        .editor_error_add_subpage: "Unterseite konnte nicht hinzugefügt werden. Bitte versuche es erneut.",
        .editor_error_open_link: "Der Link konnte nicht geöffnet werden. Bitte versuche es erneut.",
        .editor_error_add_photo: "Foto konnte nicht hinzugefügt werden. Bitte versuche es erneut.",
        .editor_unavailable: "Dieses Dokument ist nicht mehr verfügbar.",
        .editor_unavailable_with_draft:
            "Dieses Dokument ist nicht mehr verfügbar. Deine ungespeicherten Änderungen bleiben auf diesem Gerät erhalten.",

        // Editor - slash menu (display labels; matching/filtering uses the
        // stable English `SlashMenuItem.title`, never these keys)
        .editor_slash_menu_a11y: "Blocktyp-Menü",
        .editor_slash_text: "Text",
        .editor_slash_heading1: "Überschrift 1",
        .editor_slash_heading2: "Überschrift 2",
        .editor_slash_heading3: "Überschrift 3",
        .editor_slash_bulleted_list: "Aufzählungsliste",
        .editor_slash_numbered_list: "Nummerierte Liste",
        .editor_slash_checklist: "Checkliste",
        .editor_slash_quote: "Zitat",
        .editor_slash_code_block: "Codeblock",
        .editor_slash_divider: "Trennlinie",
        .editor_slash_photo: "Foto",

        // Editor - formatting bar (icon-only buttons; accessibility labels)
        .editor_format_add_block: "Block hinzufügen",
        .editor_format_bold: "Fett",
        .editor_format_italic: "Kursiv",
        .editor_format_link: "Link",
        .editor_format_bulleted_list: "Aufzählungsliste",
        .editor_format_checklist: "Checkliste",
        .editor_format_quote: "Zitat",
        .editor_format_code_block: "Codeblock",
        .editor_format_insert_photo: "Foto einfügen",

        // Editor - link editor sheet
        .editor_link_add_title: "Link hinzufügen",
        .editor_link_edit_title: "Link bearbeiten",
        .editor_link_text_label: "Text",
        .editor_link_text_placeholder: "Linktext",
        .editor_link_text_helper: "Leer lassen, um die Adresse selbst anzuzeigen.",
        .editor_link_address_label: "Adresse",
        .editor_link_address_placeholder: "example.com/page",
        .editor_link_address_error: "Diese Adresse kann nicht als Link verwendet werden.",
        .editor_link_remove: "Link entfernen",
        .editor_link_save: "Speichern",
        .editor_link_add: "Hinzufügen",

        // Editor - version history
        .versions_title: "Versionsverlauf",
        .versions_current: "Aktuelle Version",
        .versions_restore_web: "Im Web wiederherstellen",
        .versions_error: "Versionen konnten nicht geladen werden. Bitte versuche es erneut.",
        .versions_empty: "Noch keine früheren Versionen.",

        // Editor - inline image (MarkdownImageView; accessibility labels only)
        .editor_image_a11y: "Bild",
        .editor_image_loading_a11y: "Bild wird geladen",
        .editor_image_loading_named_a11y: "Bild wird geladen: %@",

        // Editor - block canvas accessibility labels (BlockEditorView)
        .editor_add_paragraph_a11y: "Absatz am Ende hinzufügen",
        .editor_divider_a11y: "Trennlinie",
        .editor_checklist_done_a11y: "Als erledigt markieren",
        .editor_checklist_not_done_a11y: "Als nicht erledigt markieren",

        // Profile
        .profile_title: "Profil",
        .profile_user: "Benutzer",
        .profile_prefs: "Einstellungen",
        .profile_prefs_footer:
            "Wenn aktiviert, bleiben von Ihnen geöffnete Dokumente auf diesem Gerät auch ohne Verbindung lesbar.",
        .profile_appearance: "Erscheinungsbild",
        .profile_language: "Sprache",
        .profile_notifications: "Benachrichtigungen",
        .profile_work_offline: "Offline arbeiten",
        .profile_server: "Server",
        .profile_server_footer: "Die App verbindet sich mit jedem Schrift-Server über Ihre bestehende Web-Sitzung.",
        .profile_connected: "Verbunden",
        .profile_offline: "Offline",
        .profile_server_version: "Serverversion",
        .profile_about: "Info",
        .profile_version: "Version",
        .profile_sign_out: "Abmelden",
        .profile_disconnect_title: "Verbindung zu %@ trennen?",
        .profile_disconnect: "Trennen",
        .profile_disconnect_body: "Sie müssen sich erneut anmelden, um die Verbindung wiederherzustellen.",

        // Appearance picker
        .appearance_system: "System",
        .appearance_light: "Hell",
        .appearance_dark: "Dunkel",
    ]
}
