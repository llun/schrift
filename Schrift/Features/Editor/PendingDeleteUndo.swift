import SwiftUI

/// The one affordance a struck-through row offers: cancel the deletion that has not been
/// sent yet.
///
/// Shared by every list that can show such a row — Home, Shared, Search, the editor's
/// Subpages section and the Pages drawer — so the wording and the behaviour cannot drift
/// between them. Each surface holds the tapped document in its own `@State` and hands the
/// undo back to whichever coordinator it has.
///
/// A system `.alert`, not a confirmation dialog: this is a yes/no question about one verb,
/// which is what the handoff reserves alerts for. It is *not* destructive — undoing keeps a
/// document — so neither button takes `.destructive`.
struct PendingDeleteUndoAlert: ViewModifier {
    @Binding var document: Document?
    let onUndo: (Document) -> Void

    @Environment(LocalizationStore.self) private var loc

    func body(content: Content) -> some View {
        content.alert(
            loc[.docrow_pending_delete], isPresented: isPresented, presenting: document
        ) { target in
            Button(loc[.pending_delete_undo]) { onUndo(target) }
            Button(loc[.common_cancel], role: .cancel) {}
        } message: { _ in
            Text(loc[.pending_delete_alert_message])
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
    /// Offer to cancel a queued deletion for `document`, which the caller sets when a
    /// struck-through row is tapped instead of navigating.
    func pendingDeleteUndoAlert(
        for document: Binding<Document?>, onUndo: @escaping (Document) -> Void
    ) -> some View {
        modifier(PendingDeleteUndoAlert(document: document, onUndo: onUndo))
    }
}
