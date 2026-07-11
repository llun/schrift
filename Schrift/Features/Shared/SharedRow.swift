import SwiftUI

struct SharedRow: View {
    let title: String
    let subtitle: String
    var onTap: (() -> Void)? = nil

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: DocsSpacing.spaceSM) {
                DocIcon(emoji: nil, size: 22, tinted: true)

                VStack(alignment: .leading, spacing: DocsSpacing.space4xs) {
                    Text(title)
                        .font(DocsFont.body)
                        .foregroundStyle(DocsColor.textPrimary)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(DocsFont.footnote)
                        .foregroundStyle(DocsColor.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: DocsSpacing.spaceXS)

                MaterialSymbol(.chevron_right, size: 18)
                    .foregroundStyle(DocsColor.gray300)
            }
            .padding(.horizontal, DocsSpacing.spaceBase)
            .frame(minHeight: DocsSpacing.rowMinHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    VStack(spacing: 0) {
        SharedRow(title: "Design review", subtitle: "Restricted · 2d ago")
        Divider()
        SharedRow(title: "Roadmap", subtitle: "Connected · 5h ago")
    }
    .background(DocsColor.surfacePage)
    .clipShape(RoundedRectangle(cornerRadius: DocsRadius.lg))
    .padding()
}
