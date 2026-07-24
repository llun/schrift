import Foundation

// AI-generated translation — pending native-speaker review.
enum Strings_es {
    static let table: [L10nKey: String] = [
        .common_cancel: "Cancelar",
        .common_close: "Cerrar",
        .common_retry: "Reintentar",
        .common_untitled: "Documento sin título",
        .common_profile: "Perfil",
        .common_clear_search: "Borrar búsqueda",
        .common_you: "(tú)",
        .search_results_one: "%d resultado",
        .search_results_other: "%d resultados",

        // Offline banner (common chrome)
        .offline_status: "Sin conexión",
        .offline_note: "Todos los documentos guardados en este dispositivo",

        // Home
        .home_title: "Schrift",
        .home_search_placeholder: "Buscar %@",
        .home_search_documents: "Buscar documentos",
        .home_section_pinned: "Fijados",
        .home_section_recent: "Recientes",
        .home_results: "Resultados",
        .home_empty_title: "Aún no hay documentos",
        .home_empty_body: "Los documentos que crees o que se compartan contigo aparecerán aquí.",
        .home_newdoc: "Nuevo doc",
        .home_dismiss_error: "Descartar error",
        .home_select_document: "Selecciona un documento",
        .home_error_load:
            "No se pudieron cargar los documentos. Desliza hacia abajo para actualizar e inténtalo de nuevo.",
        .home_error_search: "La búsqueda falló. Inténtalo de nuevo.",
        .home_error_create: "No se pudo crear el documento. Inténtalo de nuevo.",

        // Search
        .search_title: "Buscar",
        .search_placeholder: "Buscar en todos los documentos",
        .search_recent: "Búsquedas recientes",
        .search_quick: "Acceso rápido",
        .search_quick_empty: "Los documentos fijados aparecerán aquí.",
        .search_empty_title: "No se encontraron documentos",
        .search_empty_body: "Nada coincide con \u{201C}%@\u{201D}. Prueba con otro título o palabra clave.",
        .search_error_quick: "No se pudo cargar el acceso rápido. Inténtalo de nuevo.",
        .search_error_search: "La búsqueda falló. Inténtalo de nuevo.",

        // Shared
        .shared_title: "Compartidos",
        .shared_count_one: "%d documento",
        .shared_count_other: "%d documentos",
        .shared_subtitle_with: "Compartido · %@",
        .shared_subtitle_shared_by: "Compartido por %@ · %@",
        .shared_footer_with:
            "Documentos a los que otras personas te han invitado. Tu acceso depende de tu rol en cada uno.",
        .shared_error_load:
            "No se pudieron cargar los documentos compartidos. Comprueba tu conexión e inténtalo de nuevo.",
        .reach_restricted: "Restringido",
        .reach_connected: "Conectado",
        .reach_public: "Público",

        // DocRow (design-system component)
        .docrow_pinned: "Fijado",
        .docrow_shared_with_organization: "Compartido con la organización",
        .docrow_public: "Público",
        .docrow_available_offline: "Disponible sin conexión",

        // LinkReachPill hints (design-system component; labels reuse reach.*)
        .linkreach_hint_restricted: "Solo personas invitadas",
        .linkreach_hint_authenticated: "Cualquiera en la organización",
        .linkreach_hint_public: "Cualquiera con el enlace",

        // ShareMemberRow (design-system component)
        .sharemember_role_a11y: "Rol: %@",
        .sharemember_role_hint: "Doble toque para cambiar el rol",

        // Connect
        .connect_hero_title: "Bienvenido a Schrift",
        .connect_hero_subtitle: "Conéctate a cualquier servidor para escribir, organizar y colaborar — en tiempo real.",
        .connect_server_label: "Servidor",
        .connect_server_placeholder: "schrift.example.org",
        .connect_server_helper:
            "La aplicación inicia sesión con tu sesión existente — no se guarda ninguna contraseña.",
        .connect_sign_in: "Iniciar sesión",
        .connect_sign_in_to: "Iniciar sesión en %@",
        .connect_recent_servers: "Servidores recientes",
        .connect_error_invalid_server: "Introduce una dirección de servidor válida.",
        .connect_error_sign_in_failed: "No se pudo confirmar el inicio de sesión. Inténtalo de nuevo.",

        // Reauthentication
        .reauth_title: "Sesión expirada",
        .reauth_error_sign_in_failed: "No se pudo confirmar el inicio de sesión. Inténtalo de nuevo.",

        // Options sheet
        .options_title: "Opciones",
        .options_pin: "Fijar",
        .options_unpin: "Dejar de fijar",
        .options_pinned: "Fijado",
        .options_copy_link: "Copiar enlace",
        .options_share: "Compartir",
        .options_delete_document: "Eliminar documento",
        .options_delete_confirm_title: "¿Eliminar este documento?",
        .options_delete: "Eliminar",
        .options_error_toggle_favorite: "No se pudo actualizar el favorito. Inténtalo de nuevo.",
        .options_error_delete: "No se pudo eliminar el documento. Inténtalo de nuevo.",

        // Share sheet
        .share_title: "Compartir",
        .share_invite_placeholder: "Invitar por nombre o correo electrónico",
        .share_members_one: "Compartido con %d persona",
        .share_members_other: "Compartido con %d personas",
        .share_add_people: "Añadir personas",
        .share_no_people_found: "No se encontraron personas",
        .share_link_parameters: "Parámetros del enlace",
        .share_change_link_access: "Cambiar acceso del enlace",
        .share_copy_link: "Copiar enlace",
        .share_change_role: "Cambiar rol",
        .share_remove: "Quitar",
        .share_link_access: "Acceso del enlace",
        .share_reach_authenticated: "Cualquiera en la organización",
        .share_reach_public: "Cualquiera con el enlace",
        .share_role_reader: "Lector",
        .share_role_commenter: "Comentarista",
        .share_role_editor: "Editor",
        .share_role_administrator: "Administrador",
        .share_role_owner: "Propietario",
        .share_role_pending: "%@ (Pendiente)",
        .share_error_load:
            "No se pudieron cargar los miembros. Desliza hacia abajo para actualizar e inténtalo de nuevo.",
        .share_error_search: "La búsqueda falló. Inténtalo de nuevo.",
        .share_error_invite: "No se pudo añadir al miembro. Inténtalo de nuevo.",
        .share_error_update_role: "No se pudo actualizar el rol. Inténtalo de nuevo.",
        .share_error_remove_member: "No se pudo quitar al miembro. Inténtalo de nuevo.",
        .share_error_update_link: "No se pudo actualizar la configuración del enlace. Inténtalo de nuevo.",

        // Editor - save bar
        .editor_save: "Guardar",
        .editor_save_now_a11y: "Guardar ahora",
        .editor_saving: "Guardando…",
        .editor_saved: "Guardado",
        .editor_save_failed: "No se pudo guardar · Reintentar",
        .editor_save_failed_a11y: "Error al guardar. Reintentar",

        // Editor - reading surface / chrome
        .editor_offline_local_copy: "Leyendo la copia guardada en este dispositivo",
        .editor_update_available: "Documento actualizado · toca para actualizar",
        .editor_update_available_a11y: "Documento actualizado. Toca para actualizar.",
        .editor_uploading_photo: "Subiendo foto…",
        .editor_uploading_photo_a11y: "Subiendo foto",
        .editor_empty_title: "Documento vacío",
        .editor_empty_body: "Este documento aún no tiene contenido.",
        .editor_start_writing: "Empezar a escribir",
        .editor_subpages_title: "Subpáginas",
        .editor_subpages_title_count: "Subpáginas · %d",
        .editor_subpages_empty: "Organiza este documento creando subpáginas.",
        .editor_add_subpage: "Añadir una subpágina",
        .editor_action_done: "Listo",
        .editor_action_edit: "Editar",
        .editor_action_share: "Compartir",
        .editor_action_options: "Opciones",

        // Editor - sync caption (reading-surface header)
        .editor_sync_save_failed: "No se pudo guardar · toca para reintentar",
        .editor_sync_save_failed_a11y: "No se pudo guardar. Toca para reintentar.",
        .editor_sync_saved_on_device: "Guardado en este dispositivo",
        .editor_sync_pending_sync: "Guardado en este dispositivo · se sincroniza al conectarse",
        .editor_sync_edited_just_now: "Editado justo ahora",
        .editor_sync_just_now: "Sincronizado justo ahora",
        .editor_sync_ago: "Sincronizado %@",
        .editor_sync_not_synced_yet: "Aún no sincronizado",
        .editor_conflict_pill: "Conflicto de sincronización · toca para revisar",
        .editor_conflict_pill_a11y: "Conflicto de sincronización. Toca para revisar.",
        .editor_conflict_title: "Conflicto de sincronización",
        .editor_conflict_body:
            "Este documento cambió en otro lugar mientras tus cambios esperaban sincronizarse. Elige qué versión conservar.",
        .editor_conflict_server_changed: "La copia del servidor cambió %@.",
        .editor_conflict_keep_mine: "Conservar mi versión",
        .editor_conflict_keep_mine_detail: "Sobrescribe la copia del servidor",
        .editor_conflict_keep_server: "Conservar la versión del servidor",
        .editor_conflict_keep_server_detail: "Descarta los cambios en este dispositivo",
        .editor_conflict_restore_hint:
            "Las versiones sobrescritas se pueden restaurar desde el historial de versiones en la web.",

        // Editor - errors
        .editor_error_load:
            "No se pudo cargar este documento. Desliza hacia abajo para actualizar e inténtalo de nuevo.",
        .editor_error_refresh: "No se pudo actualizar. Inténtalo de nuevo.",
        .editor_error_add_subpage: "No se pudo añadir la subpágina. Inténtalo de nuevo.",
        .editor_error_open_link: "No se pudo abrir ese enlace. Inténtalo de nuevo.",
        .editor_error_add_photo: "No se pudo añadir la foto. Inténtalo de nuevo.",
        .editor_unavailable: "Este documento ya no está disponible.",
        .editor_unavailable_with_draft:
            "Este documento ya no está disponible. Tus cambios sin guardar se conservan en este dispositivo.",

        // Editor - slash menu (display labels; matching/filtering uses the
        // stable English `SlashMenuItem.title`, never these keys)
        .editor_slash_menu_a11y: "Menú de tipo de bloque",
        .editor_slash_text: "Texto",
        .editor_slash_heading1: "Título 1",
        .editor_slash_heading2: "Título 2",
        .editor_slash_heading3: "Título 3",
        .editor_slash_bulleted_list: "Lista con viñetas",
        .editor_slash_numbered_list: "Lista numerada",
        .editor_slash_checklist: "Lista de tareas",
        .editor_slash_quote: "Cita",
        .editor_slash_code_block: "Bloque de código",
        .editor_slash_divider: "Separador",
        .editor_slash_photo: "Foto",

        // Editor - formatting bar (icon-only buttons; accessibility labels)
        .editor_format_add_block: "Añadir bloque",
        .editor_format_bold: "Negrita",
        .editor_format_italic: "Cursiva",
        .editor_format_link: "Enlace",
        .editor_format_bulleted_list: "Lista con viñetas",
        .editor_format_checklist: "Lista de tareas",
        .editor_format_quote: "Cita",
        .editor_format_code_block: "Bloque de código",
        .editor_format_insert_photo: "Insertar foto",

        // Editor - link editor sheet
        .editor_link_add_title: "Añadir enlace",
        .editor_link_edit_title: "Editar enlace",
        .editor_link_text_label: "Texto",
        .editor_link_text_placeholder: "Texto del enlace",
        .editor_link_text_helper: "Déjalo vacío para mostrar la dirección misma.",
        .editor_link_address_label: "Dirección",
        .editor_link_address_placeholder: "example.com/page",
        .editor_link_address_error: "Esa dirección no se puede usar como enlace.",
        .editor_link_remove: "Quitar enlace",
        .editor_link_save: "Guardar",
        .editor_link_add: "Añadir",

        // Editor - version history
        .versions_title: "Historial de versiones",
        .versions_current: "Versión actual",
        .versions_restore_web: "Restaurar en la web",
        .versions_error: "No se pudieron cargar las versiones. Inténtalo de nuevo.",
        .versions_empty: "Aún no hay versiones anteriores.",

        // Editor - inline image (MarkdownImageView; accessibility labels only)
        .editor_image_a11y: "Imagen",
        .editor_image_loading_a11y: "Cargando imagen",
        .editor_image_loading_named_a11y: "Cargando imagen: %@",
        .editor_image_external: "Imagen externa · Toca para cargar",
        .editor_image_external_a11y: "Imagen externa de %@. Toca para cargar.",

        // Editor - block canvas accessibility labels (BlockEditorView)
        .editor_add_paragraph_a11y: "Añadir párrafo al final",
        .editor_divider_a11y: "Separador",
        .editor_checklist_done_a11y: "Marcar como hecho",
        .editor_checklist_not_done_a11y: "Marcar como no hecho",
        .editor_presence_count_one: "%d persona aquí",
        .editor_presence_count_other: "%d personas aquí",

        // Profile
        .profile_title: "Perfil",
        .profile_user: "Usuario",
        .profile_prefs: "Preferencias",
        .profile_prefs_footer:
            "Cuando está activado, los documentos que has abierto permanecen legibles en este dispositivo sin conexión.",
        .profile_appearance: "Apariencia",
        .profile_language: "Idioma",
        .profile_notifications: "Notificaciones",
        .profile_work_offline: "Trabajar sin conexión",
        .profile_live_collaboration: "Colaboración en vivo",
        .profile_live_collaboration_footer:
            "La colaboración en vivo sincroniza tus cambios con los demás en tiempo real cuando tu servidor lo admite.",
        .profile_server: "Servidor",
        .profile_server_footer: "La aplicación se conecta a cualquier servidor Schrift usando tu sesión web existente.",
        .profile_connected: "Conectado",
        .profile_offline: "Sin conexión",
        .profile_server_version: "Versión del servidor",
        .profile_about: "Acerca de",
        .profile_version: "Versión",
        .profile_sign_out: "Cerrar sesión",
        .profile_disconnect_title: "¿Desconectar de %@?",
        .profile_disconnect: "Desconectar",
        .profile_disconnect_body: "Deberás iniciar sesión de nuevo para volver a conectarte.",

        // Appearance picker
        .appearance_system: "Sistema",
        .appearance_light: "Claro",
        .appearance_dark: "Oscuro",
    ]
}
