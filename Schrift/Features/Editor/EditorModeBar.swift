import SwiftUI

/// Editing-mode header: Blocks/Markdown toggle plus live save status.
struct EditorModeBar: View {
    @Binding var modeIndex: Int
    let saveState: EditorViewModel.SaveState
    var onSaveTap: () -> Void

    var body: some View {
        HStack(spacing: DocsSpacing.spaceSM) {
            SegmentedControl(segments: ["Blocks", "Markdown"], selectedIndex: $modeIndex)
                .frame(maxWidth: 240)

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

    var body: some View {
        switch state {
        case .idle:
            EmptyView()

        case .dirty:
            Button(action: onTap) {
                Text("Save")
                    .font(DocsFont.footnote.weight(.semibold))
                    .foregroundStyle(DocsColor.textBrand)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Save now")

        case .saving:
            HStack(spacing: DocsSpacing.space3xs) {
                ProgressView()
                    .controlSize(.small)
                Text("Saving…")
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.textTertiary)
            }

        case .saved:
            HStack(spacing: DocsSpacing.space3xs) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                Text("Saved")
                    .font(DocsFont.footnote)
            }
            .foregroundStyle(DocsColor.textTertiary)

        case .failed:
            Button(action: onTap) {
                HStack(spacing: DocsSpacing.space3xs) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Couldn't save · Retry")
                        .font(DocsFont.footnote.weight(.semibold))
                }
                .foregroundStyle(DocsColor.danger)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Save failed. Retry")
        }
    }
}

#Preview {
    @Previewable @State var modeIndex = 0
    VStack(spacing: DocsSpacing.spaceBase) {
        EditorModeBar(modeIndex: $modeIndex, saveState: .dirty, onSaveTap: {})
        EditorModeBar(modeIndex: $modeIndex, saveState: .saving, onSaveTap: {})
        EditorModeBar(modeIndex: $modeIndex, saveState: .saved, onSaveTap: {})
        EditorModeBar(modeIndex: $modeIndex, saveState: .failed("nope"), onSaveTap: {})
    }
    .background(DocsColor.surfaceSunken)
}
