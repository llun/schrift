import SwiftUI

struct SharedRow: View {
    let title: String
    let subtitle: String
    var memberNames: [String] = []
    var onTap: (() -> Void)? = nil

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: DocsSpacing.spaceSM) {
                DocIcon(emoji: nil, tinted: true)

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

                if !memberNames.isEmpty {
                    AvatarGroup(names: memberNames, size: 28, max: 3)
                }
            }
            .padding(.horizontal, DocsSpacing.spaceBase)
            .frame(minHeight: DocsSpacing.rowMinHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Collapse into a single button carrying the composed label. The avatar
        // group is otherwise dropped by `children: .ignore`, so its members are
        // folded into the label — the subtitle only names the sharer.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([title, subtitle] + memberNames).joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
    }
}

#Preview("Light") {
    sharedRowPreview.environment(LocalizationStore())
}

#Preview("Dark") {
    sharedRowPreview.environment(LocalizationStore()).preferredColorScheme(.dark)
}

private var sharedRowPreview: some View {
    VStack(spacing: 0) {
        SharedRow(
            title: "Q2 roadmap",
            subtitle: "Shared by Amandine Salambo · 2 days ago",
            memberNames: ["Amandine Salambo", "Charlie Saris", "Alfredo Levin", "Cam Moreau"]
        )
        SharedRow(title: "Bibliography", subtitle: "Shared · Last week")
    }
    .background(DocsColor.surfacePage)
    .padding()
}
