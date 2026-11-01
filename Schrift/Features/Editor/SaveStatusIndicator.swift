import SwiftUI

/// The editing session's save status: the resolved display value and the small
/// view that renders it.
///
/// This used to live in a bar of its own above the canvas. There is one system
/// toolbar now, so the status moved into the editing surface — the resolver and
/// its precedence rules are unchanged, which is the part that matters.

/// What the editing session's status slot shows. A resolved value, not a raw save state:
/// a recorded conflict outranks the save state (see `saveStatusDisplay`).
///
/// `CaseIterable` so `SaveStatusIndicatorTests` can derive the list of visible
/// states rather than restate it: a sixth case added to `body`'s switch without
/// the height floor every other state carries would otherwise slip past the whole
/// file green — sized to its own text, so the canvas resizes when the status
/// changes to it, and free to reach for the `maxHeight: .infinity` that took half
/// the editor.
enum SaveStatusDisplay: Equatable, CaseIterable {
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
///
/// **Connection down** (`connectionDown`: path down or transport evidence, *not* Work
/// Offline, which still sends saves) turns `.saving` into `.savedOnDevice`: the write-ahead
/// draft is already on disk and nothing will reach the server, so "Saving…" would claim a sync that is not happening
/// (each autosave flashed it for the whole 60s request timeout). `.dirty` stays `.save`
/// (the newest keystrokes are not on disk until the flush) and `.failed` stays `.retry`.
func saveStatusDisplay(
    saveState: EditorViewModel.SaveState,
    hasConflict: Bool,
    hasUnsavedLocalContent: Bool,
    connectionDown: Bool
) -> SaveStatusDisplay {
    if hasConflict, hasUnsavedLocalContent {
        if case .dirty = saveState { return .save }
        return .savedOnDevice
    }
    switch saveState {
    case .idle: return .none
    case .dirty: return .save
    case .saving: return connectionDown ? .savedOnDevice : .saving
    case .saved: return .saved
    case .pendingSync: return .savedOnDevice
    case .failed: return .retry
    }
}

struct SaveStatusIndicator: View {
    @Environment(\.docsTheme) private var theme
    let display: SaveStatusDisplay
    var onTap: () -> Void

    @Environment(LocalizationStore.self) private var loc
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A stack, so a state leaving and the next arriving overlap in the one slot rather than
    /// stacking in the parent's layout — and no state's own height floor changes, so nothing
    /// around the slot moves while "Saving…" settles into "Saved". The crossfade is an ease
    /// (never a spring): it runs on every autosave and has to stay quiet.
    var body: some View {
        ZStack(alignment: .leading) {
            statusContent
        }
        .animation(DocsMotion.saveStatusAnimation(reduceMotion: reduceMotion), value: display)
    }

    private var statusTransition: AnyTransition {
        DocsMotion.saveStatusTransition(reduceMotion: reduceMotion)
    }

    @ViewBuilder private var statusContent: some View {
        switch display {
        case .none:
            EmptyView()

        case .save:
            Button(action: onTap) {
                Text(loc[.editor_save])
                    .font(DocsFont.footnote.weight(.semibold))
                    .foregroundStyle(theme.colors.textBrand)
                    // Reach the tap target before taking the tap shape. A footnote
                    // line is ~19pt tall, less than half the 44pt target on its
                    // own. The floor is this label's own — *not* `maxHeight:
                    // .infinity`, which is what put the title mid-screen: an
                    // unbounded max fills whatever height it is **proposed**, and
                    // `editingSurface` was then a `VStack(spacing: 0)` in a
                    // height-bounded container, so a whole screen was proposed
                    // and answered in full, leaving the canvas the remainder.
                    // (The strip's own `minHeight:` could not stop it: a floor
                    // is not a cap.) The indicator lives in the shared document
                    // header now — inside a `ScrollView`, which proposes an
                    // unspecified height — so that particular container is gone,
                    // but the floor stays: it is what buys the tap target, and
                    // an unbounded max here would be just as wrong in a scroll
                    // view's *cross* axis. The width floor
                    // matters here and nowhere else in this switch: "Save" is
                    // four characters, narrower than 44pt at the default text
                    // size, where every other state is a whole phrase.
                    // `.leading`, or widening the box would shift the word off
                    // the row's leading edge where every other state starts.
                    .frame(
                        minWidth: DocsSpacing.rowMinHeight, minHeight: DocsSpacing.rowMinHeight,
                        alignment: .leading
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc[.editor_save_now_a11y])
            .transition(statusTransition)

        case .saving:
            HStack(spacing: DocsSpacing.space3xs) {
                ProgressView()
                    .controlSize(.small)
                Text(loc[.editor_saving])
                    .font(DocsFont.footnote)
                    .foregroundStyle(theme.colors.textTertiary)
            }
            // The passive states carry the same floor as the two tappable ones —
            // they need no tap target, but sized to their own text the canvas
            // below would resize as the status moved Save → Saving → Saved. A
            // floor only levels states whose own text fits inside it, so this is
            // a default-size property: once a phrase grows past 44pt the state is
            // text-sized again, which is the right trade — capping it would clip
            // the text.
            .frame(minHeight: DocsSpacing.rowMinHeight)
            .transition(statusTransition)

        case .saved:
            HStack(spacing: DocsSpacing.space3xs) {
                SavedCheckmark()
                Text(loc[.editor_saved])
                    .font(DocsFont.footnote)
            }
            .foregroundStyle(theme.colors.textTertiary)
            // The shared floor, as in `.saving`.
            .frame(minHeight: DocsSpacing.rowMinHeight)
            .transition(statusTransition)

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
            .foregroundStyle(theme.colors.textTertiary)
            // The shared floor, as in `.saving`.
            .frame(minHeight: DocsSpacing.rowMinHeight)
            .transition(statusTransition)

        case .retry:
            Button(action: onTap) {
                HStack(spacing: DocsSpacing.space3xs) {
                    MaterialSymbol(.error, size: 11)
                    Text(loc[.editor_save_failed])
                        .font(DocsFont.footnote.weight(.semibold))
                }
                .foregroundStyle(theme.colors.danger)
                // The only retry affordance there is while editing, and the only
                // thing that unpins a document whose revalidations `reconcileDraft`
                // no-ops. It has to be reachable — floored here rather than left
                // unbounded for the row to bound, for the reason spelled out on
                // `.save`.
                .frame(minHeight: DocsSpacing.rowMinHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc[.editor_save_failed_a11y])
            .transition(statusTransition)
        }
    }
}

/// The "Saved" check, drawn as a stroke so it can draw itself in: the trim runs from nothing to
/// the whole tick when the status settles. Sized and tinted like the 11pt glyph it replaces
/// (it scales with Dynamic Type alongside the footnote beside it). Under Reduce Motion it is
/// just there. Decorative — the "Saved" text carries the meaning.
private struct SavedCheckmark: View {
    @Environment(\.docsTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 11
    @State private var drawn = false

    var body: some View {
        let drawsIn = DocsMotion.saveCheckDrawsIn(reduceMotion: reduceMotion)
        SavedCheckShape()
            .trim(from: 0, to: drawsIn && !drawn ? 0.001 : 1)
            .stroke(
                theme.colors.textTertiary,
                style: StrokeStyle(lineWidth: size * 0.14, lineCap: .round, lineJoin: .round)
            )
            .frame(width: size, height: size)
            .onAppear {
                guard drawsIn else { return }
                withAnimation(DocsMotion.saveCheckDraw) { drawn = true }
            }
            .accessibilityHidden(true)
    }
}

/// The tick's path, in a unit square: down to the elbow, then up to the right.
private struct SavedCheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.1, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.minY + rect.height * 0.85))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.92, y: rect.minY + rect.height * 0.2))
        return path
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
