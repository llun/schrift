import SwiftUI

struct SearchField: View {
    @Binding var text: String
    var placeholder: String = "Search"

    var body: some View {
        HStack(spacing: DocsSpacing.spaceXS) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DocsColor.textTertiary)
            TextField(placeholder, text: $text)
                .font(DocsFont.body)
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DocsColor.textTertiary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, DocsSpacing.spaceSM)
        .padding(.vertical, DocsSpacing.space2xs)
        .background(DocsColor.surfaceSunken)
        .clipShape(Capsule())
    }
}

#Preview {
    @Previewable @State var text = ""
    SearchField(text: $text)
        .padding()
}
