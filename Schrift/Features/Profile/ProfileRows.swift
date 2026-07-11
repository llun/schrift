import SwiftUI

/// A bespoke row matching ListRow styling, but with a custom trailing view
/// (Switch / Badge / etc.) that ListRow does not support.
struct ProfileTrailingRow<Trailing: View>: View {
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
                    .foregroundStyle(DocsColor.textSecondary)
                    .frame(width: 24)
            }

            Text(title)
                .font(DocsFont.body)
                .foregroundStyle(DocsColor.textPrimary)
                // A long value (e.g. the server host) truncates with an ellipsis
                // rather than wrapping to a second line, matching the handoff.
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            trailing
        }
        .padding(.horizontal, DocsSpacing.gutter)
        .frame(minHeight: DocsSpacing.rowMinHeight)
        // Merge the title with the trailing control so VoiceOver announces which
        // setting a switch controls (otherwise it reads a bare "switch").
        .accessibilityElement(children: .combine)
    }
}

/// Hairline divider inset past the leading icon so it starts under the text
/// (16pt gutter + 24pt icon + 12pt gap), matching the grouped-list rows.
struct ProfileRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(DocsColor.borderDefault)
            .frame(height: 1)
            .padding(.leading, 52)
    }
}
