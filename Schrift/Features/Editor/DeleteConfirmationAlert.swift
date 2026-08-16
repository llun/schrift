import SwiftUI

/// Confirm deleting a document from a list row.
///
/// Shared by every surface whose rows offer swipe-to-delete — Home, the editor's Subpages
/// section and the Pages drawer — so the wording and the destructive role cannot drift
/// between them, the same argument `PendingDeleteUndoAlert` makes for its own alert. The copy
/// is the Options sheet's, deliberately: this is the same verb reached a shorter way, and two
/// phrasings for one action would be worse than none.
///
/// A system `.alert`, not a `.confirmationDialog`: this is a yes/no question about a single
/// destructive verb, which is what the handoff reserves alerts for — a dialog is for choosing
/// among options.
///
/// `hasLocalSubpages` decides whether the message warns that sub-pages saved only on this
/// device go with it. It is asked per-document at presentation time rather than stored on the
/// row, because a document's local children can change while the list is on screen.
struct DeleteConfirmationAlert: ViewModifier {
    @Binding var document: Document?
    let hasLocalSubpages: (Document) -> Bool
    let onConfirm: (Document) -> Void

    @Environment(LocalizationStore.self) private var loc

    func body(content: Content) -> some View {
        content.alert(
            loc[.options_delete_confirm_title], isPresented: isPresented, presenting: document
        ) { target in
            Button(loc[.options_delete], role: .destructive) { onConfirm(target) }
            Button(loc[.common_cancel], role: .cancel) {}
        } message: { target in
            if hasLocalSubpages(target) {
                Text(loc[.options_delete_confirm_subpages])
            }
        }
    }

    /// Derived rather than a second `@State` flag, so the alert and the document it is about
    /// can never disagree — dismissing clears the document, and setting one presents it.
    private var isPresented: Binding<Bool> {
        Binding(
            get: { document != nil },
            set: { if !$0 { document = nil } })
    }
}

extension View {
    /// Confirm deleting `document`, which the caller sets when a row's Delete swipe action is
    /// tapped.
    func deleteConfirmationAlert(
        for document: Binding<Document?>,
        hasLocalSubpages: @escaping (Document) -> Bool = { _ in false },
        onConfirm: @escaping (Document) -> Void
    ) -> some View {
        modifier(
            DeleteConfirmationAlert(
                document: document, hasLocalSubpages: hasLocalSubpages, onConfirm: onConfirm))
    }
}

/// The swipe actions a document row offers, resolved from what is true of that row.
///
/// Pure and testable, and a free function rather than logic inlined in three `ForEach`
/// bodies, so the three surfaces cannot drift on the two rules that matter:
///
///  - a row already **waiting to be deleted** offers only "Keep this document". Delete would
///    be a no-op on it, and the row's own tap already means the undo;
///  - a **locally-created** row offers no Pin. There is no
///    `documents/{local-uuid}/favorite/` route, so the request 404s and
///    `retryableSaveFailure` rightly refuses to retry it — the same gate `OptionsSheetView`
///    applies. Delete stays: dropping the local record *is* the deletion.
///
/// **Move is offered on every row that is not already waiting to be deleted**, including a
/// locally-created one — unlike Pin, a local document has somewhere for the move to go: its
/// pending record is simply re-parented on this device and the replay creates it in the right
/// place. Every surface offers it, because the whole point is to move a document *between*
/// them.
///
/// Labels are the caller's already-localized strings, matching `docRowAccessibilityLabel`'s
/// contract, and they reuse the Options sheet's own keys so the two routes to the same verb
/// read identically.
func documentRowSwipeActions(
    isPendingDelete: Bool,
    isLocalDocument: Bool,
    isFavorite: Bool,
    offersPin: Bool,
    keepLabel: String,
    pinLabel: String,
    unpinLabel: String,
    moveLabel: String,
    deleteLabel: String,
    onKeep: @escaping () -> Void,
    onTogglePin: @escaping () -> Void,
    onMove: @escaping () -> Void,
    onDelete: @escaping () -> Void
) -> [SwipeRevealAction] {
    if isPendingDelete {
        return [
            SwipeRevealAction(id: "keep", icon: .undo, label: keepLabel, role: .brand, handler: onKeep)
        ]
    }
    var actions: [SwipeRevealAction] = []
    if offersPin && !isLocalDocument {
        actions.append(
            SwipeRevealAction(
                id: "pin", icon: .push_pin, label: isFavorite ? unpinLabel : pinLabel,
                role: .neutral, handler: onTogglePin))
    }
    // `account_tree` rather than Material's own `drive_file_move`: the bundled font is a
    // subset of the glyphs the app uses, so a new icon means re-subsetting and committing the
    // binary — deliberately left as a follow-up rather than blocking the feature on it. The
    // tree glyph is the closest thing already bundled and reads correctly here, since what a
    // move changes is the document's place in the page tree. It always appears with the
    // localized "Move" label beside it, in the strip and in the Options sheet alike.
    actions.append(
        SwipeRevealAction(
            id: "move", icon: .account_tree, label: moveLabel, role: .neutral, handler: onMove))
    actions.append(
        SwipeRevealAction(
            id: "delete", icon: .delete, label: deleteLabel, role: .destructive, handler: onDelete))
    return actions
}
