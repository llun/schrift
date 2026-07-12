import SwiftUI

/// Editing-session header. Editing hides the reading-mode nav bar (its back
/// button left the whole document, and its border stacked with this bar's into a
/// double hairline), so this is the *only* bar while editing: the live save
/// status on the left (Save / Saving… / Saved / Retry) and a **Done** button on
/// the right that ends the session. Its background fills the top safe area white
/// like `NavBar`, since it now sits directly under the status bar.
struct EditorSaveBar: View {
    let saveState: EditorViewModel.SaveState
    var onSaveTap: () -> Void
    var onDone: () -> Void

    @Environment(LocalizationStore.self) private var loc

    var body: some View {
        HStack(spacing: DocsSpacing.spaceSM) {
            SaveStatusIndicator(state: saveState, onTap: onSaveTap)

            Spacer(minLength: DocsSpacing.spaceXS)

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

struct SaveStatusIndicator: View {
    let state: EditorViewModel.SaveState
    var onTap: () -> Void

    @Environment(LocalizationStore.self) private var loc

    var body: some View {
        switch state {
        case .idle:
            EmptyView()

        case .dirty:
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

        case .pendingSync:
            // The width-constrained editing header uses the compact "Saved on this
            // device" (the `cloud_off` icon conveys the pending sync); the reading
            // surface's caption carries the full "· syncs when online" promise once
            // editing ends.
            HStack(spacing: DocsSpacing.space3xs) {
                MaterialSymbol(.cloud_off, size: 11)
                Text(loc[.editor_sync_saved_on_device])
                    .font(DocsFont.footnote)
            }
            .foregroundStyle(DocsColor.textTertiary)

        case .failed:
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
    }
    .background(DocsColor.surfaceSunken)
    .environment(LocalizationStore())
}
