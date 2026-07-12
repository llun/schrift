import Foundation

// AI-generated translation — pending native-speaker review.
enum Strings_pt {
    static let table: [L10nKey: String] = [
        .common_cancel: "Cancelar",
        .common_close: "Fechar",
        .common_retry: "Tentar novamente",
        .common_untitled: "Documento sem título",
        .common_profile: "Perfil",
        .common_clear_search: "Limpar pesquisa",
        .common_you: "(você)",
        .search_results_one: "%d resultado",
        .search_results_other: "%d resultados",

        // Offline banner (common chrome)
        .offline_status: "Offline",
        .offline_note: "Todos os documentos guardados neste dispositivo",

        // Home
        .home_title: "Schrift",
        .home_search_placeholder: "Pesquisar %@",
        .home_search_documents: "Pesquisar documentos",
        .home_section_pinned: "Fixados",
        .home_section_recent: "Recentes",
        .home_results: "Resultados",
        .home_empty_title: "Ainda não há documentos",
        .home_empty_body: "Os documentos que criar ou que forem partilhados consigo aparecerão aqui.",
        .home_newdoc: "Novo documento",
        .home_dismiss_error: "Ignorar erro",
        .home_select_document: "Selecionar um documento",
        .home_error_load: "Não foi possível carregar os documentos. Puxe para atualizar e tente novamente.",
        .home_error_search: "A pesquisa falhou. Tente novamente.",
        .home_error_create: "Não foi possível criar um documento. Tente novamente.",

        // Search
        .search_title: "Pesquisa",
        .search_placeholder: "Pesquisar em todos os documentos",
        .search_recent: "Pesquisas recentes",
        .search_quick: "Acesso rápido",
        .search_quick_empty: "Os documentos fixados aparecerão aqui.",
        .search_empty_title: "Nenhum documento encontrado",
        .search_empty_body: "Nada corresponde a \u{201C}%@\u{201D}. Tente outro título ou palavra-chave.",
        .search_error_quick: "Não foi possível carregar o acesso rápido. Tente novamente.",
        .search_error_search: "A pesquisa falhou. Tente novamente.",

        // Shared
        .shared_title: "Partilhados",
        .shared_count_one: "%d documento",
        .shared_count_other: "%d documentos",
        .shared_subtitle_with: "Partilhado · %@",
        .shared_subtitle_shared_by: "Partilhado por %@ · %@",
        .shared_footer_with:
            "Documentos para os quais outras pessoas o convidaram. O seu acesso depende da sua função em cada um.",
        .shared_error_load:
            "Não foi possível carregar os documentos partilhados. Verifique a sua ligação e tente novamente.",
        .reach_restricted: "Restrito",
        .reach_connected: "Ligado",
        .reach_public: "Público",

        // DocRow (design-system component)
        .docrow_pinned: "Fixado",
        .docrow_shared_with_organization: "Partilhado com a organização",
        .docrow_public: "Público",
        .docrow_available_offline: "Disponível offline",

        // LinkReachPill hints (design-system component; labels reuse reach.*)
        .linkreach_hint_restricted: "Apenas pessoas convidadas",
        .linkreach_hint_authenticated: "Qualquer pessoa na organização",
        .linkreach_hint_public: "Qualquer pessoa com o link",

        // ShareMemberRow (design-system component)
        .sharemember_role_a11y: "Função: %@",
        .sharemember_role_hint: "Toque duas vezes para alterar a função",

        // Connect
        .connect_hero_title: "Bem-vindo ao Schrift",
        .connect_hero_subtitle: "Ligue-se a qualquer servidor para escrever, organizar e colaborar — em tempo real.",
        .connect_server_label: "Servidor",
        .connect_server_placeholder: "schrift.example.org",
        .connect_server_helper: "A aplicação inicia sessão com a sua sessão existente — sem palavras-passe guardadas.",
        .connect_sign_in: "Iniciar sessão",
        .connect_sign_in_to: "Iniciar sessão em %@",
        .connect_recent_servers: "Servidores recentes",
        .connect_error_invalid_server: "Introduza um endereço de servidor válido.",
        .connect_error_sign_in_failed: "Não foi possível confirmar o início de sessão. Tente novamente.",

        // Reauthentication
        .reauth_title: "Sessão expirada",
        .reauth_error_sign_in_failed: "Não foi possível confirmar o início de sessão. Tente novamente.",

        // Options sheet
        .options_title: "Opções",
        .options_pin: "Fixar",
        .options_unpin: "Desafixar",
        .options_pinned: "Fixado",
        .options_copy_link: "Copiar link",
        .options_share: "Partilhar",
        .options_delete_document: "Eliminar documento",
        .options_delete_confirm_title: "Eliminar este documento?",
        .options_delete: "Eliminar",
        .options_error_toggle_favorite: "Não foi possível atualizar o favorito. Tente novamente.",
        .options_error_delete: "Não foi possível eliminar o documento. Tente novamente.",

        // Share sheet
        .share_title: "Partilhar",
        .share_invite_placeholder: "Convidar por nome ou e-mail",
        .share_members_one: "Partilhado com %d pessoa",
        .share_members_other: "Partilhado com %d pessoas",
        .share_add_people: "Adicionar pessoas",
        .share_no_people_found: "Nenhuma pessoa encontrada",
        .share_link_parameters: "Parâmetros do link",
        .share_change_link_access: "Alterar o acesso do link",
        .share_copy_link: "Copiar link",
        .share_change_role: "Alterar função",
        .share_remove: "Remover",
        .share_link_access: "Acesso do link",
        .share_reach_authenticated: "Qualquer pessoa na organização",
        .share_reach_public: "Qualquer pessoa com o link",
        .share_role_reader: "Leitor",
        .share_role_commenter: "Comentador",
        .share_role_editor: "Editor",
        .share_role_administrator: "Administrador",
        .share_role_owner: "Proprietário",
        .share_role_pending: "%@ (Pendente)",
        .share_error_load: "Não foi possível carregar os membros. Puxe para atualizar e tente novamente.",
        .share_error_search: "A pesquisa falhou. Tente novamente.",
        .share_error_invite: "Não foi possível adicionar o membro. Tente novamente.",
        .share_error_update_role: "Não foi possível atualizar a função. Tente novamente.",
        .share_error_remove_member: "Não foi possível remover o membro. Tente novamente.",
        .share_error_update_link: "Não foi possível atualizar as definições do link. Tente novamente.",

        // Editor - save bar
        .editor_save: "Guardar",
        .editor_save_now_a11y: "Guardar agora",
        .editor_saving: "A guardar…",
        .editor_saved: "Guardado",
        .editor_save_failed: "Não foi possível guardar · Tentar novamente",
        .editor_save_failed_a11y: "Falha ao guardar. Tentar novamente",

        // Editor - reading surface / chrome
        .editor_offline_local_copy: "A ler a cópia guardada neste dispositivo",
        .editor_update_available: "Documento atualizado · toque para atualizar",
        .editor_update_available_a11y: "Documento atualizado. Toque para atualizar.",
        .editor_uploading_photo: "A carregar fotografia…",
        .editor_uploading_photo_a11y: "A carregar fotografia",
        .editor_empty_title: "Documento vazio",
        .editor_empty_body: "Este documento ainda não tem conteúdo.",
        .editor_start_writing: "Começar a escrever",
        .editor_subpages_title: "Subpáginas",
        .editor_subpages_title_count: "Subpáginas · %d",
        .editor_subpages_empty: "Organize este documento criando subpáginas.",
        .editor_add_subpage: "Adicionar uma subpágina",
        .editor_action_done: "Concluído",
        .editor_action_edit: "Editar",
        .editor_action_share: "Partilhar",
        .editor_action_options: "Opções",

        // Editor - sync caption (reading-surface header)
        .editor_sync_save_failed: "Não foi possível guardar · toque para tentar novamente",
        .editor_sync_save_failed_a11y: "Não foi possível guardar. Toque para tentar novamente.",
        .editor_sync_saved_on_device: "Guardado neste dispositivo",
        .editor_sync_pending_sync: "Salvo neste dispositivo · sincroniza quando on-line",
        .editor_sync_edited_just_now: "Editado agora mesmo",
        .editor_sync_just_now: "Sincronizado agora mesmo",
        .editor_sync_ago: "Sincronizado %@",
        .editor_sync_not_synced_yet: "Ainda não sincronizado",

        // Editor - errors
        .editor_error_load: "Não foi possível carregar este documento. Puxe para atualizar e tente novamente.",
        .editor_error_refresh: "Não foi possível atualizar. Tente novamente.",
        .editor_error_add_subpage: "Não foi possível adicionar a subpágina. Tente novamente.",
        .editor_error_open_link: "Não foi possível abrir esse link. Tente novamente.",
        .editor_error_add_photo: "Não foi possível adicionar a fotografia. Tente novamente.",
        .editor_unavailable: "Este documento já não está disponível.",
        .editor_unavailable_with_draft:
            "Este documento já não está disponível. As suas alterações não guardadas são mantidas neste dispositivo.",

        // Editor - slash menu (display labels; matching/filtering uses the
        // stable English `SlashMenuItem.title`, never these keys)
        .editor_slash_menu_a11y: "Menu de tipo de bloco",
        .editor_slash_text: "Texto",
        .editor_slash_heading1: "Título 1",
        .editor_slash_heading2: "Título 2",
        .editor_slash_heading3: "Título 3",
        .editor_slash_bulleted_list: "Lista com marcadores",
        .editor_slash_numbered_list: "Lista numerada",
        .editor_slash_checklist: "Lista de verificação",
        .editor_slash_quote: "Citação",
        .editor_slash_code_block: "Bloco de código",
        .editor_slash_divider: "Divisor",
        .editor_slash_photo: "Fotografia",

        // Editor - formatting bar (icon-only buttons; accessibility labels)
        .editor_format_add_block: "Adicionar bloco",
        .editor_format_bold: "Negrito",
        .editor_format_italic: "Itálico",
        .editor_format_link: "Link",
        .editor_format_bulleted_list: "Lista com marcadores",
        .editor_format_checklist: "Lista de verificação",
        .editor_format_quote: "Citação",
        .editor_format_code_block: "Bloco de código",
        .editor_format_insert_photo: "Inserir fotografia",

        // Editor - link editor sheet
        .editor_link_add_title: "Adicionar link",
        .editor_link_edit_title: "Editar link",
        .editor_link_text_label: "Texto",
        .editor_link_text_placeholder: "Texto do link",
        .editor_link_text_helper: "Deixe vazio para mostrar o próprio endereço.",
        .editor_link_address_label: "Endereço",
        .editor_link_address_placeholder: "example.com/page",
        .editor_link_address_error: "Esse endereço não pode ser usado como link.",
        .editor_link_remove: "Remover link",
        .editor_link_save: "Guardar",
        .editor_link_add: "Adicionar",

        // Editor - version history
        .versions_title: "Histórico de versões",
        .versions_current: "Versão atual",
        .versions_restore_web: "Restaurar na web",
        .versions_error: "Não foi possível carregar as versões. Tente novamente.",
        .versions_empty: "Ainda não há versões anteriores.",

        // Editor - inline image (MarkdownImageView; accessibility labels only)
        .editor_image_a11y: "Imagem",
        .editor_image_loading_a11y: "A carregar imagem",
        .editor_image_loading_named_a11y: "A carregar imagem: %@",

        // Editor - block canvas accessibility labels (BlockEditorView)
        .editor_add_paragraph_a11y: "Adicionar parágrafo no final",
        .editor_divider_a11y: "Divisor",
        .editor_checklist_done_a11y: "Marcar como concluído",
        .editor_checklist_not_done_a11y: "Marcar como não concluído",

        // Profile
        .profile_title: "Perfil",
        .profile_user: "Usuário",
        .profile_prefs: "Preferências",
        .profile_prefs_footer:
            "Quando ativado, os documentos que você abriu continuam legíveis neste dispositivo sem conexão.",
        .profile_appearance: "Aparência",
        .profile_language: "Idioma",
        .profile_notifications: "Notificações",
        .profile_work_offline: "Trabalhar offline",
        .profile_server: "Servidor",
        .profile_server_footer: "O aplicativo se conecta a qualquer servidor Schrift usando sua sessão web existente.",
        .profile_connected: "Conectado",
        .profile_offline: "Offline",
        .profile_server_version: "Versão do servidor",
        .profile_about: "Sobre",
        .profile_version: "Versão",
        .profile_sign_out: "Sair",
        .profile_disconnect_title: "Desconectar de %@?",
        .profile_disconnect: "Desconectar",
        .profile_disconnect_body: "Você precisará entrar novamente para se reconectar.",

        // Appearance picker
        .appearance_system: "Sistema",
        .appearance_light: "Claro",
        .appearance_dark: "Escuro",
    ]
}
