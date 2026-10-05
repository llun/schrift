import SwiftUI

/// Reading chrome, kept outside checklist rows so their alignment and dense hit
/// targets remain governed entirely by EditorBlockStyle.
struct ChecklistReadingControls: View {
    @Binding var hidesCompleted: Bool
    let hiddenCount: Int
    var revealFocusRequest = 0
    @Environment(LocalizationStore.self) private var loc
    @AccessibilityFocusState(for: .voiceOver) private var revealFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DocsSpacing.space2xs) {
            Toggle(loc[.editor_checklist_hide_completed], isOn: $hidesCompleted)
                .font(DocsFont.body)
                .tint(DocsColor.textBrand)
                .accessibilityIdentifier("checklist.hideCompleted")

            if hiddenCount > 0 {
                Text(loc.format(.editor_checklist_hidden_count, hiddenCount))
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    hidesCompleted = false
                } label: {
                    Text(loc[.editor_checklist_show_completed])
                        .font(DocsFont.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: DocsSpacing.rowMinHeight, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(DocsColor.textBrand)
                .accessibilityIdentifier("checklist.showCompleted")
                .accessibilityLabel(
                    loc.format(.editor_checklist_hidden_count, hiddenCount) + ". "
                        + loc[.editor_checklist_show_completed]
                )
                .accessibilityFocused($revealFocused)
            }
        }
        .onChange(of: revealFocusRequest) { _, _ in
            // A completion can remove the VoiceOver-focused row. Give its newly
            // hidden content a reachable destination rather than leaving focus lost.
            revealFocused = true
        }
    }
}

#Preview("Completed checklist — Accessibility") {
    ChecklistReadingControls(hidesCompleted: .constant(true), hiddenCount: 12)
        .padding()
        .environment(LocalizationStore())
        .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("Checklist — default") {
    ChecklistReadingControls(hidesCompleted: .constant(false), hiddenCount: 0)
        .padding()
        .environment(LocalizationStore())
}
