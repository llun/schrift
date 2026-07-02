import SwiftUI

struct EditorFormattingBar: View {
    var onInsert: (String) -> Void

    var body: some View {
        HStack(spacing: DocsSpacing.spaceXS) {
            IconButton(systemImage: "plus", label: "Insert", variant: .ghost, color: .brand) {
                onInsert("\n")
            }
            IconButton(systemImage: "bold", label: "Bold", variant: .ghost, color: .neutral) {
                onInsert("**bold** ")
            }
            IconButton(systemImage: "italic", label: "Italic", variant: .ghost, color: .neutral) {
                onInsert("_italic_ ")
            }
            IconButton(systemImage: "list.bullet", label: "Bulleted list", variant: .ghost, color: .neutral) {
                onInsert("\n- ")
            }
            IconButton(systemImage: "checklist", label: "Checklist", variant: .ghost, color: .neutral) {
                onInsert("\n- [ ] ")
            }
            IconButton(systemImage: "photo", label: "Image", variant: .ghost, color: .neutral) {
                onInsert("![]() ")
            }
            IconButton(systemImage: "chevron.left.forwardslash.chevron.right", label: "Code", variant: .ghost, color: .neutral) {
                onInsert("` `")
            }
        }
        .padding(.horizontal, DocsSpacing.spaceXS)
        .padding(.vertical, DocsSpacing.space3xs)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(DocsColor.borderDefault, lineWidth: 1)
        )
        .clipShape(Capsule())
        .shadow(color: DocsColor.textPrimary.opacity(0.12), radius: 12, x: 0, y: 4)
    }
}

#Preview {
    EditorFormattingBar(onInsert: { _ in })
        .padding()
        .background(DocsColor.surfaceSunken)
}
