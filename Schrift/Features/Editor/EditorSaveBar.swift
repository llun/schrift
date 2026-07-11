import SwiftUI

/// Editing-session header: live save status, right-aligned. The block editor is
/// the only editing surface, so there is no mode toggle — this bar exists to keep
/// the Save / Saving… / Saved / Retry feedback visible while editing.
struct EditorSaveBar: View {
    let saveState: EditorViewModel.SaveState
    var onSaveTap: () -> Void

    var body: some View {
        HStack(spacing: DocsSpacing.spaceSM) {
            Spacer(minLength: DocsSpacing.spaceXS)

            SaveStatusIndicator(state: saveState, onTap: onSaveTap)
        }
        .padding(.horizontal, DocsSpacing.gutter)
        .padding(.vertical, DocsSpacing.space3xs)
        .background(DocsColor.surfacePage)
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
        EditorSaveBar(saveState: .dirty, onSaveTap: {})
        EditorSaveBar(saveState: .saving, onSaveTap: {})
        EditorSaveBar(saveState: .saved, onSaveTap: {})
        EditorSaveBar(saveState: .failed("nope"), onSaveTap: {})
    }
    .background(DocsColor.surfaceSunken)
    .environment(LocalizationStore())
}
