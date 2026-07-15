import SwiftUI

/// Editing-session header. Editing hides the reading-mode nav bar (its back
/// button left the whole document, and its border stacked with this bar's into a
/// double hairline), so this is the *only* bar while editing: the live save
/// status on the left (Save / Saving… / Saved / Retry) and a **Done** button on
/// the right that ends the session. Its background fills the top safe area white
/// like `NavBar`, since it now sits directly under the status bar.
struct EditorSaveBar: View {
    let saveState: EditorViewModel.SaveState
    /// A conflict is recorded, so the push is **held** — see `saveStatusDisplay`.
    var hasConflict: Bool = false
    var hasUnsavedLocalContent: Bool = false
    /// Peers currently in the document — presence avatars, empty when alone.
    var peers: [CollaborationPeer] = []
    var onSaveTap: () -> Void
    var onDone: () -> Void

    @Environment(LocalizationStore.self) private var loc

    var body: some View {
        HStack(spacing: DocsSpacing.spaceSM) {
            SaveStatusIndicator(
                display: saveStatusDisplay(
                    saveState: saveState,
                    hasConflict: hasConflict,
                    hasUnsavedLocalContent: hasUnsavedLocalContent),
                onTap: onSaveTap)

            Spacer(minLength: DocsSpacing.spaceXS)

            PresenceBar(peers: peers)

            IconButton(
                icon: .check,
                label: loc[.editor_action_done],
                color: .brand,
                action: onDone
            )
        }
        .padding(.horizontal, DocsSpacing.gutter)
        .frame(minHeight: DocsSpacing.navBarHeight)
        // Solid, opaque fill extended up through the status-bar strip — the same
        // treatment `NavBar` uses — so there is no gray/white seam above the bar.
        .background(DocsColor.surfacePage.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DocsColor.borderDefault)
                .frame(height: 0.5)
        }
    }
}

/// What the editing header's status slot shows. A resolved value, not a raw save state:
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

/// The editing header's counterpart to `syncCaption`'s precedence, and the same rule 0: a
/// **recorded conflict holds the push**. Nothing is being sent, and no affordance here can
/// send it — `saveNow` re-enqueues straight back into the enqueue-hold — so the header must
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
            // The width-constrained editing header uses the compact "Saved on this
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
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc[.editor_save_failed_a11y])
        }
    }
}

#Preview {
    VStack(spacing: DocsSpacing.spaceBase) {
        EditorSaveBar(saveState: .idle, onSaveTap: {}, onDone: {})
        EditorSaveBar(saveState: .dirty, onSaveTap: {}, onDone: {})
        EditorSaveBar(saveState: .saving, onSaveTap: {}, onDone: {})
        EditorSaveBar(saveState: .saved, onSaveTap: {}, onDone: {})
        EditorSaveBar(saveState: .pendingSync, onSaveTap: {}, onDone: {})
        EditorSaveBar(saveState: .failed("nope"), onSaveTap: {}, onDone: {})
        // Held by a conflict: a save that would otherwise read "Saved" (or offer a retry
        // that only re-parks) states only the true part. The pill below carries the action.
        EditorSaveBar(
            saveState: .saved, hasConflict: true, hasUnsavedLocalContent: true, onSaveTap: {}, onDone: {})
        EditorSaveBar(
            saveState: .failed("nope"), hasConflict: true, hasUnsavedLocalContent: true, onSaveTap: {},
            onDone: {})
    }
    .background(DocsColor.surfaceSunken)
    .environment(LocalizationStore())
}
