import Foundation

/// Every Google Material Symbols Outlined glyph the app renders. The first
/// eight groups are the exact set the design handoff enumerates
/// (`brand-iconography.html`, 69 glyphs); the final group is a handful of
/// further Material Symbols the iOS app needs that the handoff's mockups did
/// not surface (divider rule, remove-link, heading 3, a paragraph/"Text"
/// glyph, a sync spinner, a per-version clock, checklist check boxes) — still
/// the same icon system. The raw value is the Material glyph name; `codepoint`
/// is its Private-Use-Area code point in the bundled font subset.
enum MaterialIcon: String, CaseIterable, Sendable {
    // MARK: Navigation & chrome
    case description
    case search
    case group
    case account_circle
    case arrow_back_ios_new
    case chevron_right
    case close
    case more_horiz
    case left_panel_close

    // MARK: Documents & actions
    case add
    case edit
    case push_pin
    case account_tree
    case content_copy
    case download
    case history
    case delete
    case cloud_done

    // MARK: Sharing & permissions
    case share
    case person_add
    case link
    case add_link
    case lock
    case vpn_lock
    case `public`
    case expand_more
    case unfold_more

    // MARK: Editor toolbar
    case format_bold
    case format_italic
    case format_h1
    case format_h2
    case format_list_bulleted
    case format_list_numbered
    case format_quote
    case checklist
    case image
    case data_object
    case undo
    case keyboard_hide

    // MARK: Status & feedback
    case check
    case check_circle
    case cancel
    case error
    case warning
    case info
    case lightbulb
    case search_off
    case wifi_off

    // MARK: Settings & account
    case dark_mode
    case light_mode
    case contrast
    case translate
    case notifications
    case cloud_off
    case logout
    case badge
    case admin_panel_settings
    case apartment
    case event
    case open_in_new
    case mail
    case dns
    case deployed_code

    // MARK: Onboarding & sign-in
    case login
    case cloud
    case photo_camera

    // MARK: iOS status bar
    case signal_cellular_alt
    case wifi
    case battery_full

    // MARK: App-specific (Material Symbols beyond the handoff's explicit 69)
    case horizontal_rule
    case link_off
    case format_h3
    case subject
    case sync
    case schedule
    case check_box
    case check_box_outline_blank

    /// The glyph's code point in the Material Symbols font (Private Use Area).
    var codepoint: UInt32 {
        switch self {
        case .description: return 0xe873
        case .search: return 0xef7a
        case .group: return 0xea21
        case .account_circle: return 0xf20b
        case .arrow_back_ios_new: return 0xe2ea
        case .chevron_right: return 0xe5cc
        case .close: return 0xe5cd
        case .more_horiz: return 0xe5d3
        case .left_panel_close: return 0xf717
        case .add: return 0xe145
        case .edit: return 0xf097
        case .push_pin: return 0xf10d
        case .account_tree: return 0xe97a
        case .content_copy: return 0xe14d
        case .download: return 0xf090
        case .history: return 0xe8b3
        case .delete: return 0xe92e
        case .cloud_done: return 0xe2bf
        case .share: return 0xe80d
        case .person_add: return 0xea4d
        case .link: return 0xe250
        case .add_link: return 0xe178
        case .lock: return 0xe899
        case .vpn_lock: return 0xe62f
        case .`public`: return 0xe80b
        case .expand_more: return 0xe5cf
        case .unfold_more: return 0xe5d7
        case .format_bold: return 0xe238
        case .format_italic: return 0xe23f
        case .format_h1: return 0xf85d
        case .format_h2: return 0xf85e
        case .format_list_bulleted: return 0xe241
        case .format_list_numbered: return 0xe242
        case .format_quote: return 0xe244
        case .checklist: return 0xe6b1
        case .image: return 0xe3f4
        case .data_object: return 0xead3
        case .undo: return 0xe166
        case .keyboard_hide: return 0xe31a
        case .check: return 0xe668
        case .check_circle: return 0xf0be
        case .cancel: return 0xe888
        case .error: return 0xf8b6
        case .warning: return 0xf083
        case .info: return 0xe88e
        case .lightbulb: return 0xe90f
        case .search_off: return 0xea76
        case .wifi_off: return 0xe648
        case .dark_mode: return 0xe51c
        case .light_mode: return 0xe518
        case .contrast: return 0xeb37
        case .translate: return 0xe8e2
        case .notifications: return 0xe7f5
        case .cloud_off: return 0xe2c1
        case .logout: return 0xe9ba
        case .badge: return 0xea67
        case .admin_panel_settings: return 0xef3d
        case .apartment: return 0xea40
        case .event: return 0xe878
        case .open_in_new: return 0xe89e
        case .mail: return 0xe159
        case .dns: return 0xe875
        case .deployed_code: return 0xf720
        case .login: return 0xea77
        case .cloud: return 0xf15c
        case .photo_camera: return 0xe412
        case .signal_cellular_alt: return 0xe202
        case .wifi: return 0xe63e
        case .battery_full: return 0xe1a5
        case .horizontal_rule: return 0xf108
        case .link_off: return 0xe16f
        case .format_h3: return 0xf85f
        case .subject: return 0xe8d2
        case .sync: return 0xe627
        case .schedule: return 0xefd6
        case .check_box: return 0xe9de
        case .check_box_outline_blank: return 0xe835
        }
    }

    /// The single character that renders this glyph in the Material Symbols font.
    var character: Character { Character(Unicode.Scalar(codepoint)!) }
}
