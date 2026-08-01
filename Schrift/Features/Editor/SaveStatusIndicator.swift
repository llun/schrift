import SwiftUI

/// The editing session's save status: the resolved display value and the small
/// view that renders it.
///
/// This used to live in a bar of its own above the canvas. There is one system
/// toolbar now, so the status moved into the editing surface — the resolver and
/// its precedence rules are unchanged, which is the part that matters.

/// What the editing session's status slot shows. A resolved value, not a raw save state:
/// a recorded conflict outranks the save state (see `saveStatusDisplay`).
enum SaveStatusDisplay: Equatable {
    case none
    /// Tappable — flushes the in-progress edit to disk (and pushes it, unless held).
    case save
    case saving
    case saved
    /// Passive: the work is on the device but is not being sent.
    case savedOnDevice
    /// Tappable — retry a failed save.
    case retry
}

/// The editing session's counterpart to `syncCaption`'s precedence, and the same rule 0: a
/// **recorded conflict holds the push**. Nothing is being sent, and no affordance here can
/// send it — `saveNow` re-enqueues straight back into the enqueue-hold — so the status must
/// neither claim a sync ("Saving…" / "Saved") nor offer a retry that silently re-parks. The
/// work *is* on the device (the flush's write-ahead draft), so say only that, and leave the
/// conflict pill — which the editing session shows too — as the sole affordance.
///
/// `.dirty` keeps its funnel even under a conflict: the newest keystrokes are **not** on
/// disk yet (the draft is written by the flush), so "Saved on this device" would be a lie
/// there, and tapping Save is exactly what puts them there.
func saveStatusDisplay(
    saveState: EditorViewModel.SaveState,
    hasConflict: Bool,
    hasUnsavedLocalContent: Bool
) -> SaveStatusDisplay {
    if hasConflict, hasUnsavedLocalContent {
        if case .dirty = saveState { return .save }
        return .savedOnDevice
    }
    switch saveState {
    case .idle: return .none
    case .dirty: return .save
    case .saving: return .saving
    case .saved: return .saved
    case .pendingSync: return .savedOnDevice
    case .failed: return .retry
    }
}

struct SaveStatusIndicator: View {
    let display: SaveStatusDisplay
    var onTap: () -> Void

    @Environment(LocalizationStore.self) private var loc

    var body: some View {
        switch display {
        case .none:
            EmptyView()

        case .save:
            Button(action: onTap) {
                Text(loc[.editor_save])
                    .font(DocsFont.footnote.weight(.semibold))
                    .foregroundStyle(DocsColor.textBrand)
                    // Fill the row before taking the tap shape. A footnote line
                    // is ~16pt tall, so the drawn text was less than half the
                    // 44pt target on its own; the enclosing row supplies the
                    // height (see `EditorView.saveStatusRow`). The width floor
                    // matters here and nowhere else in this switch: "Save" is
                    // four characters, narrower than 44pt at the default text
                    // size, where every other state is a whole phrase.
                    // `.leading`, or widening the box would shift the word off
                    // the row's leading edge where every other state starts.
                    .frame(minWidth: DocsSpacing.rowMinHeight, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc[.editor_save_now_a11y])

        case .saving:
            HStack(spacing: DocsSpacing.space3xs) {
                ProgressView()
                    .controlSize(.small)
                Text(loc[.editor_saving])
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.textTertiary)
            }

        case .saved:
            HStack(spacing: DocsSpacing.space3xs) {
                MaterialSymbol(.check, size: 11)
                Text(loc[.editor_saved])
                    .font(DocsFont.footnote)
            }
            .foregroundStyle(DocsColor.textTertiary)

        case .savedOnDevice:
            // The width-constrained editing status uses the compact "Saved on this
            // device" (the `cloud_off` icon conveys the pending sync); the reading
            // surface's caption carries the full "· syncs when online" promise once
            // editing ends — and, under a conflict, drops that promise exactly as this
            // does, because the push is held.
            HStack(spacing: DocsSpacing.space3xs) {
                MaterialSymbol(.cloud_off, size: 11)
                Text(loc[.editor_sync_saved_on_device])
                    .font(DocsFont.footnote)
            }
            .foregroundStyle(DocsColor.textTertiary)

        case .retry:
            Button(action: onTap) {
                HStack(spacing: DocsSpacing.space3xs) {
                    MaterialSymbol(.error, size: 11)
                    Text(loc[.editor_save_failed])
                        .font(DocsFont.footnote.weight(.semibold))
                }
                .foregroundStyle(DocsColor.danger)
                // The only retry affordance there is while editing — and, when
                // offline, the only way out at all, since tap-to-edit is
                // blocked. It has to be reachable.
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc[.editor_save_failed_a11y])
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: DocsSpacing.spaceBase) {
        SaveStatusIndicator(display: .save, onTap: {})
        SaveStatusIndicator(display: .saving, onTap: {})
        SaveStatusIndicator(display: .saved, onTap: {})
        SaveStatusIndicator(display: .savedOnDevice, onTap: {})
        SaveStatusIndicator(display: .retry, onTap: {})
    }
    .padding()
    .environment(LocalizationStore())
}
