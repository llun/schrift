import SwiftUI

struct SearchField: View {
    @Binding var text: String
    var placeholder: String = "Search"
    var icon: MaterialIcon = .search
    /// When true, the field takes keyboard focus as it appears (reference
    /// `autoFocus`, used on the Search tab for one-tap search entry).
    var autoFocus: Bool = false

    @FocusState private var isFocused: Bool
    @Environment(LocalizationStore.self) private var loc

    var body: some View {
        HStack(spacing: DocsSpacing.spaceXS) {
            MaterialSymbol(icon, size: 20)
                .foregroundStyle(DocsColor.textTertiary)
            TextField(placeholder, text: $text)
                .font(DocsFont.callout)
                .focused($isFocused)
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    MaterialSymbol(.cancel, size: 20, fill: true)
                        .foregroundStyle(DocsColor.textTertiary)
                        // Keep the 20pt glyph but guarantee the 44pt iOS hit target.
                        .frame(minWidth: DocsSpacing.rowMinHeight, minHeight: DocsSpacing.rowMinHeight)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(loc[.common_clear_search])
            }
        }
        .padding(.horizontal, DocsSpacing.spaceSM)
        .frame(height: 40)
        .background(DocsColor.surfaceSunken)
        .clipShape(Capsule())
        .onAppear {
            // Defer off the current run loop so the field is in the responder
            // chain before we request focus (onAppear-synchronous focus is dropped).
            if autoFocus {
                DispatchQueue.main.async { isFocused = true }
            }
        }
    }
}

#Preview {
    @Previewable @State var text = ""
    SearchField(text: $text)
        .padding()
        .environment(LocalizationStore())
}
