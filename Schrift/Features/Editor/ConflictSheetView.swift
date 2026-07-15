import SwiftUI

/// Localized "the server copy changed <when>" line for the conflict sheet,
/// mirroring `versionRowDate` (`VersionHistorySheetView.swift`). Takes `now` so it
/// stays pure and testable, unlike `documentRowDate`.
func conflictServerChangedDate(_ serverUpdatedAt: Date, now: Date, locale: Locale) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    formatter.locale = locale
    return formatter.localizedString(for: serverUpdatedAt, relativeTo: now)
}

/// `.sheet(item:)` payload for the conflict sheet — the sheet renders the conflict's
/// server timestamp, so it must never be presented without one, and `SyncConflict` is
/// a plain value with no identity of its own. Wrapping it here keeps the UI-only `id`
/// out of the coordinator's model (same shape as `LinkEditRequest`).
struct IdentifiedSyncConflict: Identifiable {
    let id = UUID()
    let value: DocumentSaveCoordinator.SyncConflict

    init(_ value: DocumentSaveCoordinator.SyncConflict) {
        self.value = value
    }
}

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
    /// The detected conflict — its `serverUpdatedAt` tells the user *when* the other
    /// copy changed, which is the one fact they need to choose a winner. It carries
    /// no server markdown by design: "keep the server version" re-fetches.
    let conflict: DocumentSaveCoordinator.SyncConflict
    /// Overwrite the server copy with the queued local edit (resumes the save).
    var onKeepMine: () -> Void
    /// Discard the queued local edit and re-render the server's copy.
    var onKeepServer: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(LocalizationStore.self) private var loc
    @State private var isConfirmingKeepServer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                title: loc[.editor_conflict_title], closeLabel: loc[.common_close],
                onClose: { dismiss() })

            VStack(alignment: .leading, spacing: DocsSpacing.space4xs) {
                Text(loc[.editor_conflict_body])
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.textSecondary)
                Text(
                    loc.format(
                        .editor_conflict_server_changed,
                        conflictServerChangedDate(conflict.serverUpdatedAt, now: Date(), locale: locale))
                )
                .font(DocsFont.footnote)
                .foregroundStyle(DocsColor.textTertiary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            ConflictSheetView(
                conflict: .init(serverUpdatedAt: Date().addingTimeInterval(-600)),
                onKeepMine: {}, onKeepServer: {}
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .environment(LocalizationStore())
        }
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            ConflictSheetView(
                conflict: .init(serverUpdatedAt: Date().addingTimeInterval(-600)),
                onKeepMine: {}, onKeepServer: {}
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .environment(LocalizationStore())
        }
        .preferredColorScheme(.dark)
}
