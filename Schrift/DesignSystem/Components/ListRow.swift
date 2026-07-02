import SwiftUI

func listRowTitleColorHex(isDestructive: Bool) -> UInt32 {
    isDestructive ? DocsColorHex.danger : DocsColorHex.textPrimary
}

struct ListRow: View {
    var systemImage: String? = nil
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var showsChevron: Bool = false
    var isDestructive: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        Button(action: { action?() }) {
            HStack(spacing: DocsSpacing.spaceSM) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 24))
                        .foregroundStyle(isDestructive ? DocsColor.danger : DocsColor.textSecondary)
                        .frame(width: 24)
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(DocsFont.body)
                        .foregroundStyle(Color(hex: listRowTitleColorHex(isDestructive: isDestructive)))
                    if let subtitle {
                        Text(subtitle)
                            .font(DocsFont.footnote)
                            .foregroundStyle(DocsColor.textTertiary)
                    }
                }

                Spacer()

                if let value {
                    Text(value)
                        .font(DocsFont.body)
                        .foregroundStyle(DocsColor.textTertiary)
                }

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 18))
                        .foregroundStyle(DocsColor.gray300)
                }
            }
            .padding(.horizontal, DocsSpacing.gutter)
            .padding(.vertical, DocsSpacing.spaceSM - DocsSpacing.space4xs)
            .frame(minHeight: DocsSpacing.rowMinHeight)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    VStack(spacing: 0) {
        ListRow(systemImage: "pin", title: "Pin", value: "Pinned", showsChevron: false, action: {})
        ListRow(systemImage: "link", title: "Copy link", action: {})
        ListRow(title: "Delete document", isDestructive: true, action: {})
    }
}
