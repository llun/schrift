import SwiftUI

/// A bespoke row matching ListRow styling, but with a custom trailing view
/// (Switch / Badge / etc.) that ListRow does not support.
struct ProfileTrailingRow<Trailing: View>: View {
    var systemImage: String? = nil
    let title: String
    let trailing: Trailing

    init(systemImage: String? = nil, title: String, @ViewBuilder trailing: () -> Trailing) {
        self.systemImage = systemImage
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: DocsSpacing.spaceSM) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(DocsColor.textSecondary)
                    .frame(width: 24)
            }

            Text(title)
                .font(DocsFont.body)
                .foregroundStyle(DocsColor.textPrimary)

            Spacer()

            trailing
        }
        .padding(.horizontal, DocsSpacing.gutterGrouped)
        .frame(minHeight: DocsSpacing.rowMinHeight)
    }
}

/// Hairline divider matching the inset row grouping.
struct ProfileRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(DocsColor.borderDefault)
            .frame(height: 1)
            .padding(.leading, DocsSpacing.gutterGrouped)
    }
}
