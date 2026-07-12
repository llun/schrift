// AI-generated translation — pending native-speaker review.
enum Strings_zhHans {
    static let table: [L10nKey: String] = [
        .common_cancel: "取消",
        .common_close: "关闭",
        .common_retry: "重试",
        .common_untitled: "无标题文档",
        .common_profile: "个人资料",
        .common_clear_search: "清除搜索",
        .common_you: "(你)",
        .search_results_one: "%d 条结果",
        .search_results_other: "%d 条结果",

        // Offline banner (common chrome)
        .offline_status: "离线",
        .offline_note: "所有文档已保存到此设备",

        // Home
        .home_title: "Schrift",
        .home_search_placeholder: "搜索 %@",
        .home_search_documents: "搜索文档",
        .home_section_pinned: "已置顶",
        .home_section_recent: "最近",
        .home_results: "结果",
        .home_empty_title: "暂无文档",
        .home_empty_body: "你创建的或与你共享的文档会显示在这里。",
        .home_newdoc: "新建文档",
        .home_dismiss_error: "忽略错误",
        .home_select_document: "选择文档",
        .home_error_load: "无法加载文档。下拉刷新以重试。",
        .home_error_search: "搜索失败。请重试。",
        .home_error_create: "无法创建文档。请重试。",

        // Search
        .search_title: "搜索",
        .search_placeholder: "搜索所有文档",
        .search_recent: "最近搜索",
        .search_quick: "快速访问",
        .search_quick_empty: "已置顶的文档会显示在这里。",
        .search_empty_title: "未找到文档",
        .search_empty_body: "没有与 \u{201C}%@\u{201D} 匹配的内容。请尝试其他标题或关键字。",
        .search_error_quick: "无法加载快速访问。请重试。",
        .search_error_search: "搜索失败。请重试。",

        // Shared
        .shared_title: "已共享",
        .shared_with_me: "与我共享",
        .shared_by_me: "我共享的",
        .shared_count_one: "%d 个文档",
        .shared_count_other: "%d 个文档",
        .shared_subtitle_with: "已共享 · %@",
        .shared_subtitle_shared_by: "由 %@ 共享 · %@",
        .shared_subtitle_by: "%@ · 共享于 %@",
        .shared_footer_with:
            "其他人邀请你访问的文档。你的访问权限取决于你在每个文档中的角色。",
        .shared_footer_by:
            "你拥有或已共享的文档。可在每个文档的分享面板中管理谁可以查看。",
        .shared_error_load: "无法加载共享文档。请检查网络连接后重试。",
        .reach_restricted: "受限",
        .reach_connected: "组织内",
        .reach_public: "公开",

        // DocRow (design-system component)
        .docrow_pinned: "已置顶",
        .docrow_shared_with_organization: "已与组织共享",
        .docrow_public: "公开",
        .docrow_available_offline: "可离线使用",

        // LinkReachPill hints (design-system component; labels reuse reach.*)
        .linkreach_hint_restricted: "仅受邀请的人",
        .linkreach_hint_authenticated: "组织内的任何人",
        .linkreach_hint_public: "拥有链接的任何人",

        // ShareMemberRow (design-system component)
        .sharemember_role_a11y: "角色：%@",
        .sharemember_role_hint: "双击以更改角色",

        // Connect
        .connect_hero_title: "欢迎使用 Schrift",
        .connect_hero_subtitle: "连接到任意服务器，实时写作、整理和协作。",
        .connect_server_label: "服务器",
        .connect_server_placeholder: "schrift.example.org",
        .connect_server_helper: "应用使用你现有的会话登录，不会存储密码。",
        .connect_sign_in: "登录",
        .connect_sign_in_to: "登录到 %@",
        .connect_recent_servers: "最近的服务器",
        .connect_error_invalid_server: "请输入有效的服务器地址。",
        .connect_error_sign_in_failed: "无法确认登录。请重试。",

        // Reauthentication
        .reauth_title: "会话已过期",
        .reauth_error_sign_in_failed: "无法确认登录。请重试。",

        // Options sheet
        .options_title: "选项",
        .options_pin: "置顶",
        .options_unpin: "取消置顶",
        .options_pinned: "已置顶",
        .options_copy_link: "复制链接",
        .options_share: "分享",
        .options_delete_document: "删除文档",
        .options_delete_confirm_title: "删除此文档？",
        .options_delete: "删除",
        .options_error_toggle_favorite: "无法更新收藏。请重试。",
        .options_error_delete: "无法删除文档。请重试。",

        // Share sheet
        .share_title: "分享",
        .share_invite_placeholder: "按姓名或电子邮件邀请",
        .share_members_one: "已与 %d 人共享",
        .share_members_other: "已与 %d 人共享",
        .share_add_people: "添加成员",
        .share_no_people_found: "未找到成员",
        .share_link_parameters: "链接参数",
        .share_change_link_access: "更改链接访问权限",
        .share_copy_link: "复制链接",
        .share_change_role: "更改角色",
        .share_remove: "移除",
        .share_link_access: "链接访问权限",
        .share_reach_authenticated: "组织内的任何人",
        .share_reach_public: "拥有链接的任何人",
        .share_role_reader: "阅读者",
        .share_role_commenter: "评论者",
        .share_role_editor: "编辑者",
        .share_role_administrator: "管理员",
        .share_role_owner: "所有者",
        .share_role_pending: "%@ (待接受)",
        .share_error_load: "无法加载成员。下拉刷新以重试。",
        .share_error_search: "搜索失败。请重试。",
        .share_error_invite: "无法添加成员。请重试。",
        .share_error_update_role: "无法更新角色。请重试。",
        .share_error_remove_member: "无法移除成员。请重试。",
        .share_error_update_link: "无法更新链接设置。请重试。",

        // Editor - save bar
        .editor_save: "保存",
        .editor_save_now_a11y: "立即保存",
        .editor_saving: "正在保存…",
        .editor_saved: "已保存",
        .editor_save_failed: "无法保存 · 重试",
        .editor_save_failed_a11y: "保存失败。重试",

        // Editor - reading surface / chrome
        .editor_offline_local_copy: "正在阅读保存在此设备上的副本",
        .editor_update_available: "文档已更新 · 点按以刷新",
        .editor_update_available_a11y: "文档已更新。点按以刷新。",
        .editor_uploading_photo: "正在上传照片…",
        .editor_uploading_photo_a11y: "正在上传照片",
        .editor_empty_title: "空文档",
        .editor_empty_body: "此文档还没有任何内容。",
        .editor_start_writing: "开始写作",
        .editor_subpages_title: "子页面",
        .editor_subpages_title_count: "子页面 · %d",
        .editor_subpages_empty: "通过创建子页面来整理此文档。",
        .editor_add_subpage: "添加子页面",
        .editor_action_done: "完成",
        .editor_action_edit: "编辑",
        .editor_action_share: "分享",
        .editor_action_options: "选项",

        // Editor - sync caption (reading-surface header)
        .editor_sync_save_failed: "无法保存 · 点按以重试",
        .editor_sync_save_failed_a11y: "无法保存。点按以重试。",
        .editor_sync_saved_on_device: "已保存到此设备",
        .editor_sync_edited_just_now: "刚刚编辑",
        .editor_sync_just_now: "刚刚同步",
        .editor_sync_ago: "同步于 %@",
        .editor_sync_not_synced_yet: "尚未同步",

        // Editor - errors
        .editor_error_load: "无法加载此文档。下拉刷新以重试。",
        .editor_error_refresh: "无法刷新。请重试。",
        .editor_error_add_subpage: "无法添加子页面。请重试。",
        .editor_error_open_link: "无法打开该链接。请重试。",
        .editor_error_add_photo: "无法添加照片。请重试。",
        .editor_unavailable: "此文档已不可用。",
        .editor_unavailable_with_draft:
            "此文档已不可用。你未保存的更改已保留在此设备上。",

        // Editor - slash menu (display labels; matching/filtering uses the
        // stable English `SlashMenuItem.title`, never these keys)
        .editor_slash_menu_a11y: "块类型菜单",
        .editor_slash_text: "文本",
        .editor_slash_heading1: "标题 1",
        .editor_slash_heading2: "标题 2",
        .editor_slash_heading3: "标题 3",
        .editor_slash_bulleted_list: "项目符号列表",
        .editor_slash_numbered_list: "编号列表",
        .editor_slash_checklist: "清单",
        .editor_slash_quote: "引用",
        .editor_slash_code_block: "代码块",
        .editor_slash_divider: "分隔线",
        .editor_slash_photo: "照片",

        // Editor - formatting bar (icon-only buttons; accessibility labels)
        .editor_format_add_block: "添加块",
        .editor_format_bold: "粗体",
        .editor_format_italic: "斜体",
        .editor_format_link: "链接",
        .editor_format_bulleted_list: "项目符号列表",
        .editor_format_checklist: "清单",
        .editor_format_quote: "引用",
        .editor_format_code_block: "代码块",
        .editor_format_insert_photo: "插入照片",

        // Editor - link editor sheet
        .editor_link_add_title: "添加链接",
        .editor_link_edit_title: "编辑链接",
        .editor_link_text_label: "文本",
        .editor_link_text_placeholder: "链接文本",
        .editor_link_text_helper: "留空则显示地址本身。",
        .editor_link_address_label: "地址",
        .editor_link_address_placeholder: "example.com/page",
        .editor_link_address_error: "该地址无法用作链接。",
        .editor_link_remove: "移除链接",
        .editor_link_save: "保存",
        .editor_link_add: "添加",

        // Editor - version history
        .versions_title: "版本历史",
        .versions_current: "当前版本",
        .versions_restore_web: "在网页端恢复",
        .versions_error: "无法加载版本。请重试。",
        .versions_empty: "暂无早期版本。",

        // Editor - inline image (MarkdownImageView; accessibility labels only)
        .editor_image_a11y: "图片",
        .editor_image_loading_a11y: "正在加载图片",
        .editor_image_loading_named_a11y: "正在加载图片：%@",

        // Editor - block canvas accessibility labels (BlockEditorView)
        .editor_add_paragraph_a11y: "在末尾添加段落",
        .editor_divider_a11y: "分隔线",
        .editor_checklist_done_a11y: "标记为已完成",
        .editor_checklist_not_done_a11y: "标记为未完成",

        // Profile
        .profile_title: "个人资料",
        .profile_user: "用户",
        .profile_prefs: "偏好设置",
        .profile_prefs_footer: "开启后，您打开过的文档即使离线也可以在此设备上阅读。",
        .profile_appearance: "外观",
        .profile_language: "语言",
        .profile_notifications: "通知",
        .profile_work_offline: "离线工作",
        .profile_server: "服务器",
        .profile_server_footer: "该应用会使用您现有的网页会话连接到任意 Schrift 服务器。",
        .profile_connected: "已连接",
        .profile_offline: "离线",
        .profile_server_version: "服务器版本",
        .profile_about: "关于",
        .profile_version: "版本",
        .profile_sign_out: "退出登录",
        .profile_disconnect_title: "要断开与 %@ 的连接吗？",
        .profile_disconnect: "断开连接",
        .profile_disconnect_body: "您需要重新登录才能再次连接。",

        // Appearance picker
        .appearance_system: "系统",
        .appearance_light: "浅色",
        .appearance_dark: "深色",
    ]
}
