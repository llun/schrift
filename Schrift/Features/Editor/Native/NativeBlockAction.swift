import Foundation

/// The block menu (PR06d): actions on the caret's block and its whole
/// subtree, each one durable command (`NativeInputCoordinator.performBlockAction`)
/// except Copy, which only writes the pasteboard. Menu order.
enum NativeBlockAction: String, CaseIterable, Sendable {
    case moveUp, moveDown, outdent, indent, insertAbove, insertBelow, duplicate, copy, delete

    var labelKey: L10nKey {
        switch self {
        case .moveUp: .native_editor_block_move_up
        case .moveDown: .native_editor_block_move_down
        case .outdent: .editor_format_outdent
        case .indent: .editor_format_indent
        case .insertAbove: .native_editor_block_insert_above
        case .insertBelow: .native_editor_block_insert_below
        case .duplicate: .native_editor_block_duplicate
        case .copy: .native_editor_block_copy
        case .delete: .native_editor_block_delete
        }
    }
}
