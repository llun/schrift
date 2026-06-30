import SwiftUI

struct RootView: View {
    var body: some View {
        VStack(spacing: DocsSpacing.spaceSM) {
            Text("Docs")
                .font(DocsFont.largeTitle)
                .foregroundStyle(DocsColor.textPrimary)
            Text("Connected to your documents")
                .font(DocsFont.body)
                .foregroundStyle(DocsColor.textSecondary)
        }
        .padding(DocsSpacing.spaceBase)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DocsColor.surfacePage)
    }
}

#Preview {
    RootView()
}
