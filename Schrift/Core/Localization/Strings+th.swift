import Foundation

// AI-generated translation — pending native-speaker review.
enum Strings_th {
    static let table: [L10nKey: String] = [
        .common_done: "เสร็จ",
        .common_cancel: "ยกเลิก",
        .common_retry: "ลองอีกครั้ง",
        .common_untitled: "เอกสารไม่มีชื่อ",
        .common_profile: "โปรไฟล์",
        .common_clear_search: "ล้างการค้นหา",
        .common_you: "(คุณ)",
        .search_results_one: "%d ผลลัพธ์",
        .search_results_other: "%d ผลลัพธ์",

        // Offline banner (common chrome)
        .offline_status: "ออฟไลน์",
        .offline_note: "เอกสารทั้งหมดบันทึกไว้บนอุปกรณ์นี้แล้ว",

        // Home
        .home_title: "Schrift",
        .home_search_placeholder: "ค้นหา %@",
        .home_search_documents: "ค้นหาเอกสาร",
        .home_filter_all: "ทั้งหมด",
        .home_filter_shared: "ที่แชร์",
        .home_filter_pinned: "ปักหมุดแล้ว",
        .home_section_pinned: "ปักหมุดแล้ว",
        .home_section_recent: "ล่าสุด",
        .home_section_shared: "ที่แชร์กับฉัน",
        .home_results: "ผลลัพธ์",
        .home_empty_title: "ยังไม่มีเอกสาร",
        .home_empty_body: "เอกสารที่คุณสร้างหรือที่ถูกแชร์กับคุณจะปรากฏที่นี่",
        .home_newdoc: "เอกสารใหม่",
        .home_pin: "ปักหมุด",
        .home_unpin: "เลิกปักหมุด",
        .home_dismiss_error: "ปิดข้อผิดพลาด",
        .home_document_options: "ตัวเลือกเอกสาร",
        .home_select_document: "เลือกเอกสาร",
        .home_error_load: "โหลดเอกสารไม่ได้ ดึงลงเพื่อรีเฟรชแล้วลองอีกครั้ง",
        .home_error_search: "ค้นหาไม่สำเร็จ โปรดลองอีกครั้ง",
        .home_error_create: "สร้างเอกสารไม่ได้ โปรดลองอีกครั้ง",
        .home_error_favorite: "อัปเดตรายการโปรดไม่ได้ โปรดลองอีกครั้ง",

        // Search
        .search_title: "ค้นหา",
        .search_placeholder: "ค้นหาเอกสารทั้งหมด",
        .search_recent: "การค้นหาล่าสุด",
        .search_quick: "เข้าถึงด่วน",
        .search_quick_empty: "เอกสารที่ปักหมุดแล้วจะปรากฏที่นี่",
        .search_empty_title: "ไม่พบเอกสาร",
        .search_empty_body: "ไม่มีรายการที่ตรงกับ \u{201C}%@\u{201D} ลองใช้ชื่อหรือคำสำคัญอื่น",
        .search_error_quick: "โหลดการเข้าถึงด่วนไม่ได้ โปรดลองอีกครั้ง",
        .search_error_search: "ค้นหาไม่สำเร็จ โปรดลองอีกครั้ง",

        // Shared
        .shared_title: "ที่แชร์",
        .shared_with_me: "ที่แชร์กับฉัน",
        .shared_by_me: "ที่ฉันแชร์",
        .shared_count_one: "เอกสาร %d ฉบับ",
        .shared_count_other: "เอกสาร %d ฉบับ",
        .shared_subtitle_with: "ที่แชร์ · %@",
        .shared_subtitle_by: "%@ · แชร์ %@",
        .shared_footer_with:
            "เอกสารที่ผู้อื่นเชิญคุณเข้าร่วม สิทธิ์การเข้าถึงของคุณขึ้นอยู่กับบทบาทของคุณในแต่ละเอกสาร",
        .shared_footer_by:
            "เอกสารที่คุณเป็นเจ้าของหรือได้แชร์ไว้ จัดการผู้ที่สามารถเห็นเอกสารได้จากชีตแชร์ของแต่ละเอกสาร",
        .shared_error_load: "โหลดเอกสารที่แชร์ไม่ได้ ตรวจสอบการเชื่อมต่อแล้วลองอีกครั้ง",
        .reach_restricted: "จำกัด",
        .reach_connected: "เชื่อมต่อ",
        .reach_public: "สาธารณะ",

        // DocRow (design-system component)
        .docrow_pinned: "ปักหมุดแล้ว",
        .docrow_shared_with_organization: "แชร์กับองค์กร",
        .docrow_public: "สาธารณะ",
        .docrow_more_options: "ตัวเลือกเพิ่มเติม",
        .docrow_available_offline: "ใช้งานได้แบบออฟไลน์",

        // LinkReachPill hints (design-system component; labels reuse reach.*)
        .linkreach_hint_restricted: "เฉพาะผู้ที่ได้รับเชิญ",
        .linkreach_hint_authenticated: "ทุกคนในองค์กร",
        .linkreach_hint_public: "ทุกคนที่มีลิงก์",

        // ShareMemberRow (design-system component)
        .sharemember_role_a11y: "บทบาท: %@",
        .sharemember_role_hint: "แตะสองครั้งเพื่อเปลี่ยนบทบาท",

        // Connect
        .connect_hero_title: "ยินดีต้อนรับสู่ Schrift",
        .connect_hero_subtitle: "เชื่อมต่อกับเซิร์ฟเวอร์ใดก็ได้เพื่อเขียน จัดระเบียบ และทำงานร่วมกัน — แบบเรียลไทม์",
        .connect_server_label: "เซิร์ฟเวอร์",
        .connect_server_placeholder: "schrift.example.org",
        .connect_server_helper: "แอปลงชื่อเข้าใช้ด้วยเซสชันที่คุณมีอยู่ — ไม่มีการเก็บรหัสผ่าน",
        .connect_sign_in: "ลงชื่อเข้าใช้",
        .connect_sign_in_to: "ลงชื่อเข้าใช้ %@",
        .connect_recent_servers: "เซิร์ฟเวอร์ล่าสุด",
        .connect_error_invalid_server: "ป้อนที่อยู่เซิร์ฟเวอร์ที่ถูกต้อง",
        .connect_error_sign_in_failed: "ยืนยันการลงชื่อเข้าใช้ไม่ได้ โปรดลองอีกครั้ง",

        // Reauthentication
        .reauth_title: "เซสชันหมดอายุ",
        .reauth_error_sign_in_failed: "ยืนยันการลงชื่อเข้าใช้ไม่ได้ โปรดลองอีกครั้ง",

        // Options sheet
        .options_title: "ตัวเลือก",
        .options_pin: "ปักหมุด",
        .options_unpin: "เลิกปักหมุด",
        .options_pinned: "ปักหมุดแล้ว",
        .options_copy_link: "คัดลอกลิงก์",
        .options_share: "แชร์",
        .options_copy_markdown: "คัดลอกเป็น Markdown",
        .options_duplicate: "ทำสำเนา",
        .options_delete_document: "ลบเอกสาร",
        .options_delete_confirm_title: "ลบเอกสารนี้ใช่หรือไม่",
        .options_delete: "ลบ",
        .options_error_toggle_favorite: "อัปเดตรายการโปรดไม่ได้ โปรดลองอีกครั้ง",
        .options_error_duplicate: "ทำสำเนาเอกสารไม่ได้ โปรดลองอีกครั้ง",
        .options_error_delete: "ลบเอกสารไม่ได้ โปรดลองอีกครั้ง",

        // Share sheet
        .share_title: "แชร์",
        .share_invite_placeholder: "เชิญด้วยชื่อหรืออีเมล",
        .share_members_one: "แชร์กับ %d คน",
        .share_members_other: "แชร์กับ %d คน",
        .share_add_people: "เพิ่มบุคคล",
        .share_no_people_found: "ไม่พบบุคคล",
        .share_link_parameters: "พารามิเตอร์ลิงก์",
        .share_change_link_access: "เปลี่ยนการเข้าถึงลิงก์",
        .share_copy_link: "คัดลอกลิงก์",
        .share_change_role: "เปลี่ยนบทบาท",
        .share_remove: "นำออก",
        .share_link_access: "การเข้าถึงลิงก์",
        .share_reach_authenticated: "ทุกคนในองค์กร",
        .share_reach_public: "ทุกคนที่มีลิงก์",
        .share_role_reader: "ผู้อ่าน",
        .share_role_commenter: "ผู้แสดงความคิดเห็น",
        .share_role_editor: "ผู้แก้ไข",
        .share_role_administrator: "ผู้ดูแลระบบ",
        .share_role_owner: "เจ้าของ",
        .share_role_pending: "%@ (รอดำเนินการ)",
        .share_error_load: "โหลดสมาชิกไม่ได้ ดึงลงเพื่อรีเฟรชแล้วลองอีกครั้ง",
        .share_error_search: "ค้นหาไม่สำเร็จ โปรดลองอีกครั้ง",
        .share_error_invite: "เพิ่มสมาชิกไม่ได้ โปรดลองอีกครั้ง",
        .share_error_update_role: "อัปเดตบทบาทไม่ได้ โปรดลองอีกครั้ง",
        .share_error_remove_member: "นำสมาชิกออกไม่ได้ โปรดลองอีกครั้ง",
        .share_error_update_link: "อัปเดตการตั้งค่าลิงก์ไม่ได้ โปรดลองอีกครั้ง",

        // Editor - save bar
        .editor_save: "บันทึก",
        .editor_save_now_a11y: "บันทึกทันที",
        .editor_saving: "กำลังบันทึก…",
        .editor_saved: "บันทึกแล้ว",
        .editor_save_failed: "บันทึกไม่ได้ · ลองใหม่",
        .editor_save_failed_a11y: "บันทึกไม่สำเร็จ ลองใหม่",

        // Editor - reading surface / chrome
        .editor_offline_local_copy: "กำลังอ่านสำเนาที่บันทึกไว้บนอุปกรณ์นี้",
        .editor_update_available: "เอกสารมีการอัปเดต · แตะเพื่อรีเฟรช",
        .editor_update_available_a11y: "เอกสารมีการอัปเดต แตะเพื่อรีเฟรช",
        .editor_uploading_photo: "กำลังอัปโหลดรูปภาพ…",
        .editor_uploading_photo_a11y: "กำลังอัปโหลดรูปภาพ",
        .editor_empty_title: "เอกสารว่างเปล่า",
        .editor_empty_body: "เอกสารนี้ยังไม่มีเนื้อหา",
        .editor_start_writing: "เริ่มเขียน",
        .editor_subpages_title: "หน้าย่อย",
        .editor_subpages_title_count: "หน้าย่อย · %d",
        .editor_subpages_empty: "จัดระเบียบเอกสารนี้ด้วยการสร้างหน้าย่อย",
        .editor_add_subpage: "เพิ่มหน้าย่อย",
        .editor_action_done: "เสร็จ",
        .editor_action_pages: "หน้า",
        .editor_action_share: "แชร์",
        .editor_action_options: "ตัวเลือก",

        // Editor - sync caption (reading-surface header)
        .editor_sync_save_failed: "บันทึกไม่ได้ · แตะเพื่อลองใหม่",
        .editor_sync_save_failed_a11y: "บันทึกไม่ได้ แตะเพื่อลองใหม่",
        .editor_sync_saved_on_device: "บันทึกไว้บนอุปกรณ์นี้",
        .editor_sync_edited_just_now: "แก้ไขเมื่อสักครู่",
        .editor_sync_just_now: "ซิงค์เมื่อสักครู่",
        .editor_sync_ago: "ซิงค์เมื่อ %@",
        .editor_sync_not_synced_yet: "ยังไม่ได้ซิงค์",

        // Editor - errors
        .editor_error_load: "โหลดเอกสารนี้ไม่ได้ ดึงลงเพื่อรีเฟรชแล้วลองอีกครั้ง",
        .editor_error_refresh: "รีเฟรชไม่ได้ โปรดลองอีกครั้ง",
        .editor_error_add_subpage: "เพิ่มหน้าย่อยไม่ได้ โปรดลองอีกครั้ง",
        .editor_error_open_link: "เปิดลิงก์นั้นไม่ได้ โปรดลองอีกครั้ง",
        .editor_error_add_photo: "เพิ่มรูปภาพไม่ได้ โปรดลองอีกครั้ง",
        .editor_unavailable: "เอกสารนี้ไม่พร้อมใช้งานอีกต่อไป",
        .editor_unavailable_with_draft:
            "เอกสารนี้ไม่พร้อมใช้งานอีกต่อไป การเปลี่ยนแปลงที่ยังไม่ได้บันทึกของคุณถูกเก็บไว้บนอุปกรณ์นี้",

        // Editor - slash menu (display labels; matching/filtering uses the
        // stable English `SlashMenuItem.title`, never these keys)
        .editor_slash_menu_a11y: "เมนูประเภทบล็อก",
        .editor_slash_text: "ข้อความ",
        .editor_slash_heading1: "หัวข้อ 1",
        .editor_slash_heading2: "หัวข้อ 2",
        .editor_slash_heading3: "หัวข้อ 3",
        .editor_slash_bulleted_list: "รายการหัวข้อย่อย",
        .editor_slash_numbered_list: "รายการลำดับเลข",
        .editor_slash_checklist: "รายการตรวจสอบ",
        .editor_slash_quote: "อ้างอิง",
        .editor_slash_code_block: "บล็อกโค้ด",
        .editor_slash_divider: "เส้นแบ่ง",
        .editor_slash_photo: "รูปภาพ",

        // Editor - formatting bar (icon-only buttons; accessibility labels)
        .editor_format_add_block: "เพิ่มบล็อก",
        .editor_format_bold: "ตัวหนา",
        .editor_format_italic: "ตัวเอียง",
        .editor_format_link: "ลิงก์",
        .editor_format_bulleted_list: "รายการหัวข้อย่อย",
        .editor_format_checklist: "รายการตรวจสอบ",
        .editor_format_quote: "อ้างอิง",
        .editor_format_code_block: "บล็อกโค้ด",
        .editor_format_insert_photo: "แทรกรูปภาพ",

        // Editor - link editor sheet
        .editor_link_add_title: "เพิ่มลิงก์",
        .editor_link_edit_title: "แก้ไขลิงก์",
        .editor_link_text_label: "ข้อความ",
        .editor_link_text_placeholder: "ข้อความลิงก์",
        .editor_link_text_helper: "เว้นว่างไว้เพื่อแสดงที่อยู่โดยตรง",
        .editor_link_address_label: "ที่อยู่",
        .editor_link_address_placeholder: "example.com/page",
        .editor_link_address_error: "ที่อยู่นั้นใช้เป็นลิงก์ไม่ได้",
        .editor_link_remove: "นำลิงก์ออก",
        .editor_link_save: "บันทึก",
        .editor_link_add: "เพิ่ม",

        // Editor - document tree panel (DocTreePanel)
        .editor_tree_pages: "หน้า",
        .editor_tree_close: "ปิดหน้า",
        .editor_tree_empty: "ยังไม่มีหน้าย่อย เพิ่มหน้าย่อยเพื่อจัดระเบียบเอกสารนี้",
        .editor_tree_new_page: "หน้าใหม่",

        // Editor - inline image (MarkdownImageView; accessibility labels only)
        .editor_image_a11y: "รูปภาพ",
        .editor_image_loading_a11y: "กำลังโหลดรูปภาพ",
        .editor_image_loading_named_a11y: "กำลังโหลดรูปภาพ: %@",

        // Editor - block canvas accessibility labels (BlockEditorView)
        .editor_add_paragraph_a11y: "เพิ่มย่อหน้าที่ท้ายสุด",
        .editor_divider_a11y: "เส้นแบ่ง",
        .editor_checklist_done_a11y: "ทำเครื่องหมายว่าเสร็จ",
        .editor_checklist_not_done_a11y: "ทำเครื่องหมายว่ายังไม่เสร็จ",

        // Profile
        .profile_title: "โปรไฟล์",
        .profile_user: "ผู้ใช้",
        .profile_prefs: "การตั้งค่า",
        .profile_prefs_footer: "เมื่อเปิดใช้งาน เอกสารที่คุณเปิดไว้จะยังอ่านได้บนอุปกรณ์นี้แม้ไม่มีการเชื่อมต่อ",
        .profile_appearance: "รูปลักษณ์",
        .profile_language: "ภาษา",
        .profile_notifications: "การแจ้งเตือน",
        .profile_work_offline: "ทำงานออฟไลน์",
        .profile_server: "เซิร์ฟเวอร์",
        .profile_server_footer: "แอปเชื่อมต่อกับเซิร์ฟเวอร์ Schrift ใดก็ได้โดยใช้เซสชันเว็บที่มีอยู่ของคุณ",
        .profile_connected: "เชื่อมต่อแล้ว",
        .profile_offline: "ออฟไลน์",
        .profile_server_version: "เวอร์ชันเซิร์ฟเวอร์",
        .profile_about: "เกี่ยวกับ",
        .profile_version: "เวอร์ชัน",
        .profile_sign_out: "ออกจากระบบ",
        .profile_disconnect_title: "ยกเลิกการเชื่อมต่อจาก %@?",
        .profile_disconnect: "ยกเลิกการเชื่อมต่อ",
        .profile_disconnect_body: "คุณจะต้องลงชื่อเข้าใช้อีกครั้งเพื่อเชื่อมต่อใหม่",

        // Appearance picker
        .appearance_system: "ระบบ",
        .appearance_light: "สว่าง",
        .appearance_dark: "มืด",
    ]
}
