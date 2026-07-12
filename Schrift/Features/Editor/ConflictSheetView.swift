import SwiftUI

/// The sync-conflict resolution sheet. Presented when a document was changed on
/// the server while the user's offline edits were still queued to sync: the app
/// **detects and asks** rather than merging (there is no on-device Yjs decoder and
/// no CRDT), so the user picks a single winner.
///
/// Flat, boxless `SheetHeader` chrome per the design system (see CLAUDE.md): the
/// two choices are `ListRow`s drawn directly on `DocsColor.surfacePage`, no
/// `NavigationStack`/"Done" and no `ListSection` card. "Keep the server version"
/// discards the queued local edit, so it is destructive and goes through a
/// confirmation. Both choices dismiss the sheet before handing off to the caller.
struct ConflictSheetView: View {
    /// Overwrite the server copy with the queued local edit (resumes the save).
    var onKeepMine: () -> Void
    /// Discard the queued local edit and re-render the server's copy.
    var onKeepServer: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(LocalizationStore.self) private var loc
    @State private var isConfirmingKeepServer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                title: loc[.editor_conflict_title], closeLabel: loc[.common_close],
                onClose: { dismiss() })

            Text(loc[.editor_conflict_body])
                .font(DocsFont.footnote)
                .foregroundStyle(DocsColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.bottom, DocsSpacing.spaceXS)

            ListRow(
                icon: .cloud, title: loc[.editor_conflict_keep_mine],
                subtitle: loc[.editor_conflict_keep_mine_detail],
                action: {
                    dismiss()
                    onKeepMine()
                })

            ListRow(
                icon: .download, title: loc[.editor_conflict_keep_server],
                subtitle: loc[.editor_conflict_keep_server_detail],
                isDestructive: true,
                action: { isConfirmingKeepServer = true })

            Text(loc[.editor_conflict_restore_hint])
                .font(DocsFont.footnote)
                .foregroundStyle(DocsColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.top, DocsSpacing.spaceXS)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DocsColor.surfacePage)
        .confirmationDialog(
            loc[.editor_conflict_keep_server], isPresented: $isConfirmingKeepServer,
            titleVisibility: .visible
        ) {
            Button(loc[.editor_conflict_keep_server], role: .destructive) {
                dismiss()
                onKeepServer()
            }
            Button(loc[.common_cancel], role: .cancel) {}
        } message: {
            Text(loc[.editor_conflict_keep_server_detail])
        }
    }
}

#Preview("Light") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            ConflictSheetView(onKeepMine: {}, onKeepServer: {})
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .environment(LocalizationStore())
        }
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            ConflictSheetView(onKeepMine: {}, onKeepServer: {})
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .environment(LocalizationStore())
        }
        .preferredColorScheme(.dark)
}
