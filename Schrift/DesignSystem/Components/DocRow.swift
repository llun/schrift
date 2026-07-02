import SwiftUI

func docRowReachIndicatorSystemImage(reach: LinkReach) -> String? {
    switch reach {
    case .restricted: return nil
    case .authenticated: return "network.badge.shield.half.filled"
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
    var offlineAvailable: Bool = false
    var onOpen: (() -> Void)? = nil
    var onMore: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: DocsSpacing.spaceSM) {
            DocIcon(emoji: emoji, tinted: true, pinned: pinned)

            // Title and its inline reach glyph sit 6pt apart (reference), while
            // the DocIcon keeps the outer 12pt gap.
            HStack(spacing: DocsSpacing.space2xs) {
                Text(title)
                    .font(DocsFont.body)
                    .foregroundStyle(DocsColor.textPrimary)
                    .lineLimit(1)

                if let indicatorImage = docRowReachIndicatorSystemImage(reach: reach) {
                    Image(systemName: indicatorImage)
                        .font(.system(size: 16))
                        .foregroundStyle(DocsColor.textTertiary)
                }
            }

            Spacer(minLength: DocsSpacing.spaceXS)

            if offlineAvailable {
                Image(systemName: "checkmark.icloud.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(DocsColor.gray350)
                    .accessibilityLabel("Available offline")
            }

            if !date.isEmpty {
                Text(date)
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.textTertiary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }

            // Only show the more-options control when a handler is wired, so
            // rows without one (e.g. search results) don't present an inert button.
            if let onMore {
                IconButton(systemImage: "ellipsis", label: "More options", size: .small, action: onMore)
            }
        }
        .padding(.horizontal, DocsSpacing.spaceSM)
        .padding(.vertical, DocsSpacing.spaceSM - DocsSpacing.space4xs)
        .frame(minHeight: DocsSpacing.rowMinHeight)
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        // Collapse the row into a single button carrying the composed label,
        // otherwise the child Texts/glyphs stay separately focusable and the
        // label is never applied.
        .accessibilityElement(children: .ignore)
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
