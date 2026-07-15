import Foundation

// AI-generated translation — pending native-speaker review.
enum Strings_it {
    static let table: [L10nKey: String] = [
        .common_cancel: "Annulla",
        .common_close: "Chiudi",
        .common_retry: "Riprova",
        .common_untitled: "Documento senza titolo",
        .common_profile: "Profilo",
        .common_clear_search: "Cancella ricerca",
        .common_you: "(tu)",
        .search_results_one: "%d risultato",
        .search_results_other: "%d risultati",

        // Offline banner (common chrome)
        .offline_status: "Offline",
        .offline_note: "Tutti i documenti salvati su questo dispositivo",

        // Home
        .home_title: "Schrift",
        .home_search_placeholder: "Cerca %@",
        .home_search_documents: "Cerca documenti",
        .home_section_pinned: "Bloccati",
        .home_section_recent: "Recenti",
        .home_results: "Risultati",
        .home_empty_title: "Nessun documento",
        .home_empty_body: "I documenti che crei o che vengono condivisi con te appariranno qui.",
        .home_newdoc: "Nuovo documento",
        .home_dismiss_error: "Ignora errore",
        .home_select_document: "Seleziona un documento",
        .home_error_load: "Impossibile caricare i documenti. Trascina per aggiornare e riprova.",
        .home_error_search: "Ricerca non riuscita. Riprova.",
        .home_error_create: "Impossibile creare il documento. Riprova.",

        // Search
        .search_title: "Cerca",
        .search_placeholder: "Cerca in tutti i documenti",
        .search_recent: "Ricerche recenti",
        .search_quick: "Accesso rapido",
        .search_quick_empty: "I documenti bloccati appariranno qui.",
        .search_empty_title: "Nessun documento trovato",
        .search_empty_body: "Nessun risultato per \u{201C}%@\u{201D}. Prova un altro titolo o parola chiave.",
        .search_error_quick: "Impossibile caricare l'accesso rapido. Riprova.",
        .search_error_search: "Ricerca non riuscita. Riprova.",

        // Shared
        .shared_title: "Condivisi",
        .shared_count_one: "%d documento",
        .shared_count_other: "%d documenti",
        .shared_subtitle_with: "Condiviso · %@",
        .shared_subtitle_shared_by: "Condiviso da %@ · %@",
        .shared_footer_with:
            "Documenti a cui altre persone ti hanno invitato. Il tuo accesso dipende dal ruolo che hai su ciascuno.",
        .shared_error_load: "Impossibile caricare i documenti condivisi. Controlla la connessione e riprova.",
        .reach_restricted: "Limitato",
        .reach_connected: "Connesso",
        .reach_public: "Pubblico",

        // DocRow (design-system component)
        .docrow_pinned: "Bloccato",
        .docrow_shared_with_organization: "Condiviso con l'organizzazione",
        .docrow_public: "Pubblico",
        .docrow_available_offline: "Disponibile offline",

        // LinkReachPill hints (design-system component; labels reuse reach.*)
        .linkreach_hint_restricted: "Solo le persone invitate",
        .linkreach_hint_authenticated: "Chiunque nell'organizzazione",
        .linkreach_hint_public: "Chiunque abbia il link",

        // ShareMemberRow (design-system component)
        .sharemember_role_a11y: "Ruolo: %@",
        .sharemember_role_hint: "Tocca due volte per cambiare ruolo",

        // Connect
        .connect_hero_title: "Benvenuto in Schrift",
        .connect_hero_subtitle: "Connettiti a un server per scrivere, organizzare e collaborare — in tempo reale.",
        .connect_server_label: "Server",
        .connect_server_placeholder: "schrift.example.org",
        .connect_server_helper: "L'app accede con la tua sessione esistente — nessuna password viene memorizzata.",
        .connect_sign_in: "Accedi",
        .connect_sign_in_to: "Accedi a %@",
        .connect_recent_servers: "Server recenti",
        .connect_error_invalid_server: "Inserisci un indirizzo del server valido.",
        .connect_error_sign_in_failed: "Impossibile confermare l'accesso. Riprova.",

        // Reauthentication
        .reauth_title: "Sessione scaduta",
        .reauth_error_sign_in_failed: "Impossibile confermare l'accesso. Riprova.",

        // Options sheet
        .options_title: "Opzioni",
        .options_pin: "Blocca",
        .options_unpin: "Sblocca",
        .options_pinned: "Bloccato",
        .options_copy_link: "Copia link",
        .options_share: "Condividi",
        .options_delete_document: "Elimina documento",
        .options_delete_confirm_title: "Eliminare questo documento?",
        .options_delete: "Elimina",
        .options_error_toggle_favorite: "Impossibile aggiornare il preferito. Riprova.",
        .options_error_delete: "Impossibile eliminare il documento. Riprova.",

        // Share sheet
        .share_title: "Condividi",
        .share_invite_placeholder: "Invita per nome o email",
        .share_members_one: "Condiviso con %d persona",
        .share_members_other: "Condiviso con %d persone",
        .share_add_people: "Aggiungi persone",
        .share_no_people_found: "Nessuna persona trovata",
        .share_link_parameters: "Parametri del link",
        .share_change_link_access: "Cambia accesso al link",
        .share_copy_link: "Copia link",
        .share_change_role: "Cambia ruolo",
        .share_remove: "Rimuovi",
        .share_link_access: "Accesso al link",
        .share_reach_authenticated: "Chiunque nell'organizzazione",
        .share_reach_public: "Chiunque abbia il link",
        .share_role_reader: "Lettore",
        .share_role_commenter: "Commentatore",
        .share_role_editor: "Editor",
        .share_role_administrator: "Amministratore",
        .share_role_owner: "Proprietario",
        .share_role_pending: "%@ (In attesa)",
        .share_error_load: "Impossibile caricare i membri. Trascina per aggiornare e riprova.",
        .share_error_search: "Ricerca non riuscita. Riprova.",
        .share_error_invite: "Impossibile aggiungere il membro. Riprova.",
        .share_error_update_role: "Impossibile aggiornare il ruolo. Riprova.",
        .share_error_remove_member: "Impossibile rimuovere il membro. Riprova.",
        .share_error_update_link: "Impossibile aggiornare le impostazioni del link. Riprova.",

        // Editor - save bar
        .editor_save: "Salva",
        .editor_save_now_a11y: "Salva ora",
        .editor_saving: "Salvataggio…",
        .editor_saved: "Salvato",
        .editor_save_failed: "Impossibile salvare · Riprova",
        .editor_save_failed_a11y: "Salvataggio non riuscito. Riprova",

        // Editor - reading surface / chrome
        .editor_offline_local_copy: "Stai leggendo la copia salvata su questo dispositivo",
        .editor_update_available: "Documento aggiornato · tocca per aggiornare",
        .editor_update_available_a11y: "Documento aggiornato. Tocca per aggiornare.",
        .editor_uploading_photo: "Caricamento foto…",
        .editor_uploading_photo_a11y: "Caricamento foto",
        .editor_empty_title: "Documento vuoto",
        .editor_empty_body: "Questo documento non ha ancora contenuti.",
        .editor_start_writing: "Inizia a scrivere",
        .editor_subpages_title: "Sottopagine",
        .editor_subpages_title_count: "Sottopagine · %d",
        .editor_subpages_empty: "Organizza questo documento creando sottopagine.",
        .editor_add_subpage: "Aggiungi una sottopagina",
        .editor_action_done: "Fine",
        .editor_action_edit: "Modifica",
        .editor_action_share: "Condividi",
        .editor_action_options: "Opzioni",

        // Editor - sync caption (reading-surface header)
        .editor_sync_save_failed: "Impossibile salvare · tocca per riprovare",
        .editor_sync_save_failed_a11y: "Impossibile salvare. Tocca per riprovare.",
        .editor_sync_saved_on_device: "Salvato su questo dispositivo",
        .editor_sync_pending_sync: "Salvato su questo dispositivo · si sincronizza online",
        .editor_sync_edited_just_now: "Modificato proprio ora",
        .editor_sync_just_now: "Sincronizzato proprio ora",
        .editor_sync_ago: "Sincronizzato %@",
        .editor_sync_not_synced_yet: "Non ancora sincronizzato",
        .editor_conflict_pill: "Conflitto di sincronizzazione · tocca per rivedere",
        .editor_conflict_pill_a11y: "Conflitto di sincronizzazione. Tocca per rivedere.",
        .editor_conflict_title: "Conflitto di sincronizzazione",
        .editor_conflict_body:
            "Questo documento è stato modificato altrove mentre le tue modifiche attendevano la sincronizzazione. Scegli quale versione mantenere.",
        .editor_conflict_server_changed: "La copia sul server è stata modificata %@.",
        .editor_conflict_keep_mine: "Mantieni la mia versione",
        .editor_conflict_keep_mine_detail: "Sovrascrive la copia sul server",
        .editor_conflict_keep_server: "Mantieni la versione del server",
        .editor_conflict_keep_server_detail: "Ignora le modifiche su questo dispositivo",
        .editor_conflict_restore_hint:
            "Le versioni sovrascritte possono essere ripristinate dalla cronologia delle versioni sul web.",

        // Editor - errors
        .editor_error_load: "Impossibile caricare questo documento. Trascina per aggiornare e riprova.",
        .editor_error_refresh: "Impossibile aggiornare. Riprova.",
        .editor_error_add_subpage: "Impossibile aggiungere la sottopagina. Riprova.",
        .editor_error_open_link: "Impossibile aprire il link. Riprova.",
        .editor_error_add_photo: "Impossibile aggiungere la foto. Riprova.",
        .editor_unavailable: "Questo documento non è più disponibile.",
        .editor_unavailable_with_draft:
            "Questo documento non è più disponibile. Le modifiche non salvate vengono conservate su questo dispositivo.",

        // Editor - slash menu (display labels; matching/filtering uses the
        // stable English `SlashMenuItem.title`, never these keys)
        .editor_slash_menu_a11y: "Menu tipo di blocco",
        .editor_slash_text: "Testo",
        .editor_slash_heading1: "Titolo 1",
        .editor_slash_heading2: "Titolo 2",
        .editor_slash_heading3: "Titolo 3",
        .editor_slash_bulleted_list: "Elenco puntato",
        .editor_slash_numbered_list: "Elenco numerato",
        .editor_slash_checklist: "Lista di controllo",
        .editor_slash_quote: "Citazione",
        .editor_slash_code_block: "Blocco di codice",
        .editor_slash_divider: "Divisore",
        .editor_slash_photo: "Foto",

        // Editor - formatting bar (icon-only buttons; accessibility labels)
        .editor_format_add_block: "Aggiungi blocco",
        .editor_format_bold: "Grassetto",
        .editor_format_italic: "Corsivo",
        .editor_format_link: "Link",
        .editor_format_bulleted_list: "Elenco puntato",
        .editor_format_checklist: "Lista di controllo",
        .editor_format_quote: "Citazione",
        .editor_format_code_block: "Blocco di codice",
        .editor_format_insert_photo: "Inserisci foto",

        // Editor - link editor sheet
        .editor_link_add_title: "Aggiungi link",
        .editor_link_edit_title: "Modifica link",
        .editor_link_text_label: "Testo",
        .editor_link_text_placeholder: "Testo del link",
        .editor_link_text_helper: "Lascia vuoto per mostrare l'indirizzo stesso.",
        .editor_link_address_label: "Indirizzo",
        .editor_link_address_placeholder: "example.com/page",
        .editor_link_address_error: "Questo indirizzo non può essere usato come link.",
        .editor_link_remove: "Rimuovi link",
        .editor_link_save: "Salva",
        .editor_link_add: "Aggiungi",

        // Editor - version history
        .versions_title: "Cronologia versioni",
        .versions_current: "Versione corrente",
        .versions_restore_web: "Ripristina sul web",
        .versions_error: "Impossibile caricare le versioni. Riprova.",
        .versions_empty: "Nessuna versione precedente.",

        // Editor - inline image (MarkdownImageView; accessibility labels only)
        .editor_image_a11y: "Immagine",
        .editor_image_loading_a11y: "Caricamento immagine",
        .editor_image_loading_named_a11y: "Caricamento immagine: %@",

        // Editor - block canvas accessibility labels (BlockEditorView)
        .editor_add_paragraph_a11y: "Aggiungi paragrafo alla fine",
        .editor_divider_a11y: "Divisore",
        .editor_checklist_done_a11y: "Contrassegna come completato",
        .editor_checklist_not_done_a11y: "Contrassegna come non completato",

        // Profile
        .profile_title: "Profilo",
        .profile_user: "Utente",
        .profile_prefs: "Preferenze",
        .profile_prefs_footer:
            "Se attivo, i documenti aperti restano leggibili su questo dispositivo anche senza connessione.",
        .profile_appearance: "Aspetto",
        .profile_language: "Lingua",
        .profile_notifications: "Notifiche",
        .profile_work_offline: "Lavora offline",
        .profile_server: "Server",
        .profile_server_footer: "L’app si connette a qualsiasi server Schrift utilizzando la sessione web esistente.",
        .profile_connected: "Connesso",
        .profile_offline: "Offline",
        .profile_server_version: "Versione del server",
        .profile_about: "Informazioni",
        .profile_version: "Versione",
        .profile_sign_out: "Disconnetti",
        .profile_disconnect_title: "Disconnettersi da %@?",
        .profile_disconnect: "Disconnetti",
        .profile_disconnect_body: "Dovrai accedere di nuovo per riconnetterti.",

        // Appearance picker
        .appearance_system: "Sistema",
        .appearance_light: "Chiaro",
        .appearance_dark: "Scuro",
    ]
}
