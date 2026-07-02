import SwiftUI

struct SearchField: View {
    @Binding var text: String
    var placeholder: String = "Search"

    var body: some View {
        HStack(spacing: DocsSpacing.spaceXS) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18))
                .foregroundStyle(DocsColor.textTertiary)
            TextField(placeholder, text: $text)
                .font(DocsFont.callout)
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(DocsColor.textTertiary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, DocsSpacing.spaceSM)
        .frame(height: 40)
        .background(DocsColor.surfaceSunken)
        .clipShape(Capsule())
    }
}

#Preview {
    @Previewable @State var text = ""
    SearchField(text: $text)
        .padding()
}
