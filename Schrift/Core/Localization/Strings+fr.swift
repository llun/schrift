import Foundation

// AI-generated translation — pending native-speaker review.
enum Strings_fr {
    static let table: [L10nKey: String] = [
        .common_cancel: "Annuler",
        .common_close: "Fermer",
        .common_retry: "Réessayer",
        .common_untitled: "Document sans titre",
        .common_profile: "Profil",
        .common_clear_search: "Effacer la recherche",
        .common_you: "(vous)",
        .search_results_one: "%d résultat",
        .search_results_other: "%d résultats",

        // Offline banner (common chrome)
        .offline_status: "Hors ligne",
        .offline_note: "Tous les documents enregistrés sur cet appareil",

        // Home
        .home_title: "Schrift",
        .home_search_placeholder: "Rechercher %@",
        .home_search_documents: "Rechercher des documents",
        .home_section_pinned: "Épinglés",
        .home_section_recent: "Récents",
        .home_results: "Résultats",
        .home_empty_title: "Aucun document pour le moment",
        .home_empty_body: "Les documents que vous créez ou qui sont partagés avec vous apparaîtront ici.",
        .home_newdoc: "Nouveau doc",
        .home_dismiss_error: "Ignorer l’erreur",
        .home_select_document: "Sélectionner un document",
        .home_error_load: "Impossible de charger les documents. Tirez vers le bas pour réessayer.",
        .home_error_search: "Échec de la recherche. Veuillez réessayer.",
        .home_error_create: "Impossible de créer un document. Veuillez réessayer.",

        // Search
        .search_title: "Recherche",
        .search_placeholder: "Rechercher dans tous les documents",
        .search_recent: "Recherches récentes",
        .search_quick: "Accès rapide",
        .search_quick_empty: "Les documents épinglés apparaîtront ici.",
        .search_empty_title: "Aucun document trouvé",
        .search_empty_body: "Aucun résultat pour \u{201C}%@\u{201D}. Essayez un autre titre ou mot-clé.",
        .search_error_quick: "Impossible de charger l’accès rapide. Veuillez réessayer.",
        .search_error_search: "Échec de la recherche. Veuillez réessayer.",

        // Shared
        .shared_title: "Partagés",
        .shared_count_one: "%d document",
        .shared_count_other: "%d documents",
        .shared_subtitle_with: "Partagé · %@",
        .shared_subtitle_shared_by: "Partagé par %@ · %@",
        .shared_footer_with:
            "Documents auxquels d’autres personnes vous ont invité. Votre accès dépend de votre rôle sur chacun d’eux.",
        .shared_error_load: "Impossible de charger les documents partagés. Vérifiez votre connexion et réessayez.",
        .reach_restricted: "Restreint",
        .reach_connected: "Connecté",
        .reach_public: "Public",

        // DocRow (design-system component)
        .docrow_pinned: "Épinglé",
        .docrow_shared_with_organization: "Partagé avec l’organisation",
        .docrow_public: "Public",
        .docrow_available_offline: "Disponible hors ligne",

        // LinkReachPill hints (design-system component; labels reuse reach.*)
        .linkreach_hint_restricted: "Uniquement les personnes invitées",
        .linkreach_hint_authenticated: "Toute personne de l’organisation",
        .linkreach_hint_public: "Toute personne disposant du lien",

        // ShareMemberRow (design-system component)
        .sharemember_role_a11y: "Rôle : %@",
        .sharemember_role_hint: "Appuyez deux fois pour changer le rôle",

        // Connect
        .connect_hero_title: "Bienvenue sur Schrift",
        .connect_hero_subtitle:
            "Connectez-vous à n’importe quel serveur pour écrire, organiser et collaborer — en temps réel.",
        .connect_server_label: "Serveur",
        .connect_server_placeholder: "schrift.example.org",
        .connect_server_helper:
            "L’application se connecte avec votre session existante — aucun mot de passe n’est stocké.",
        .connect_sign_in: "Se connecter",
        .connect_sign_in_to: "Se connecter à %@",
        .connect_recent_servers: "Serveurs récents",
        .connect_error_invalid_server: "Saisissez une adresse de serveur valide.",
        .connect_error_sign_in_failed: "La connexion n’a pas pu être confirmée. Veuillez réessayer.",

        // Reauthentication
        .reauth_title: "Session expirée",
        .reauth_error_sign_in_failed: "La connexion n’a pas pu être confirmée. Veuillez réessayer.",

        // Options sheet
        .options_title: "Options",
        .options_pin: "Épingler",
        .options_unpin: "Désépingler",
        .options_pinned: "Épinglé",
        .options_copy_link: "Copier le lien",
        .options_share: "Partager",
        .options_delete_document: "Supprimer le document",
        .options_delete_confirm_title: "Supprimer ce document ?",
        .options_delete: "Supprimer",
        .options_error_toggle_favorite: "Impossible de mettre à jour le favori. Veuillez réessayer.",
        .options_error_delete: "Impossible de supprimer le document. Veuillez réessayer.",

        // Share sheet
        .share_title: "Partager",
        .share_invite_placeholder: "Inviter par nom ou e-mail",
        .share_members_one: "Partagé avec %d personne",
        .share_members_other: "Partagé avec %d personnes",
        .share_add_people: "Ajouter des personnes",
        .share_no_people_found: "Aucune personne trouvée",
        .share_link_parameters: "Paramètres du lien",
        .share_change_link_access: "Modifier l’accès au lien",
        .share_copy_link: "Copier le lien",
        .share_change_role: "Changer le rôle",
        .share_remove: "Retirer",
        .share_link_access: "Accès au lien",
        .share_reach_authenticated: "Toute personne dans l’organisation",
        .share_reach_public: "Toute personne disposant du lien",
        .share_role_reader: "Lecteur",
        .share_role_commenter: "Commentateur",
        .share_role_editor: "Éditeur",
        .share_role_administrator: "Administrateur",
        .share_role_owner: "Propriétaire",
        .share_role_pending: "%@ (en attente)",
        .share_error_load: "Impossible de charger les membres. Tirez vers le bas pour réessayer.",
        .share_error_search: "Échec de la recherche. Veuillez réessayer.",
        .share_error_invite: "Impossible d’ajouter le membre. Veuillez réessayer.",
        .share_error_update_role: "Impossible de mettre à jour le rôle. Veuillez réessayer.",
        .share_error_remove_member: "Impossible de retirer le membre. Veuillez réessayer.",
        .share_error_update_link: "Impossible de mettre à jour les paramètres du lien. Veuillez réessayer.",

        // Editor - save bar
        .editor_save: "Enregistrer",
        .editor_save_now_a11y: "Enregistrer maintenant",
        .editor_saving: "Enregistrement…",
        .editor_saved: "Enregistré",
        .editor_save_failed: "Impossible d’enregistrer · Réessayer",
        .editor_save_failed_a11y: "Échec de l’enregistrement. Réessayer",

        // Editor - reading surface / chrome
        .editor_offline_local_copy: "Lecture de la copie enregistrée sur cet appareil",
        .editor_update_available: "Document mis à jour · appuyez pour actualiser",
        .editor_update_available_a11y: "Document mis à jour. Appuyez pour actualiser.",
        .editor_uploading_photo: "Envoi de la photo…",
        .editor_uploading_photo_a11y: "Envoi de la photo",
        .editor_empty_title: "Document vide",
        .editor_empty_body: "Ce document n’a pas encore de contenu.",
        .editor_start_writing: "Commencer à écrire",
        .editor_subpages_title: "Sous-pages",
        .editor_subpages_title_count: "Sous-pages · %d",
        .editor_subpages_empty: "Organisez ce document en créant des sous-pages.",
        .editor_add_subpage: "Ajouter une sous-page",
        .editor_action_done: "Terminé",
        .editor_action_edit: "Modifier",
        .editor_action_share: "Partager",
        .editor_action_options: "Options",

        // Editor - sync caption (reading-surface header)
        .editor_sync_save_failed: "Impossible d’enregistrer · appuyez pour réessayer",
        .editor_sync_save_failed_a11y: "Impossible d’enregistrer. Appuyez pour réessayer.",
        .editor_sync_saved_on_device: "Enregistré sur cet appareil",
        .editor_sync_pending_sync: "Enregistré sur cet appareil · synchronisé une fois en ligne",
        .editor_sync_edited_just_now: "Modifié à l’instant",
        .editor_sync_just_now: "Synchronisé à l’instant",
        .editor_sync_ago: "Synchronisé %@",
        .editor_sync_not_synced_yet: "Pas encore synchronisé",
        .editor_conflict_pill: "Conflit de synchronisation · appuyer pour vérifier",
        .editor_conflict_pill_a11y: "Conflit de synchronisation. Appuyer pour vérifier.",
        .editor_conflict_title: "Conflit de synchronisation",
        .editor_conflict_body:
            "Ce document a été modifié ailleurs pendant que vos modifications attendaient la synchronisation. Choisissez la version à conserver.",
        .editor_conflict_server_changed: "La copie du serveur a été modifiée %@.",
        .editor_conflict_keep_mine: "Conserver ma version",
        .editor_conflict_keep_mine_detail: "Remplace la copie du serveur",
        .editor_conflict_keep_server: "Conserver la version du serveur",
        .editor_conflict_keep_server_detail: "Ignore les modifications sur cet appareil",
        .editor_conflict_restore_hint:
            "Les versions remplacées peuvent être restaurées depuis l’historique des versions sur le web.",

        // Editor - errors
        .editor_error_load: "Impossible de charger ce document. Tirez vers le bas pour réessayer.",
        .editor_error_refresh: "Impossible d’actualiser. Veuillez réessayer.",
        .editor_error_add_subpage: "Impossible d’ajouter la sous-page. Veuillez réessayer.",
        .editor_error_open_link: "Impossible d’ouvrir ce lien. Veuillez réessayer.",
        .editor_error_add_photo: "Impossible d’ajouter la photo. Veuillez réessayer.",
        .editor_unavailable: "Ce document n’est plus disponible.",
        .editor_unavailable_with_draft:
            "Ce document n’est plus disponible. Vos modifications non enregistrées sont conservées sur cet appareil.",

        // Editor - slash menu (display labels; matching/filtering uses the
        // stable English `SlashMenuItem.title`, never these keys)
        .editor_slash_menu_a11y: "Menu de type de bloc",
        .editor_slash_text: "Texte",
        .editor_slash_heading1: "Titre 1",
        .editor_slash_heading2: "Titre 2",
        .editor_slash_heading3: "Titre 3",
        .editor_slash_bulleted_list: "Liste à puces",
        .editor_slash_numbered_list: "Liste numérotée",
        .editor_slash_checklist: "Liste de tâches",
        .editor_slash_quote: "Citation",
        .editor_slash_code_block: "Bloc de code",
        .editor_slash_divider: "Séparateur",
        .editor_slash_photo: "Photo",

        // Editor - formatting bar (icon-only buttons; accessibility labels)
        .editor_format_add_block: "Ajouter un bloc",
        .editor_format_bold: "Gras",
        .editor_format_italic: "Italique",
        .editor_format_link: "Lien",
        .editor_format_bulleted_list: "Liste à puces",
        .editor_format_checklist: "Liste de tâches",
        .editor_format_quote: "Citation",
        .editor_format_code_block: "Bloc de code",
        .editor_format_insert_photo: "Insérer une photo",

        // Editor - link editor sheet
        .editor_link_add_title: "Ajouter un lien",
        .editor_link_edit_title: "Modifier le lien",
        .editor_link_text_label: "Texte",
        .editor_link_text_placeholder: "Texte du lien",
        .editor_link_text_helper: "Laissez vide pour afficher l’adresse elle-même.",
        .editor_link_address_label: "Adresse",
        .editor_link_address_placeholder: "example.com/page",
        .editor_link_address_error: "Cette adresse ne peut pas être utilisée comme lien.",
        .editor_link_remove: "Supprimer le lien",
        .editor_link_save: "Enregistrer",
        .editor_link_add: "Ajouter",

        // Editor - version history
        .versions_title: "Historique des versions",
        .versions_current: "Version actuelle",
        .versions_restore_web: "Restaurer sur le web",
        .versions_error: "Impossible de charger les versions. Veuillez réessayer.",
        .versions_empty: "Aucune version antérieure pour le moment.",

        // Editor - inline image (MarkdownImageView; accessibility labels only)
        .editor_image_a11y: "Image",
        .editor_image_loading_a11y: "Chargement de l’image",
        .editor_image_loading_named_a11y: "Chargement de l’image : %@",

        // Editor - block canvas accessibility labels (BlockEditorView)
        .editor_add_paragraph_a11y: "Ajouter un paragraphe à la fin",
        .editor_divider_a11y: "Séparateur",
        .editor_checklist_done_a11y: "Marquer comme terminé",
        .editor_checklist_not_done_a11y: "Marquer comme non terminé",
        .editor_presence_count_one: "%d personne ici",
        .editor_presence_count_other: "%d personnes ici",

        // Profile
        .profile_title: "Profil",
        .profile_user: "Utilisateur",
        .profile_prefs: "Préférences",
        .profile_prefs_footer:
            "Lorsque cette option est activée, les documents que vous avez ouverts restent lisibles sur cet appareil sans connexion.",
        .profile_appearance: "Apparence",
        .profile_language: "Langue",
        .profile_notifications: "Notifications",
        .profile_work_offline: "Travailler hors ligne",
        .profile_live_collaboration: "Collaboration en direct",
        .profile_live_collaboration_footer:
            "La collaboration en direct synchronise vos modifications avec les autres en temps réel lorsque votre serveur la prend en charge.",
        .profile_server: "Serveur",
        .profile_server_footer:
            "L’application se connecte à n’importe quel serveur Schrift à l’aide de votre session Web existante.",
        .profile_connected: "Connecté",
        .profile_offline: "Hors ligne",
        .profile_server_version: "Version du serveur",
        .profile_about: "À propos",
        .profile_version: "Version",
        .profile_sign_out: "Se déconnecter",
        .profile_disconnect_title: "Se déconnecter de %@ ?",
        .profile_disconnect: "Déconnecter",
        .profile_disconnect_body: "Vous devrez vous reconnecter pour rétablir la connexion.",

        // Appearance picker
        .appearance_system: "Système",
        .appearance_light: "Clair",
        .appearance_dark: "Sombre",
    ]
}
