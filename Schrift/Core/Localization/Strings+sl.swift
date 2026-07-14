import Foundation

// AI-generated translation — pending native-speaker review.
//
// Slovene is the one language whose plural rules need more than one/other:
// `*_two` (the dual) and `*_few` forms are defined here and nowhere else
// (see PluralRule and LocalizationStore.plural).
enum Strings_sl {
    static let table: [L10nKey: String] = [
        .common_cancel: "Prekliči",
        .common_close: "Zapri",
        .common_retry: "Poskusi znova",
        .common_untitled: "Neimenovan dokument",
        .common_profile: "Profil",
        .common_clear_search: "Počisti iskanje",
        .common_you: "(vi)",
        .search_results_one: "%d rezultat",
        .search_results_other: "%d rezultatov",
        .search_results_two: "%d rezultata",
        .search_results_few: "%d rezultati",

        // Offline banner (common chrome)
        .offline_status: "Brez povezave",
        .offline_note: "Vsi dokumenti, shranjeni v tej napravi",

        // Home
        .home_title: "Schrift",
        .home_search_placeholder: "Išči %@",
        .home_search_documents: "Išči dokumente",
        .home_section_pinned: "Pripeto",
        .home_section_recent: "Nedavno",
        .home_results: "Rezultati",
        .home_empty_title: "Še ni dokumentov",
        .home_empty_body: "Dokumenti, ki jih ustvarite ali so deljeni z vami, bodo prikazani tukaj.",
        .home_newdoc: "Nov dokument",
        .home_dismiss_error: "Skrij napako",
        .home_select_document: "Izberite dokument",
        .home_error_load: "Dokumentov ni bilo mogoče naložiti. Povlecite za osvežitev in poskusite znova.",
        .home_error_search: "Iskanje ni uspelo. Poskusite znova.",
        .home_error_create: "Dokumenta ni bilo mogoče ustvariti. Poskusite znova.",

        // Search
        .search_title: "Iskanje",
        .search_placeholder: "Išči po vseh dokumentih",
        .search_recent: "Nedavna iskanja",
        .search_quick: "Hitri dostop",
        .search_quick_empty: "Pripeti dokumenti bodo prikazani tukaj.",
        .search_empty_title: "Ni najdenih dokumentov",
        .search_empty_body: "Nič se ne ujema z \u{201C}%@\u{201D}. Poskusite z drugim naslovom ali ključno besedo.",
        .search_error_quick: "Hitrega dostopa ni bilo mogoče naložiti. Poskusite znova.",
        .search_error_search: "Iskanje ni uspelo. Poskusite znova.",

        // Shared
        .shared_title: "Deljeno",
        .shared_count_one: "%d dokument",
        .shared_count_other: "%d dokumentov",
        .shared_count_two: "%d dokumenta",
        .shared_count_few: "%d dokumenti",
        .shared_subtitle_with: "Deljeno · %@",
        .shared_subtitle_shared_by: "Delil %@ · %@",
        .shared_footer_with:
            "Dokumenti, h katerim so vas povabili drugi. Vaš dostop je odvisen od vaše vloge pri vsakem.",
        .shared_error_load: "Deljenih dokumentov ni bilo mogoče naložiti. Preverite povezavo in poskusite znova.",
        .reach_restricted: "Omejeno",
        .reach_connected: "Povezano",
        .reach_public: "Javno",

        // DocRow (design-system component)
        .docrow_pinned: "Pripeto",
        .docrow_shared_with_organization: "Deljeno z organizacijo",
        .docrow_public: "Javno",
        .docrow_available_offline: "Na voljo brez povezave",

        // LinkReachPill hints (design-system component; labels reuse reach.*)
        .linkreach_hint_restricted: "Samo povabljeni",
        .linkreach_hint_authenticated: "Vsakdo v organizaciji",
        .linkreach_hint_public: "Vsakdo s povezavo",

        // ShareMemberRow (design-system component)
        .sharemember_role_a11y: "Vloga: %@",
        .sharemember_role_hint: "Dvakrat tapnite za spremembo vloge",

        // Connect
        .connect_hero_title: "Dobrodošli v Schrift",
        .connect_hero_subtitle:
            "Povežite se s katerim koli strežnikom za pisanje, urejanje in sodelovanje — v realnem času.",
        .connect_server_label: "Strežnik",
        .connect_server_placeholder: "schrift.example.org",
        .connect_server_helper: "Aplikacija se prijavi z vašo obstoječo sejo — geslo ni shranjeno.",
        .connect_sign_in: "Prijava",
        .connect_sign_in_to: "Prijava v %@",
        .connect_recent_servers: "Nedavni strežniki",
        .connect_error_invalid_server: "Vnesite veljaven naslov strežnika.",
        .connect_error_sign_in_failed: "Prijave ni bilo mogoče potrditi. Poskusite znova.",

        // Reauthentication
        .reauth_title: "Seja je potekla",
        .reauth_error_sign_in_failed: "Prijave ni bilo mogoče potrditi. Poskusite znova.",

        // Options sheet
        .options_title: "Možnosti",
        .options_pin: "Pripni",
        .options_unpin: "Odpni",
        .options_pinned: "Pripeto",
        .options_copy_link: "Kopiraj povezavo",
        .options_share: "Deli",
        .options_delete_document: "Izbriši dokument",
        .options_delete_confirm_title: "Izbrišem ta dokument?",
        .options_delete: "Izbriši",
        .options_error_toggle_favorite: "Priljubljene ni bilo mogoče posodobiti. Poskusite znova.",
        .options_error_delete: "Dokumenta ni bilo mogoče izbrisati. Poskusite znova.",

        // Share sheet
        .share_title: "Deljenje",
        .share_invite_placeholder: "Povabite po imenu ali e-pošti",
        .share_members_one: "Deljeno z %d osebo",
        .share_members_other: "Deljeno z %d osebami",
        .share_members_two: "Deljeno z %d osebama",
        .share_members_few: "Deljeno s %d osebami",
        .share_add_people: "Dodaj osebe",
        .share_no_people_found: "Ni najdenih oseb",
        .share_link_parameters: "Parametri povezave",
        .share_change_link_access: "Spremeni dostop do povezave",
        .share_copy_link: "Kopiraj povezavo",
        .share_change_role: "Spremeni vlogo",
        .share_remove: "Odstrani",
        .share_link_access: "Dostop do povezave",
        .share_reach_authenticated: "Vsakdo v organizaciji",
        .share_reach_public: "Vsakdo s povezavo",
        .share_role_reader: "Bralec",
        .share_role_commenter: "Komentator",
        .share_role_editor: "Urejevalec",
        .share_role_administrator: "Skrbnik",
        .share_role_owner: "Lastnik",
        .share_role_pending: "%@ (na čakanju)",
        .share_error_load: "Članov ni bilo mogoče naložiti. Povlecite za osvežitev in poskusite znova.",
        .share_error_search: "Iskanje ni uspelo. Poskusite znova.",
        .share_error_invite: "Člana ni bilo mogoče dodati. Poskusite znova.",
        .share_error_update_role: "Vloge ni bilo mogoče posodobiti. Poskusite znova.",
        .share_error_remove_member: "Člana ni bilo mogoče odstraniti. Poskusite znova.",
        .share_error_update_link: "Nastavitev povezave ni bilo mogoče posodobiti. Poskusite znova.",

        // Editor - save bar
        .editor_save: "Shrani",
        .editor_save_now_a11y: "Shrani zdaj",
        .editor_saving: "Shranjevanje…",
        .editor_saved: "Shranjeno",
        .editor_save_failed: "Ni bilo mogoče shraniti · Poskusi znova",
        .editor_save_failed_a11y: "Shranjevanje ni uspelo. Poskusi znova",

        // Editor - reading surface / chrome
        .editor_offline_local_copy: "Berete kopijo, shranjeno v tej napravi",
        .editor_update_available: "Dokument posodobljen · tapnite za osvežitev",
        .editor_update_available_a11y: "Dokument posodobljen. Tapnite za osvežitev.",
        .editor_uploading_photo: "Nalaganje fotografije…",
        .editor_uploading_photo_a11y: "Nalaganje fotografije",
        .editor_empty_title: "Prazen dokument",
        .editor_empty_body: "Ta dokument še nima vsebine.",
        .editor_start_writing: "Začni pisati",
        .editor_subpages_title: "Podstrani",
        .editor_subpages_title_count: "Podstrani · %d",
        .editor_subpages_empty: "Organizirajte ta dokument z ustvarjanjem podstrani.",
        .editor_add_subpage: "Dodaj podstran",
        .editor_action_done: "Končano",
        .editor_action_edit: "Uredi",
        .editor_action_share: "Deli",
        .editor_action_options: "Možnosti",

        // Editor - sync caption (reading-surface header)
        .editor_sync_save_failed: "Ni bilo mogoče shraniti · tapnite za ponovni poskus",
        .editor_sync_save_failed_a11y: "Ni bilo mogoče shraniti. Tapnite za ponovni poskus.",
        .editor_sync_saved_on_device: "Shranjeno v tej napravi",
        .editor_sync_pending_sync: "Shranjeno v tej napravi · sinhronizira se ob povezavi",
        .editor_sync_edited_just_now: "Pravkar urejeno",
        .editor_sync_just_now: "Pravkar sinhronizirano",
        .editor_sync_ago: "Sinhronizirano %@",
        .editor_sync_not_synced_yet: "Še ni sinhronizirano",
        .editor_conflict_pill: "Konflikt sinhronizacije · tapnite za pregled",
        .editor_conflict_pill_a11y: "Konflikt sinhronizacije. Tapnite za pregled.",
        .editor_conflict_title: "Konflikt sinhronizacije",
        .editor_conflict_body:
            "Ta dokument je bil medtem, ko so vaše spremembe čakale na sinhronizacijo, spremenjen drugje. Izberite, katero različico obdržati.",
        .editor_conflict_server_changed: "Strežniška kopija je bila spremenjena %@.",
        .editor_conflict_keep_mine: "Obdrži mojo različico",
        .editor_conflict_keep_mine_detail: "Prepiše kopijo na strežniku",
        .editor_conflict_keep_server: "Obdrži strežniško različico",
        .editor_conflict_keep_server_detail: "Zavrže spremembe v tej napravi",
        .editor_conflict_restore_hint: "Prepisane različice je mogoče obnoviti iz zgodovine različic na spletu.",

        // Editor - errors
        .editor_error_load: "Tega dokumenta ni bilo mogoče naložiti. Povlecite za osvežitev in poskusite znova.",
        .editor_error_refresh: "Ni bilo mogoče osvežiti. Poskusite znova.",
        .editor_error_add_subpage: "Podstrani ni bilo mogoče dodati. Poskusite znova.",
        .editor_error_open_link: "Te povezave ni bilo mogoče odpreti. Poskusite znova.",
        .editor_error_add_photo: "Fotografije ni bilo mogoče dodati. Poskusite znova.",
        .editor_unavailable: "Ta dokument ni več na voljo.",
        .editor_unavailable_with_draft:
            "Ta dokument ni več na voljo. Vaše neshranjene spremembe so ohranjene v tej napravi.",

        // Editor - slash menu (display labels; matching/filtering uses the
        // stable English `SlashMenuItem.title`, never these keys)
        .editor_slash_menu_a11y: "Meni vrst blokov",
        .editor_slash_text: "Besedilo",
        .editor_slash_heading1: "Naslov 1",
        .editor_slash_heading2: "Naslov 2",
        .editor_slash_heading3: "Naslov 3",
        .editor_slash_bulleted_list: "Označen seznam",
        .editor_slash_numbered_list: "Oštevilčen seznam",
        .editor_slash_checklist: "Kontrolni seznam",
        .editor_slash_quote: "Citat",
        .editor_slash_code_block: "Blok kode",
        .editor_slash_divider: "Ločilna črta",
        .editor_slash_photo: "Fotografija",

        // Editor - formatting bar (icon-only buttons; accessibility labels)
        .editor_format_add_block: "Dodaj blok",
        .editor_format_bold: "Krepko",
        .editor_format_italic: "Ležeče",
        .editor_format_link: "Povezava",
        .editor_format_bulleted_list: "Označen seznam",
        .editor_format_checklist: "Kontrolni seznam",
        .editor_format_quote: "Citat",
        .editor_format_code_block: "Blok kode",
        .editor_format_insert_photo: "Vstavi fotografijo",

        // Editor - link editor sheet
        .editor_link_add_title: "Dodaj povezavo",
        .editor_link_edit_title: "Uredi povezavo",
        .editor_link_text_label: "Besedilo",
        .editor_link_text_placeholder: "Besedilo povezave",
        .editor_link_text_helper: "Pustite prazno za prikaz samega naslova.",
        .editor_link_address_label: "Naslov",
        .editor_link_address_placeholder: "example.com/page",
        .editor_link_address_error: "Tega naslova ni mogoče uporabiti kot povezavo.",
        .editor_link_remove: "Odstrani povezavo",
        .editor_link_save: "Shrani",
        .editor_link_add: "Dodaj",

        // Editor - version history
        .versions_title: "Zgodovina različic",
        .versions_current: "Trenutna različica",
        .versions_restore_web: "Obnovi na spletu",
        .versions_error: "Različic ni bilo mogoče naložiti. Poskusite znova.",
        .versions_empty: "Še ni starejših različic.",

        // Editor - inline image (MarkdownImageView; accessibility labels only)
        .editor_image_a11y: "Slika",
        .editor_image_loading_a11y: "Nalaganje slike",
        .editor_image_loading_named_a11y: "Nalaganje slike: %@",

        // Editor - block canvas accessibility labels (BlockEditorView)
        .editor_add_paragraph_a11y: "Dodaj odstavek na koncu",
        .editor_divider_a11y: "Ločilna črta",
        .editor_checklist_done_a11y: "Označi kot opravljeno",
        .editor_checklist_not_done_a11y: "Označi kot neopravljeno",

        // Profile
        .profile_title: "Profil",
        .profile_user: "Uporabnik",
        .profile_prefs: "Nastavitve",
        .profile_prefs_footer:
            "Ko je vklopljeno, ostanejo dokumenti, ki ste jih odprli, berljivi v tej napravi brez povezave.",
        .profile_appearance: "Videz",
        .profile_language: "Jezik",
        .profile_notifications: "Obvestila",
        .profile_work_offline: "Delo brez povezave",
        .profile_server: "Strežnik",
        .profile_server_footer: "Aplikacija se poveže s katerim koli strežnikom Schrift z vašo obstoječo spletno sejo.",
        .profile_connected: "Povezano",
        .profile_offline: "Brez povezave",
        .profile_server_version: "Različica strežnika",
        .profile_about: "O aplikaciji",
        .profile_version: "Različica",
        .profile_sign_out: "Odjava",
        .profile_disconnect_title: "Prekinem povezavo z %@?",
        .profile_disconnect: "Prekini povezavo",
        .profile_disconnect_body: "Za ponovno povezavo se boste morali znova prijaviti.",

        // Appearance picker
        .appearance_system: "Sistem",
        .appearance_light: "Svetlo",
        .appearance_dark: "Temno",
    ]
}
