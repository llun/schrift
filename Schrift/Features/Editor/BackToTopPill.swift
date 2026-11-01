import SwiftUI

/// The small glass pill offered for a few seconds after a document reopens where the reader
/// left off ("Continue reading"), so the way back to the start is one tap away.
///
/// Glass because it floats over the reading surface, the same rule as the toast and the
/// formatting bar. Text only — the app's icon set is a fixed Material subset and a lone arrow
/// would add nothing the label does not say. At least `rowMinHeight` tall for the touch
/// target, and it grows with Dynamic Type through `DocsFont.footnote`.
struct BackToTopPill: View {
    @Environment(\.docsTheme) private var theme
    let title: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DocsFont.footnote.weight(.semibold))
                .foregroundStyle(theme.colors.textPrimary)
                .padding(.horizontal, DocsSpacing.spaceBase)
                .frame(minHeight: DocsSpacing.rowMinHeight)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityLabel(accessibilityLabel)
    }
}
