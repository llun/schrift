// AI-generated translation — pending native-speaker review.
enum Strings_zhHant {
    static let table: [L10nKey: String] = [
        .common_cancel: "取消",
        .common_close: "關閉",
        .common_retry: "再試一次",
        .common_untitled: "未命名文件",
        .common_profile: "個人檔案",
        .common_clear_search: "清除搜尋",
        .common_you: "(你)",
        .search_results_one: "%d 個結果",
        .search_results_other: "%d 個結果",

        // Offline banner (common chrome)
        .offline_status: "離線",
        .offline_note: "所有文件已儲存在此裝置",

        // Home
        .home_title: "Schrift",
        .home_search_placeholder: "搜尋 %@",
        .home_search_documents: "搜尋文件",
        .home_section_pinned: "已釘選",
        .home_section_recent: "最近",
        .home_results: "結果",
        .home_empty_title: "尚無文件",
        .home_empty_body: "你建立或別人與你共用的文件會顯示在這裡。",
        .home_newdoc: "新文件",
        .home_dismiss_error: "關閉錯誤",
        .home_select_document: "選擇文件",
        .home_error_load: "無法載入文件。下拉重新整理以再試一次。",
        .home_error_search: "搜尋失敗。請再試一次。",
        .home_error_create: "無法建立文件。請再試一次。",

        // Search
        .search_title: "搜尋",
        .search_placeholder: "搜尋所有文件",
        .search_recent: "最近的搜尋",
        .search_quick: "快速存取",
        .search_quick_empty: "已釘選的文件會顯示在這裡。",
        .search_empty_title: "找不到文件",
        .search_empty_body: "沒有符合 \u{201C}%@\u{201D} 的項目。請嘗試其他標題或關鍵字。",
        .search_error_quick: "無法載入快速存取。請再試一次。",
        .search_error_search: "搜尋失敗。請再試一次。",

        // Shared
        .shared_title: "共用",
        .shared_count_one: "%d 個文件",
        .shared_count_other: "%d 個文件",
        .shared_subtitle_with: "共用 · %@",
        .shared_subtitle_shared_by: "由 %@ 共用 · %@",
        .shared_footer_with:
            "其他人邀請你參與的文件。你的存取權取決於你在各文件中的角色。",
        .shared_error_load: "無法載入共用文件。請檢查你的連線並再試一次。",
        .reach_restricted: "受限",
        .reach_connected: "已連線",
        .reach_public: "公開",

        // DocRow (design-system component)
        .docrow_pinned: "已釘選",
        .docrow_shared_with_organization: "與機構共用",
        .docrow_public: "公開",
        .docrow_available_offline: "可離線使用",

        // LinkReachPill hints (design-system component; labels reuse reach.*)
        .linkreach_hint_restricted: "僅限受邀者",
        .linkreach_hint_authenticated: "機構內任何人",
        .linkreach_hint_public: "擁有連結的任何人",

        // ShareMemberRow (design-system component)
        .sharemember_role_a11y: "角色：%@",
        .sharemember_role_hint: "點兩下以變更角色",

        // Connect
        .connect_hero_title: "歡迎使用 Schrift",
        .connect_hero_subtitle: "連接任何伺服器，即時書寫、整理與協作。",
        .connect_server_label: "伺服器",
        .connect_server_placeholder: "schrift.example.org",
        .connect_server_helper: "此應用程式會使用你現有的工作階段登入，不會儲存密碼。",
        .connect_sign_in: "登入",
        .connect_sign_in_to: "登入 %@",
        .connect_recent_servers: "最近的伺服器",
        .connect_error_invalid_server: "請輸入有效的伺服器位址。",
        .connect_error_sign_in_failed: "無法確認登入。請再試一次。",

        // Reauthentication
        .reauth_title: "工作階段已過期",
        .reauth_error_sign_in_failed: "無法確認登入。請再試一次。",

        // Options sheet
        .options_title: "選項",
        .options_pin: "釘選",
        .options_unpin: "取消釘選",
        .options_pinned: "已釘選",
        .options_copy_link: "複製連結",
        .options_share: "分享",
        .options_delete_document: "刪除文件",
        .options_delete_confirm_title: "要刪除此文件嗎？",
        .options_delete: "刪除",
        .options_error_toggle_favorite: "無法更新最愛。請再試一次。",
        .options_error_delete: "無法刪除文件。請再試一次。",

        // Share sheet
        .share_title: "分享",
        .share_invite_placeholder: "以姓名或電子郵件邀請",
        .share_members_one: "已與 %d 人共用",
        .share_members_other: "已與 %d 人共用",
        .share_add_people: "新增成員",
        .share_no_people_found: "找不到成員",
        .share_link_parameters: "連結參數",
        .share_change_link_access: "變更連結存取權",
        .share_copy_link: "複製連結",
        .share_change_role: "變更角色",
        .share_remove: "移除",
        .share_link_access: "連結存取權",
        .share_reach_authenticated: "機構內的任何人",
        .share_reach_public: "擁有連結的任何人",
        .share_role_reader: "檢視者",
        .share_role_commenter: "註解者",
        .share_role_editor: "編輯者",
        .share_role_administrator: "管理員",
        .share_role_owner: "擁有者",
        .share_role_pending: "%@ (待處理)",
        .share_error_load: "無法載入成員。下拉重新整理以再試一次。",
        .share_error_search: "搜尋失敗。請再試一次。",
        .share_error_invite: "無法新增成員。請再試一次。",
        .share_error_update_role: "無法更新角色。請再試一次。",
        .share_error_remove_member: "無法移除成員。請再試一次。",
        .share_error_update_link: "無法更新連結設定。請再試一次。",

        // Editor - save bar
        .editor_save: "儲存",
        .editor_save_now_a11y: "立即儲存",
        .editor_saving: "儲存中…",
        .editor_saved: "已儲存",
        .editor_save_failed: "無法儲存 · 重試",
        .editor_save_failed_a11y: "儲存失敗。重試",

        // Editor - reading surface / chrome
        .editor_offline_local_copy: "正在閱讀儲存在此裝置的副本",
        .editor_update_available: "文件已更新 · 點按以重新整理",
        .editor_update_available_a11y: "文件已更新。點按以重新整理。",
        .editor_uploading_photo: "正在上傳照片…",
        .editor_uploading_photo_a11y: "正在上傳照片",
        .editor_empty_title: "空白文件",
        .editor_empty_body: "此文件尚無任何內容。",
        .editor_start_writing: "開始書寫",
        .editor_subpages_title: "子頁面",
        .editor_subpages_title_count: "子頁面 · %d",
        .editor_subpages_empty: "建立子頁面來整理此文件。",
        .editor_add_subpage: "新增子頁面",
        .editor_action_done: "完成",
        .editor_action_edit: "編輯",
        .editor_action_share: "分享",
        .editor_action_options: "選項",

        // Editor - sync caption (reading-surface header)
        .editor_sync_save_failed: "無法儲存 · 點按以重試",
        .editor_sync_save_failed_a11y: "無法儲存。點按以重試。",
        .editor_sync_saved_on_device: "已儲存在此裝置",
        .editor_sync_pending_sync: "已儲存到此裝置 · 連線後同步",
        .editor_sync_edited_just_now: "剛剛編輯",
        .editor_sync_just_now: "剛剛同步",
        .editor_sync_ago: "%@ 同步",
        .editor_sync_not_synced_yet: "尚未同步",

        // Editor - errors
        .editor_error_load: "無法載入此文件。下拉重新整理以再試一次。",
        .editor_error_refresh: "無法重新整理。請再試一次。",
        .editor_error_add_subpage: "無法新增子頁面。請再試一次。",
        .editor_error_open_link: "無法開啟該連結。請再試一次。",
        .editor_error_add_photo: "無法新增照片。請再試一次。",
        .editor_unavailable: "此文件已無法使用。",
        .editor_unavailable_with_draft:
            "此文件已無法使用。你未儲存的變更會保留在此裝置。",

        // Editor - slash menu (display labels; matching/filtering uses the
        // stable English `SlashMenuItem.title`, never these keys)
        .editor_slash_menu_a11y: "區塊類型選單",
        .editor_slash_text: "文字",
        .editor_slash_heading1: "標題 1",
        .editor_slash_heading2: "標題 2",
        .editor_slash_heading3: "標題 3",
        .editor_slash_bulleted_list: "項目符號清單",
        .editor_slash_numbered_list: "編號清單",
        .editor_slash_checklist: "核取清單",
        .editor_slash_quote: "引文",
        .editor_slash_code_block: "程式碼區塊",
        .editor_slash_divider: "分隔線",
        .editor_slash_photo: "照片",

        // Editor - formatting bar (icon-only buttons; accessibility labels)
        .editor_format_add_block: "新增區塊",
        .editor_format_bold: "粗體",
        .editor_format_italic: "斜體",
        .editor_format_link: "連結",
        .editor_format_bulleted_list: "項目符號清單",
        .editor_format_checklist: "核取清單",
        .editor_format_quote: "引文",
        .editor_format_code_block: "程式碼區塊",
        .editor_format_insert_photo: "插入照片",

        // Editor - link editor sheet
        .editor_link_add_title: "新增連結",
        .editor_link_edit_title: "編輯連結",
        .editor_link_text_label: "文字",
        .editor_link_text_placeholder: "連結文字",
        .editor_link_text_helper: "留空則顯示位址本身。",
        .editor_link_address_label: "位址",
        .editor_link_address_placeholder: "example.com/page",
        .editor_link_address_error: "該位址無法作為連結使用。",
        .editor_link_remove: "移除連結",
        .editor_link_save: "儲存",
        .editor_link_add: "新增",

        // Editor - version history
        .versions_title: "版本歷史",
        .versions_current: "目前版本",
        .versions_restore_web: "在網頁上還原",
        .versions_error: "無法載入版本。請再試一次。",
        .versions_empty: "尚無較早的版本。",

        // Editor - inline image (MarkdownImageView; accessibility labels only)
        .editor_image_a11y: "圖片",
        .editor_image_loading_a11y: "正在載入圖片",
        .editor_image_loading_named_a11y: "正在載入圖片：%@",

        // Editor - block canvas accessibility labels (BlockEditorView)
        .editor_add_paragraph_a11y: "在結尾新增段落",
        .editor_divider_a11y: "分隔線",
        .editor_checklist_done_a11y: "標示為完成",
        .editor_checklist_not_done_a11y: "標示為未完成",

        // Profile
        .profile_title: "個人檔案",
        .profile_user: "使用者",
        .profile_prefs: "偏好設定",
        .profile_prefs_footer: "開啟後，您開啟過的文件即使離線也能在此裝置上閱讀。",
        .profile_appearance: "外觀",
        .profile_language: "語言",
        .profile_notifications: "通知",
        .profile_work_offline: "離線工作",
        .profile_server: "伺服器",
        .profile_server_footer: "該應用程式會使用您現有的網頁工作階段連線至任何 Schrift 伺服器。",
        .profile_connected: "已連線",
        .profile_offline: "離線",
        .profile_server_version: "伺服器版本",
        .profile_about: "關於",
        .profile_version: "版本",
        .profile_sign_out: "登出",
        .profile_disconnect_title: "要中斷與 %@ 的連線嗎？",
        .profile_disconnect: "中斷連線",
        .profile_disconnect_body: "您需要重新登入才能再次連線。",

        // Appearance picker
        .appearance_system: "系統",
        .appearance_light: "淺色",
        .appearance_dark: "深色",
    ]
}
