import SwiftUI

/// Which adaptive token colors a row's title. A case, not a raw hex, so the
/// title stays dark-mode adaptive via `DocsColor` — resolving to a raw hex
/// here would lock the title to light mode via the non-adaptive `Color(hex:)`.
enum ListRowTitleColor: Equatable {
    case primary
    case danger
}

func listRowTitleColor(isDestructive: Bool) -> ListRowTitleColor {
    isDestructive ? .danger : .primary
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
        // Only interactive rows are buttons; static informational rows (no
        // action) render as plain views so VoiceOver doesn't announce an inert
        // button (mirrors the reference's `interactive` gating).
        if let action {
            Button(action: action) { rowContent }
                .buttonStyle(.plain)
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
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
                    .foregroundStyle(
                        listRowTitleColor(isDestructive: isDestructive) == .danger
                            ? DocsColor.danger : DocsColor.textPrimary)
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
}

#Preview {
    VStack(spacing: 0) {
        ListRow(systemImage: "pin", title: "Pin", value: "Pinned", showsChevron: false, action: {})
        ListRow(systemImage: "link", title: "Copy link", action: {})
        ListRow(title: "Delete document", isDestructive: true, action: {})
    }
}
