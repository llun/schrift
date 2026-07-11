import Foundation

// AI-generated translation — pending native-speaker review.
enum Strings_nl {
    static let table: [L10nKey: String] = [
        .common_done: "Gereed",
        .common_cancel: "Annuleren",
        .common_retry: "Opnieuw proberen",
        .common_untitled: "Naamloos document",
        .common_profile: "Profiel",
        .common_clear_search: "Zoekopdracht wissen",
        .common_you: "(jij)",
        .search_results_one: "%d resultaat",
        .search_results_other: "%d resultaten",

        // Offline banner (common chrome)
        .offline_status: "Offline",
        .offline_note: "Alle documenten opgeslagen op dit apparaat",

        // Home
        .home_title: "Schrift",
        .home_search_placeholder: "Zoek %@",
        .home_search_documents: "Documenten zoeken",
        .home_filter_all: "Alle",
        .home_filter_shared: "Gedeeld",
        .home_filter_pinned: "Vastgezet",
        .home_section_pinned: "Vastgezet",
        .home_section_recent: "Recent",
        .home_section_shared: "Met mij gedeeld",
        .home_results: "Resultaten",
        .home_empty_title: "Nog geen documenten",
        .home_empty_body: "Documenten die je maakt of die met jou worden gedeeld, verschijnen hier.",
        .home_newdoc: "Nieuw document",
        .home_pin: "Vastzetten",
        .home_unpin: "Losmaken",
        .home_dismiss_error: "Foutmelding sluiten",
        .home_document_options: "Documentopties",
        .home_select_document: "Selecteer een document",
        .home_error_load: "Kan documenten niet laden. Trek omlaag om het opnieuw te proberen.",
        .home_error_search: "Zoeken mislukt. Probeer het opnieuw.",
        .home_error_create: "Kan geen document maken. Probeer het opnieuw.",
        .home_error_favorite: "Kan favoriet niet bijwerken. Probeer het opnieuw.",

        // Search
        .search_title: "Zoeken",
        .search_placeholder: "Zoek in alle documenten",
        .search_recent: "Recente zoekopdrachten",
        .search_quick: "Snelle toegang",
        .search_quick_empty: "Vastgezette documenten verschijnen hier.",
        .search_empty_title: "Geen documenten gevonden",
        .search_empty_body:
            "Niets komt overeen met \u{201C}%@\u{201D}. Probeer een andere titel of een ander trefwoord.",
        .search_error_quick: "Kan snelle toegang niet laden. Probeer het opnieuw.",
        .search_error_search: "Zoeken mislukt. Probeer het opnieuw.",

        // Shared
        .shared_title: "Gedeeld",
        .shared_with_me: "Met mij gedeeld",
        .shared_by_me: "Door mij gedeeld",
        .shared_count_one: "%d document",
        .shared_count_other: "%d documenten",
        .shared_subtitle_with: "Gedeeld · %@",
        .shared_subtitle_by: "%@ · Gedeeld %@",
        .shared_footer_with:
            "Documenten waarvoor anderen je hebben uitgenodigd. Je toegang hangt af van je rol per document.",
        .shared_footer_by:
            "Documenten die van jou zijn of die je hebt gedeeld. Beheer wie ze kunnen zien via het deelvenster van elk document.",
        .shared_error_load: "Kan gedeelde documenten niet laden. Controleer je verbinding en probeer het opnieuw.",
        .reach_restricted: "Beperkt",
        .reach_connected: "Verbonden",
        .reach_public: "Openbaar",

        // DocRow (design-system component)
        .docrow_pinned: "Vastgezet",
        .docrow_shared_with_organization: "Gedeeld met organisatie",
        .docrow_public: "Openbaar",
        .docrow_more_options: "Meer opties",
        .docrow_available_offline: "Offline beschikbaar",

        // LinkReachPill hints (design-system component; labels reuse reach.*)
        .linkreach_hint_restricted: "Alleen uitgenodigde personen",
        .linkreach_hint_authenticated: "Iedereen in de organisatie",
        .linkreach_hint_public: "Iedereen met de link",

        // ShareMemberRow (design-system component)
        .sharemember_role_a11y: "Rol: %@",
        .sharemember_role_hint: "Dubbeltik om rol te wijzigen",

        // Connect
        .connect_hero_title: "Welkom bij Schrift",
        .connect_hero_subtitle:
            "Maak verbinding met een server om te schrijven, organiseren en samen te werken — in realtime.",
        .connect_server_label: "Server",
        .connect_server_placeholder: "schrift.example.org",
        .connect_server_helper: "De app meldt zich aan met je bestaande sessie — er wordt geen wachtwoord opgeslagen.",
        .connect_sign_in: "Aanmelden",
        .connect_sign_in_to: "Aanmelden bij %@",
        .connect_recent_servers: "Recente servers",
        .connect_error_invalid_server: "Voer een geldig serveradres in.",
        .connect_error_sign_in_failed: "Aanmelden kon niet worden bevestigd. Probeer het opnieuw.",

        // Reauthentication
        .reauth_title: "Sessie verlopen",
        .reauth_error_sign_in_failed: "Aanmelden kon niet worden bevestigd. Probeer het opnieuw.",

        // Options sheet
        .options_title: "Opties",
        .options_pin: "Vastzetten",
        .options_unpin: "Losmaken",
        .options_pinned: "Vastgezet",
        .options_copy_link: "Link kopiëren",
        .options_share: "Delen",
        .options_copy_markdown: "Kopiëren als Markdown",
        .options_duplicate: "Dupliceren",
        .options_delete_document: "Document verwijderen",
        .options_delete_confirm_title: "Dit document verwijderen?",
        .options_delete: "Verwijderen",
        .options_error_toggle_favorite: "Kan favoriet niet bijwerken. Probeer het opnieuw.",
        .options_error_duplicate: "Kan document niet dupliceren. Probeer het opnieuw.",
        .options_error_delete: "Kan document niet verwijderen. Probeer het opnieuw.",

        // Share sheet
        .share_title: "Delen",
        .share_invite_placeholder: "Uitnodigen via naam of e-mail",
        .share_members_one: "Gedeeld met %d persoon",
        .share_members_other: "Gedeeld met %d personen",
        .share_add_people: "Personen toevoegen",
        .share_no_people_found: "Geen personen gevonden",
        .share_link_parameters: "Linkparameters",
        .share_change_link_access: "Linktoegang wijzigen",
        .share_copy_link: "Link kopiëren",
        .share_change_role: "Rol wijzigen",
        .share_remove: "Verwijderen",
        .share_link_access: "Linktoegang",
        .share_reach_authenticated: "Iedereen in de organisatie",
        .share_reach_public: "Iedereen met de link",
        .share_role_reader: "Lezer",
        .share_role_commenter: "Opmerker",
        .share_role_editor: "Bewerker",
        .share_role_administrator: "Beheerder",
        .share_role_owner: "Eigenaar",
        .share_role_pending: "%@ (In behandeling)",
        .share_error_load: "Kan leden niet laden. Trek omlaag om het opnieuw te proberen.",
        .share_error_search: "Zoeken mislukt. Probeer het opnieuw.",
        .share_error_invite: "Kan lid niet toevoegen. Probeer het opnieuw.",
        .share_error_update_role: "Kan rol niet bijwerken. Probeer het opnieuw.",
        .share_error_remove_member: "Kan lid niet verwijderen. Probeer het opnieuw.",
        .share_error_update_link: "Kan linkinstellingen niet bijwerken. Probeer het opnieuw.",

        // Editor - save bar
        .editor_save: "Opslaan",
        .editor_save_now_a11y: "Nu opslaan",
        .editor_saving: "Opslaan…",
        .editor_saved: "Opgeslagen",
        .editor_save_failed: "Opslaan mislukt · Opnieuw proberen",
        .editor_save_failed_a11y: "Opslaan mislukt. Opnieuw proberen",

        // Editor - reading surface / chrome
        .editor_offline_local_copy: "Je leest de kopie die op dit apparaat is opgeslagen",
        .editor_update_available: "Document bijgewerkt · tik om te vernieuwen",
        .editor_update_available_a11y: "Document bijgewerkt. Tik om te vernieuwen.",
        .editor_uploading_photo: "Foto uploaden…",
        .editor_uploading_photo_a11y: "Foto uploaden",
        .editor_empty_title: "Leeg document",
        .editor_empty_body: "Dit document heeft nog geen inhoud.",
        .editor_start_writing: "Begin met schrijven",
        .editor_subpages_title: "Subpagina's",
        .editor_subpages_title_count: "Subpagina's · %d",
        .editor_subpages_empty: "Organiseer dit document door subpagina's te maken.",
        .editor_add_subpage: "Subpagina toevoegen",
        .editor_action_done: "Gereed",
        .editor_action_pages: "Pagina's",
        .editor_action_share: "Delen",
        .editor_action_options: "Opties",

        // Editor - sync caption (reading-surface header)
        .editor_sync_save_failed: "Opslaan mislukt · tik om opnieuw te proberen",
        .editor_sync_save_failed_a11y: "Opslaan mislukt. Tik om opnieuw te proberen.",
        .editor_sync_saved_on_device: "Opgeslagen op dit apparaat",
        .editor_sync_edited_just_now: "Zojuist bewerkt",
        .editor_sync_just_now: "Zojuist gesynchroniseerd",
        .editor_sync_ago: "Gesynchroniseerd %@",
        .editor_sync_not_synced_yet: "Nog niet gesynchroniseerd",

        // Editor - errors
        .editor_error_load: "Kan dit document niet laden. Trek omlaag om het opnieuw te proberen.",
        .editor_error_refresh: "Vernieuwen mislukt. Probeer het opnieuw.",
        .editor_error_add_subpage: "Kan de subpagina niet toevoegen. Probeer het opnieuw.",
        .editor_error_open_link: "Kan die link niet openen. Probeer het opnieuw.",
        .editor_error_add_photo: "Kan de foto niet toevoegen. Probeer het opnieuw.",
        .editor_unavailable: "Dit document is niet meer beschikbaar.",
        .editor_unavailable_with_draft:
            "Dit document is niet meer beschikbaar. Je niet-opgeslagen wijzigingen worden bewaard op dit apparaat.",

        // Editor - slash menu (display labels; matching/filtering uses the
        // stable English `SlashMenuItem.title`, never these keys)
        .editor_slash_menu_a11y: "Menu bloktype",
        .editor_slash_text: "Tekst",
        .editor_slash_heading1: "Kop 1",
        .editor_slash_heading2: "Kop 2",
        .editor_slash_heading3: "Kop 3",
        .editor_slash_bulleted_list: "Opsommingslijst",
        .editor_slash_numbered_list: "Genummerde lijst",
        .editor_slash_checklist: "Checklist",
        .editor_slash_quote: "Citaat",
        .editor_slash_code_block: "Codeblok",
        .editor_slash_divider: "Scheidingslijn",
        .editor_slash_photo: "Foto",

        // Editor - formatting bar (icon-only buttons; accessibility labels)
        .editor_format_add_block: "Blok toevoegen",
        .editor_format_bold: "Vet",
        .editor_format_italic: "Cursief",
        .editor_format_link: "Link",
        .editor_format_bulleted_list: "Opsommingslijst",
        .editor_format_checklist: "Checklist",
        .editor_format_quote: "Citaat",
        .editor_format_code_block: "Codeblok",
        .editor_format_insert_photo: "Foto invoegen",

        // Editor - link editor sheet
        .editor_link_add_title: "Link toevoegen",
        .editor_link_edit_title: "Link bewerken",
        .editor_link_text_label: "Tekst",
        .editor_link_text_placeholder: "Linktekst",
        .editor_link_text_helper: "Laat leeg om het adres zelf weer te geven.",
        .editor_link_address_label: "Adres",
        .editor_link_address_placeholder: "example.com/page",
        .editor_link_address_error: "Dat adres kan niet als link worden gebruikt.",
        .editor_link_remove: "Link verwijderen",
        .editor_link_save: "Opslaan",
        .editor_link_add: "Toevoegen",

        // Editor - document tree panel (DocTreePanel)
        .editor_tree_pages: "Pagina's",
        .editor_tree_close: "Pagina's sluiten",
        .editor_tree_empty: "Nog geen subpagina's. Voeg er een toe om dit document te organiseren.",
        .editor_tree_new_page: "Nieuwe pagina",

        // Editor - inline image (MarkdownImageView; accessibility labels only)
        .editor_image_a11y: "Afbeelding",
        .editor_image_loading_a11y: "Afbeelding laden",
        .editor_image_loading_named_a11y: "Afbeelding laden: %@",

        // Editor - block canvas accessibility labels (BlockEditorView)
        .editor_add_paragraph_a11y: "Alinea toevoegen aan het einde",
        .editor_divider_a11y: "Scheidingslijn",
        .editor_checklist_done_a11y: "Markeren als voltooid",
        .editor_checklist_not_done_a11y: "Markeren als niet voltooid",

        // Profile
        .profile_title: "Profiel",
        .profile_user: "Gebruiker",
        .profile_prefs: "Voorkeuren",
        .profile_prefs_footer:
            "Indien ingeschakeld, blijven geopende documenten op dit apparaat leesbaar zonder verbinding.",
        .profile_appearance: "Weergave",
        .profile_language: "Taal",
        .profile_notifications: "Meldingen",
        .profile_work_offline: "Offline werken",
        .profile_server: "Server",
        .profile_server_footer: "De app maakt verbinding met elke Schrift-server via uw bestaande websessie.",
        .profile_connected: "Verbonden",
        .profile_offline: "Offline",
        .profile_server_version: "Serverversie",
        .profile_about: "Over",
        .profile_version: "Versie",
        .profile_sign_out: "Afmelden",
        .profile_disconnect_title: "Verbinding met %@ verbreken?",
        .profile_disconnect: "Verbreken",
        .profile_disconnect_body: "U moet opnieuw inloggen om weer verbinding te maken.",

        // Appearance picker
        .appearance_system: "Systeem",
        .appearance_light: "Licht",
        .appearance_dark: "Donker",
    ]
}
