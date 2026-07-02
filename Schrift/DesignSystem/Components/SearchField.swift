import SwiftUI

struct SearchField: View {
    @Binding var text: String
    var placeholder: String = "Search"
    var icon: String = "magnifyingglass"
    /// When true, the field takes keyboard focus as it appears (reference
    /// `autoFocus`, used on the Search tab for one-tap search entry).
    var autoFocus: Bool = false

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: DocsSpacing.spaceXS) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(DocsColor.textTertiary)
            TextField(placeholder, text: $text)
                .font(DocsFont.callout)
                .focused($isFocused)
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(DocsColor.textTertiary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, DocsSpacing.spaceSM)
        .frame(height: 40)
        .background(DocsColor.surfaceSunken)
        .clipShape(Capsule())
        .onAppear {
            if autoFocus { isFocused = true }
        }
    }
}

#Preview {
    @Previewable @State var text = ""
    SearchField(text: $text)
        .padding()
}
