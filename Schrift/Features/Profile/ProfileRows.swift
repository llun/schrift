import SwiftUI

/// A bespoke row matching ListRow styling, but with a custom trailing view
/// (Switch / Badge / etc.) that ListRow does not support.
struct ProfileTrailingRow<Trailing: View>: View {
    @Environment(\.docsTheme) private var theme
    @Environment(\.docsRowGutter) private var rowGutter
    var icon: MaterialIcon? = nil
    let title: String
    let trailing: Trailing

    init(icon: MaterialIcon? = nil, title: String, @ViewBuilder trailing: () -> Trailing) {
        self.icon = icon
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: DocsSpacing.spaceSM) {
            if let icon {
                MaterialSymbol(icon, size: 24)
                    .foregroundStyle(theme.colors.textSecondary)
                    .frame(width: 24)
            }

            Text(title)
                .font(DocsFont.body)
                .foregroundStyle(theme.colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            trailing
        }
        .padding(.horizontal, rowGutter)
        .frame(minHeight: DocsSpacing.rowMinHeight)
        // Callers wrap this in a plain `Button` (the server row opens the
        // disconnect confirmation), which hit-tests only what its label draws —
        // so without this the gap between the title and the trailing badge is
        // dead. Harmless on the rows whose trailing control is a `Switch`: that
        // control is in front and still takes its own taps.
        .contentShape(Rectangle())
        // Merge the title with the trailing control so VoiceOver announces which
        // setting a switch controls (otherwise it reads a bare "switch").
        .accessibilityElement(children: .combine)
    }
}

/// Hairline divider inset past the leading icon so it starts under the text
/// (16pt gutter + 24pt icon + 12pt gap), matching the grouped-list rows.
struct ProfileRowDivider: View {
    @Environment(\.docsTheme) private var theme
    @Environment(\.docsRowGutter) private var rowGutter
    var body: some View {
        Rectangle()
            .fill(theme.colors.borderDefault)
            .frame(height: 1)
            .padding(.leading, 52)
    }
}
