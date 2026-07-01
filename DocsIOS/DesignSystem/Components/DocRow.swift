import SwiftUI

func docRowReachIndicatorSystemImage(reach: LinkReach) -> String? {
    switch reach {
    case .restricted: return nil
    case .authenticated: return "network"
    case .public: return "globe"
    }
}

func docRowAccessibilityLabel(title: String, reach: LinkReach, date: String, pinned: Bool) -> String {
    var parts = [title]
    if pinned {
        parts.append("Pinned")
    }
    switch reach {
    case .restricted:
        break
    case .authenticated:
        parts.append("Shared with organization")
    case .public:
        parts.append("Public")
    }
    if !date.isEmpty {
        parts.append(date)
    }
    return parts.joined(separator: ", ")
}

struct DocRow: View {
    var emoji: String? = nil
    var title: String = "Untitled document"
    var pinned: Bool = false
    var reach: LinkReach = .restricted
    var date: String = ""
    var onOpen: (() -> Void)? = nil
    var onMore: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: DocsSpacing.spaceSM) {
            DocIcon(emoji: emoji, pinned: pinned)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DocsSpacing.space4xs) {
                    Text(title)
                        .font(DocsFont.body)
                        .foregroundStyle(DocsColor.textPrimary)
                        .lineLimit(1)
                    if let indicatorImage = docRowReachIndicatorSystemImage(reach: reach) {
                        Image(systemName: indicatorImage)
                            .font(.system(size: 11))
                            .foregroundStyle(DocsColor.textTertiary)
                    }
                }
                Text(date)
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.textTertiary)
            }

            Spacer()

            IconButton(systemImage: "ellipsis", label: "More options", action: { onMore?() })
        }
        .padding(.horizontal, DocsSpacing.gutterGrouped)
        .frame(minHeight: DocsSpacing.rowMinHeight)
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .accessibilityLabel(docRowAccessibilityLabel(title: title, reach: reach, date: date, pinned: pinned))
        .accessibilityAddTraits(.isButton)
    }
}

#Preview {
    VStack(spacing: 0) {
        DocRow(emoji: "📄", title: "Q3 Planning", pinned: true, reach: .restricted, date: "3 days ago")
        DocRow(emoji: "📊", title: "Roadmap", reach: .authenticated, date: "Yesterday")
        DocRow(title: "Public notes", reach: .public, date: "Last week")
    }
}
